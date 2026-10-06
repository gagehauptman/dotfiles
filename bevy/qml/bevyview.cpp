#include "bevyview.h"
#include <QSGRendererInterface>
#include <QSGSimpleTextureNode>
#include <QVulkanInstance>
#include <QtQuick/qsgtexture_platform.h>
#include <QRunnable>
#include <QDebug>
#include <QJsonDocument>
#include <QJsonObject>
#include <QFileInfo>
#include <QDir>
#include <QMutex>
#include <QHash>
#include <dlfcn.h>
#include <algorithm>

namespace {
// Loaded app libraries, kept for the life of the process: a library that owns
// thread pools cannot be unloaded safely, and two cards may share one app.
QMutex g_libsLock;
QHash<QString, BevyApi> g_libs;

bool loadApi(const QString &path, BevyApi &api, QString &err)
{
    QMutexLocker lock(&g_libsLock);
    if (g_libs.contains(path)) { api = g_libs.value(path); return true; }
    void *h = dlopen(QFile::encodeName(path).constData(), RTLD_NOW | RTLD_LOCAL);
    if (!h) { err = QString::fromUtf8(dlerror()); return false; }
    BevyApi a;
    a.create = reinterpret_cast<bevy_create_fn>(dlsym(h, "bevy_widget_create"));
    a.frame = reinterpret_cast<bevy_frame_fn>(dlsym(h, "bevy_widget_frame"));
    a.pointer = reinterpret_cast<bevy_pointer_fn>(dlsym(h, "bevy_widget_pointer"));
    a.scroll = reinterpret_cast<bevy_scroll_fn>(dlsym(h, "bevy_widget_scroll"));
    a.ui = reinterpret_cast<bevy_ui_fn>(dlsym(h, "bevy_widget_ui"));
    a.event = reinterpret_cast<bevy_event_fn>(dlsym(h, "bevy_widget_event"));
    a.nextFrame = reinterpret_cast<bevy_next_frame_fn>(dlsym(h, "bevy_widget_next_frame"));
    a.shown = reinterpret_cast<bevy_shown_fn>(dlsym(h, "bevy_widget_shown"));
    a.destroy = reinterpret_cast<bevy_destroy_fn>(dlsym(h, "bevy_widget_destroy"));
    if (!a.create || !a.frame || !a.pointer || !a.scroll || !a.ui || !a.event || !a.destroy) {
        err = path + " is not a quickshell-bevy app (missing bevy_widget_* symbols)";
        return false;
    }
    g_libs.insert(path, a);
    api = a;
    return true;
}

// Frees an app's GPU state on its window's render thread, never on the GUI
// thread: Qt's render thread records and submits frames that sample the app's
// image at any time, and Qt owns the VkQueue (the device wait in destroy
// needs it). Runs from a render job after the next sync, when the item's node
// is gone or no longer shows the image (frames before that are covered by the
// device wait), or from sceneGraphInvalidated if the window goes first. If
// neither ever runs, it leaks rather than free anything at the wrong time.
struct Reaper
{
    BevyApi api;
    BevyWidget *bevy = nullptr;
    std::vector<QSGTexture *> textures;
    std::atomic<bool> done{false};
    std::mutex lock;
    QMetaObject::Connection invalidated;
    void run()
    {
        if (done.exchange(true)) return;
        {
            std::lock_guard l(lock);
            QObject::disconnect(invalidated);
        }
        for (QSGTexture *t : textures) delete t;
        if (bevy && api.destroy) api.destroy(bevy);
    }
};

class ReapJob : public QRunnable
{
public:
    explicit ReapJob(std::shared_ptr<Reaper> r) : reaper(std::move(r)) {}
    void run() override { reaper->run(); }
    std::shared_ptr<Reaper> reaper;
};
}

BevyView::BevyView() : m_guard(std::make_shared<Guard>())
{
    m_guard->view = this;
    setFlag(ItemHasContents, true);
    m_timer.setSingleShot(true);
    m_timer.setTimerType(Qt::PreciseTimer);
    connect(&m_timer, &QTimer::timeout, this, [this] { if (isVisible()) update(); });
}

void BevyView::kick()
{
    m_kicked = true;
    m_timer.stop();
    update();
}

void BevyView::schedule(int ms)
{
    if (!isVisible()) return;
    if (ms <= 1) {
        m_timer.stop();
        update();
    } else if (!m_timer.isActive() || m_timer.remainingTime() > ms) {
        m_timer.start(ms);
    }
}

BevyView::~BevyView()
{
    // Waits for a render-thread hook that is running; later ones see null
    std::lock_guard lock(m_guard->lock);
    m_guard->view = nullptr;
    detach();
}

void BevyView::setLibrary(const QString &path)
{
    if (path == m_library) return;
    {
        // Another app: the old one goes like a removed item's (after the sync
        // that drops its image from the node), the new one starts after it.
        std::lock_guard lock(m_guard->lock);
        if (m_window) retire(m_window, false);
        m_library = path;
        m_failed = false;
    }
    if (!m_error.isEmpty()) { m_error.clear(); emit errorChanged(); }
    if (m_ready) { m_ready = false; emit readyChanged(); }
    if (m_frameReady) { m_frameReady = false; emit frameReadyChanged(); }
    emit libraryChanged();
    update();
}

void BevyView::setOptions(const QString &json)
{
    if (json == m_options) return;
    {
        std::lock_guard lock(m_guard->lock);
        m_options = json;
    }
    emit optionsChanged();
}

void BevyView::pointer(qreal x, qreal y, bool down)
{
    {
        std::lock_guard lock(m_inputLock);
        if (m_bevy && m_api.pointer) m_api.pointer(m_bevy, float(x), float(y), down);
    }
    // A press, drag or release wants a frame now; hovering waits for the next.
    if (down || down != m_lastDown) kick();
    m_lastDown = down;
}

void BevyView::scroll(qreal dy)
{
    {
        std::lock_guard lock(m_inputLock);
        if (m_bevy && m_api.scroll) m_api.scroll(m_bevy, float(dy));
    }
    kick();
}

void BevyView::send(const QString &id, const QString &value)
{
    {
        std::lock_guard lock(m_inputLock);
        if (m_bevy && m_api.event) m_api.event(m_bevy, id.toUtf8().constData(), value.toUtf8().constData());
    }
    kick();
}

void BevyView::itemChange(ItemChange change, const ItemChangeData &value)
{
    if (change == ItemSceneChange) {
        // The app lives on the old window's device: it goes with the window
        // change (on that window's render thread) and starts again on the new one.
        bool hadFrame = m_frameReady;
        {
            std::lock_guard lock(m_guard->lock);
            detach();
            if (value.window) attach(value.window);
        }
        if (hadFrame) { m_frameReady = false; emit frameReadyChanged(); }
    } else if (change == ItemVisibleHasChanged && value.boolValue) {
        update();
    }
    QQuickItem::itemChange(change, value);
}

void BevyView::attach(QQuickWindow *win)
{
    m_window = win;
    // Render-thread hooks: Bevy renders in beforeRendering (its queue work is
    // submitted before Qt's frame, on the same queue), and afterRendering asks
    // for the next frame so the scene animates while the item is shown. They
    // go through the guard (see Guard), with the window as the context.
    auto hook = [g = m_guard](void (BevyView::*fn)()) {
        return [g, fn] {
            std::lock_guard lock(g->lock);
            if (g->view) (g->view->*fn)();
        };
    };
    m_conns.push_back(connect(win, &QQuickWindow::beforeRendering, win, hook(&BevyView::beforeRendering), Qt::DirectConnection));
    m_conns.push_back(connect(win, &QQuickWindow::afterRendering, win, hook(&BevyView::afterRendering), Qt::DirectConnection));
    m_conns.push_back(connect(win, &QQuickWindow::sceneGraphInvalidated, win, hook(&BevyView::invalidate), Qt::DirectConnection));
    update();
}

void BevyView::detach()
{
    for (auto &c : m_conns) disconnect(c);
    m_conns.clear();
    // Also from the destructor: Qt drops the item's node at the window's next
    // sync, and the app and its textures go right after it.
    if (m_window) retire(m_window, true);
    m_window = nullptr;
}

void BevyView::retire(QQuickWindow *win, bool textures)
{
    auto r = std::make_shared<Reaper>();
    r->api = m_api;
    {
        std::lock_guard lock(m_inputLock);
        r->bevy = m_bevy;
        m_bevy = nullptr;
    }
    if (textures) {
        for (auto &t : m_retired) r->textures.push_back(t.tex);
        m_retired.clear();
        if (m_nodeTex) r->textures.push_back(m_nodeTex);
        m_nodeTex = nullptr;
        m_nodeImage = 0;
    }
    // Without textures the item stays: its next sync sees no image and drops
    // the node, which is before the job runs.
    m_frameImage = 0;
    m_frameSize = QSize();
    m_deferred = false;
    m_uiGen = 0;
    if (!r->bevy && r->textures.empty()) return;
    {
        std::lock_guard lock(r->lock);
        r->invalidated = QObject::connect(win, &QQuickWindow::sceneGraphInvalidated, win, [r] { r->run(); }, Qt::DirectConnection);
    }
    win->scheduleRenderJob(new ReapJob(r), QQuickWindow::AfterSynchronizingStage);
    win->update();
}

void BevyView::fail(const QString &msg)
{
    m_failed = true;
    QMetaObject::invokeMethod(this, [this, msg] {
        m_error = msg;
        emit errorChanged();
    }, Qt::QueuedConnection);
    qWarning() << "BevyView:" << msg;
}

void BevyView::beforeRendering()
{
    if (m_failed || !m_window || !isVisible() || width() < 1 || height() < 1 || m_library.isEmpty()) return;
    QSGRendererInterface *ri = m_window->rendererInterface();
    if (!m_bevy) {
        // Building the app takes a few hundred ms on this thread, and a new
        // window shows nothing until its first frame is done: let that frame
        // go out without the scene (the lock screen's poster and text are up
        // at once), build it for the next.
        if (!m_deferred) {
            m_deferred = true;
            QMetaObject::invokeMethod(this, [this] { update(); }, Qt::QueuedConnection);
            return;
        }
        if (!ri || ri->graphicsApi() != QSGRendererInterface::Vulkan) {
            fail("needs the Vulkan scene graph backend (QSG_RHI_BACKEND=vulkan)");
            return;
        }
        QString err;
        if (!QFileInfo::exists(m_library)) {
            fail("app not built: " + m_library);
            return;
        }
        if (!loadApi(m_library, m_api, err)) {
            fail(err);
            return;
        }
        const QByteArray assets = QFile::encodeName(QFileInfo(m_library).dir().filePath("assets"));
        auto *inst = static_cast<QVulkanInstance *>(ri->getResource(m_window, QSGRendererInterface::VulkanInstanceResource));
        auto *phys = static_cast<VkPhysicalDevice *>(ri->getResource(m_window, QSGRendererInterface::PhysicalDeviceResource));
        auto *dev = static_cast<VkDevice *>(ri->getResource(m_window, QSGRendererInterface::DeviceResource));
        auto *family = static_cast<uint32_t *>(ri->getResource(m_window, QSGRendererInterface::GraphicsQueueFamilyIndexResource));
        auto *qidx = static_cast<uint32_t *>(ri->getResource(m_window, QSGRendererInterface::GraphicsQueueIndexResource));
        if (!inst || !phys || !dev || !family || !qidx) {
            fail("could not get the Vulkan device from the scene graph");
            return;
        }
        QByteArrayList exts = inst->extensions();
        std::vector<const char *> extPtrs;
        for (const QByteArray &e : exts) extPtrs.push_back(e.constData());
        QVersionNumber v = inst->apiVersion();
        BevyWidgetInit init{};
        init.instance = reinterpret_cast<uint64_t>(inst->vkInstance());
        init.physical_device = reinterpret_cast<uint64_t>(*phys);
        init.device = reinterpret_cast<uint64_t>(*dev);
        init.queue_family = *family;
        init.queue_index = *qidx;
        init.api_version = VK_MAKE_API_VERSION(0, v.majorVersion(), v.minorVersion(), 0);
        init.instance_extensions = extPtrs.data();
        init.instance_extension_count = uint32_t(extPtrs.size());
        init.assets_dir = assets.constData();
        const QByteArray opts = m_options.toUtf8();
        m_optFps = QJsonDocument::fromJson(opts).object().value("fps").toDouble(0);
        init.options = opts.constData();
        char cerr[512] = {0};
        BevyWidget *bevy = m_api.create(&init, cerr, sizeof cerr);
        if (!bevy) {
            fail(QString::fromUtf8(cerr[0] ? cerr : "bevy failed to start"));
            return;
        }
        {
            std::lock_guard lock(m_inputLock);
            m_bevy = bevy;
        }
        QMetaObject::invokeMethod(this, [this] { m_ready = true; emit readyChanged(); }, Qt::QueuedConnection);
    }
    // What the scene graph samples this frame (synced just before), so the
    // app frees an old target only once Qt is done with it
    if (m_api.shown) m_api.shown(m_bevy, m_nodeImage);
    const qreal dpr = m_window->effectiveDevicePixelRatio();
    const QSize px(qMax(1, int(width() * dpr)), qMax(1, int(height() * dpr)));
    // Not due yet (the window redraws for another item, say): keep showing
    // the last image. A resize or input is always due.
    const auto now = std::chrono::steady_clock::now();
    const bool kicked = m_kicked.exchange(false);
    if (!kicked && now < m_due && m_frameImage && px == m_frameSize) return;
    uint64_t image = m_api.frame(m_bevy, uint32_t(px.width()), uint32_t(px.height()));
    if (image) {
        if (!m_frameImage)
            QMetaObject::invokeMethod(this, [this] { if (!m_frameReady) { m_frameReady = true; emit frameReadyChanged(); } }, Qt::QueuedConnection);
        m_frameImage = image;
        m_frameSize = px;
    }
    uint32_t ms = m_api.nextFrame ? m_api.nextFrame(m_bevy) : 0;
    // The options' `fps` (apps that read it for their own cap, e.g. the lock's
    // full-rate scene) also lifts the harness pacing, which defaults to 30 fps.
    if (m_optFps > 0) ms = std::min(ms, uint32_t(1000.0 / m_optFps));
    m_due = now + std::chrono::milliseconds(ms);
    // Controls and readouts changed by the app this frame
    uint64_t gen = m_uiGen;
    const char *json = m_api.ui(m_bevy, &gen);
    if (json && gen != m_uiGen) {
        m_uiGen = gen;
        const QString s = QString::fromUtf8(json);
        QMetaObject::invokeMethod(this, [this, s] { m_ui = s; emit uiChanged(); }, Qt::QueuedConnection);
    }
}

void BevyView::afterRendering()
{
    if (m_failed || !m_bevy) return;
    // Ask for the window's next frame when the app's is due: right away at
    // the display rate, else on a timer. Also when this window frame wasn't
    // ours, so a skipped frame never stalls the card.
    const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(m_due - std::chrono::steady_clock::now()).count();
    const int ms = int(std::clamp<qint64>(left, 0, 60000));
    QMetaObject::invokeMethod(this, [this, ms] { schedule(ms); }, Qt::QueuedConnection);
}

void BevyView::invalidate()
{
    // Scene graph going away (window destroyed / GPU context lost): the Bevy
    // device state is tied to it. Qt has deleted the nodes already and the
    // device is still there.
    BevyWidget *bevy;
    {
        std::lock_guard lock(m_inputLock);
        bevy = m_bevy;
        m_bevy = nullptr;
    }
    for (auto &r : m_retired) delete r.tex;
    m_retired.clear();
    delete m_nodeTex;
    m_nodeTex = nullptr;
    if (bevy && m_api.destroy) m_api.destroy(bevy);
    m_deferred = false;
    m_frameImage = m_nodeImage = 0;
    m_frameSize = QSize();
    m_uiGen = 0;
    QMetaObject::invokeMethod(this, [this] { if (m_frameReady) { m_frameReady = false; emit frameReadyChanged(); } }, Qt::QueuedConnection);
}

void BevyView::releaseResources()
{
    // Called on the GUI thread with the render thread idle; the textures (the
    // node doesn't own its own) are deleted on the render thread: with the
    // node in updatePaintNode, or by the reaper / invalidate.
}

QSGNode *BevyView::updatePaintNode(QSGNode *old, UpdatePaintNodeData *)
{
    auto *node = static_cast<QSGSimpleTextureNode *>(old);
    // Drop textures Qt has definitely finished with (two frames in flight)
    for (auto it = m_retired.begin(); it != m_retired.end();) {
        if (++it->frames > 3) { delete it->tex; it = m_retired.erase(it); } else ++it;
    }
    if (!m_frameImage) {
        // No image (another app is starting): the node goes, and the image
        // with it after this sync (see retire)
        if (m_nodeTex) m_retired.push_back({m_nodeTex, 0});
        m_nodeTex = nullptr;
        m_nodeImage = 0;
        delete node;
        return nullptr;
    }
    if (!node) {
        node = new QSGSimpleTextureNode;
        node->setFiltering(QSGTexture::Linear);
        node->setOwnsTexture(false);
        if (m_nodeTex) m_retired.push_back({m_nodeTex, 0});
        m_nodeTex = nullptr;
        m_nodeImage = 0;
    }
    if (m_nodeImage != m_frameImage) {
        // The image is always handed over in SHADER_READ_ONLY_OPTIMAL (lib.rs),
        // so Qt never needs a layout transition of its own.
        QSGTexture *tex = QNativeInterface::QSGVulkanTexture::fromNative(
            reinterpret_cast<VkImage>(m_frameImage), VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, m_window, m_frameSize,
            QQuickWindow::TextureHasAlphaChannel);
        if (m_nodeTex) m_retired.push_back({m_nodeTex, 0});
        node->setTexture(tex);
        m_nodeTex = tex;
        m_nodeImage = m_frameImage;
    }
    node->setRect(boundingRect());
    node->markDirty(QSGNode::DirtyMaterial);
    return node;
}

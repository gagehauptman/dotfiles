#include "bevyview.h"
#include <QSGRendererInterface>
#include <QSGSimpleTextureNode>
#include <QVulkanInstance>
#include <QtQuick/qsgtexture_platform.h>
#include <QRunnable>
#include <QDebug>
#include <QFileInfo>
#include <QDir>
#include <QMutex>
#include <QHash>
#include <dlfcn.h>

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
    a.destroy = reinterpret_cast<bevy_destroy_fn>(dlsym(h, "bevy_widget_destroy"));
    if (!a.create || !a.frame || !a.pointer || !a.destroy) {
        err = path + " is not a quickshell-bevy app (missing bevy_widget_* symbols)";
        return false;
    }
    g_libs.insert(path, a);
    api = a;
    return true;
}

// Tears Bevy down on the render thread (the device must go idle there).
class Cleanup : public QRunnable
{
public:
    Cleanup(BevyApi a, BevyWidget *b, std::vector<QSGTexture *> t) : api(a), bevy(b), textures(std::move(t)) {}
    void run() override
    {
        for (QSGTexture *t : textures) delete t;
        if (bevy && api.destroy) api.destroy(bevy);
    }
    BevyApi api;
    BevyWidget *bevy;
    std::vector<QSGTexture *> textures;
};
}

BevyView::BevyView()
{
    setFlag(ItemHasContents, true);
}

BevyView::~BevyView()
{
    detach();
    std::vector<QSGTexture *> texs;
    for (auto &r : m_retired) texs.push_back(r.tex);
    m_retired.clear();
    if (m_window && (m_bevy || !texs.empty()))
        m_window->scheduleRenderJob(new Cleanup(m_api, m_bevy, std::move(texs)), QQuickWindow::BeforeSynchronizingStage);
    else if (m_bevy && m_api.destroy)
        m_api.destroy(m_bevy);
    m_bevy = nullptr;
}

void BevyView::setLibrary(const QString &path)
{
    if (path == m_library) return;
    m_library = path;
    emit libraryChanged();
    update();
}

void BevyView::pointer(qreal x, qreal y, bool down)
{
    if (m_bevy && m_api.pointer) m_api.pointer(m_bevy, float(x), float(y), down);
}

void BevyView::itemChange(ItemChange change, const ItemChangeData &value)
{
    if (change == ItemSceneChange) {
        detach();
        if (value.window) attach(value.window);
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
    // for the next frame so the scene animates while the item is shown.
    m_conns.push_back(connect(win, &QQuickWindow::beforeRendering, this, &BevyView::beforeRendering, Qt::DirectConnection));
    m_conns.push_back(connect(win, &QQuickWindow::afterRendering, this, &BevyView::afterRendering, Qt::DirectConnection));
    m_conns.push_back(connect(win, &QQuickWindow::sceneGraphInvalidated, this, &BevyView::invalidate, Qt::DirectConnection));
    update();
}

void BevyView::detach()
{
    for (auto &c : m_conns) disconnect(c);
    m_conns.clear();
    m_window = nullptr;
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
        char cerr[512] = {0};
        m_bevy = m_api.create(&init, cerr, sizeof cerr);
        if (!m_bevy) {
            fail(QString::fromUtf8(cerr[0] ? cerr : "bevy failed to start"));
            return;
        }
        QMetaObject::invokeMethod(this, [this] { m_ready = true; emit readyChanged(); }, Qt::QueuedConnection);
    }
    const qreal dpr = m_window->effectiveDevicePixelRatio();
    const QSize px(qMax(1, int(width() * dpr)), qMax(1, int(height() * dpr)));
    uint64_t image = m_api.frame(m_bevy, uint32_t(px.width()), uint32_t(px.height()));
    if (image) {
        m_frameImage = image;
        m_frameSize = px;
    }
}

void BevyView::afterRendering()
{
    if (m_failed || !m_bevy) return;
    QMetaObject::invokeMethod(this, [this] { if (isVisible()) update(); }, Qt::QueuedConnection);
}

void BevyView::invalidate()
{
    // Scene graph going away (window destroyed / GPU context lost): the Bevy
    // device state is tied to it.
    if (m_bevy && m_api.destroy) m_api.destroy(m_bevy);
    m_bevy = nullptr;
    for (auto &r : m_retired) delete r.tex;
    m_retired.clear();
    m_frameImage = m_nodeImage = 0;
}

void BevyView::releaseResources()
{
    // Called on the GUI thread with the render thread idle; textures are owned
    // by the node (deleted with it) or by m_retired (deleted on the render thread).
}

QSGNode *BevyView::updatePaintNode(QSGNode *old, UpdatePaintNodeData *)
{
    auto *node = static_cast<QSGSimpleTextureNode *>(old);
    // Drop textures Qt has definitely finished with (two frames in flight)
    for (auto it = m_retired.begin(); it != m_retired.end();) {
        if (++it->frames > 3) { delete it->tex; it = m_retired.erase(it); } else ++it;
    }
    if (!m_frameImage) {
        delete node;
        return nullptr;
    }
    if (!node) {
        node = new QSGSimpleTextureNode;
        node->setFiltering(QSGTexture::Linear);
        node->setOwnsTexture(false);
        m_nodeImage = 0;
    }
    if (m_nodeImage != m_frameImage) {
        // The image is always handed over in SHADER_READ_ONLY_OPTIMAL (lib.rs),
        // so Qt never needs a layout transition of its own.
        QSGTexture *tex = QNativeInterface::QSGVulkanTexture::fromNative(
            reinterpret_cast<VkImage>(m_frameImage), VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, m_window, m_frameSize,
            QQuickWindow::TextureHasAlphaChannel);
        if (QSGTexture *prev = node->texture()) m_retired.push_back({prev, 0});
        node->setTexture(tex);
        m_nodeImage = m_frameImage;
    }
    node->setRect(boundingRect());
    node->markDirty(QSGNode::DirtyMaterial);
    return node;
}

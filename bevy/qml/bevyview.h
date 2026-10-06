// BevyView: a Qt Quick item that shows a Bevy app rendered in-process on the
// same Vulkan device as the scene graph. The app is a cdylib built with the
// quickshell-bevy harness (../harness) and loaded at runtime from `library`.
#pragma once
#include <vulkan/vulkan.h>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSGTexture>
#include <QTimer>
#include <QtQml/qqmlregistration.h>
#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <vector>

extern "C" {
struct BevyWidgetInit {
    uint64_t instance;
    uint64_t physical_device;
    uint64_t device;
    uint32_t queue_family;
    uint32_t queue_index;
    uint32_t api_version;
    const char *const *instance_extensions;
    uint32_t instance_extension_count;
    const char *assets_dir;
    const char *options;
};
struct BevyWidget;
typedef BevyWidget *(*bevy_create_fn)(const BevyWidgetInit *init, char *err, uint32_t err_len);
typedef uint64_t (*bevy_frame_fn)(BevyWidget *w, uint32_t width, uint32_t height);
typedef void (*bevy_pointer_fn)(BevyWidget *w, float x, float y, bool down);
typedef void (*bevy_scroll_fn)(BevyWidget *w, float dy);
typedef const char *(*bevy_ui_fn)(BevyWidget *w, uint64_t *generation);
typedef void (*bevy_event_fn)(BevyWidget *w, const char *id, const char *value);
typedef uint32_t (*bevy_next_frame_fn)(BevyWidget *w);
typedef void (*bevy_shown_fn)(BevyWidget *w, uint64_t image);
typedef void (*bevy_destroy_fn)(BevyWidget *w);
}
// The entry points of one loaded app library
struct BevyApi {
    bevy_create_fn create = nullptr;
    bevy_frame_fn frame = nullptr;
    bevy_pointer_fn pointer = nullptr;
    bevy_scroll_fn scroll = nullptr;
    bevy_ui_fn ui = nullptr;
    bevy_event_fn event = nullptr;
    // Optional (older apps lack it): ms until the app wants its next frame
    bevy_next_frame_fn nextFrame = nullptr;
    // Optional (older apps lack it): the image the scene graph samples this
    // frame, so the app frees an old target only once Qt is done with it
    bevy_shown_fn shown = nullptr;
    bevy_destroy_fn destroy = nullptr;
};

class BevyView : public QQuickItem
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString library READ library WRITE setLibrary NOTIFY libraryChanged)
    Q_PROPERTY(QString options READ options WRITE setOptions NOTIFY optionsChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
    Q_PROPERTY(bool ready READ ready NOTIFY readyChanged)
    // The app has drawn its first frame (the item shows the scene, not nothing)
    Q_PROPERTY(bool frameReady READ frameReady NOTIFY frameReadyChanged)
    // Controls and readouts the app declares, as JSON {"controls": [...], "info": [...]}
    Q_PROPERTY(QString ui READ ui NOTIFY uiChanged)
public:
    BevyView();
    ~BevyView() override;
    QString library() const { return m_library; }
    void setLibrary(const QString &path);
    QString options() const { return m_options; }
    void setOptions(const QString &json);
    Q_INVOKABLE void scroll(qreal dy);
    QString ui() const { return m_ui; }
    // A control press: the id and, for a toggle, the new state "true"/"false"
    Q_INVOKABLE void send(const QString &id, const QString &value);
    QString error() const { return m_error; }
    bool ready() const { return m_ready; }
    bool frameReady() const { return m_frameReady; }
    Q_INVOKABLE void pointer(qreal x, qreal y, bool down);

signals:
    void libraryChanged();
    void optionsChanged();
    void errorChanged();
    void readyChanged();
    void frameReadyChanged();
    void uiChanged();

protected:
    QSGNode *updatePaintNode(QSGNode *node, UpdatePaintNodeData *) override;
    void itemChange(ItemChange change, const ItemChangeData &value) override;
    void releaseResources() override;

private:
    // The render-thread hooks reach the item through this, never directly:
    // the item can be deleted on the GUI thread while the render thread is
    // in the middle of a frame. The destructor clears `view` under `lock`,
    // so a hook either finishes first or sees null.
    struct Guard {
        std::mutex lock;
        BevyView *view = nullptr;
    };
    std::shared_ptr<Guard> m_guard;

    // GUI thread, m_guard->lock held
    void attach(QQuickWindow *win);
    void detach();
    // Hands the app (and, with `textures`, the scene-graph textures) to `win`'s
    // render thread, which frees them after the next sync, when no frame can
    // sample the image any more. GUI thread, m_guard->lock held.
    void retire(QQuickWindow *win, bool textures);
    void beforeRendering();   // render thread, m_guard->lock held
    void afterRendering();    // render thread, m_guard->lock held
    void invalidate();        // render thread, m_guard->lock held
    void fail(const QString &msg);

    QQuickWindow *m_window = nullptr;
    // m_bevy for input calls on the GUI thread, against the render thread
    // creating or destroying it
    std::mutex m_inputLock;
    std::vector<QMetaObject::Connection> m_conns;
    QString m_library;
    QString m_options;
    BevyApi m_api;
    BevyWidget *m_bevy = nullptr;
    bool m_failed = false;
    bool m_ready = false;
    bool m_frameReady = false;  // GUI thread
    bool m_deferred = false;    // render thread: the app is built after the window's first frame
    QString m_error;
    QString m_ui;          // GUI thread
    uint64_t m_uiGen = 0;  // render thread

    // Frame pacing: the app says after each frame when it wants the next
    // (FramePacing in the harness); frames in between reuse the last image,
    // even when something else makes the window redraw.
    void kick();                                   // GUI thread: input, a frame now
    void schedule(int ms);                         // GUI thread
    QTimer m_timer;                                // GUI thread
    std::atomic<bool> m_kicked{false};
    bool m_lastDown = false;                       // GUI thread
    std::chrono::steady_clock::time_point m_due{}; // render thread
    double m_optFps = 0;                           // render thread: `fps` from the options, 0 = none

    // Written on the render thread in beforeRendering, read in the sync phase
    uint64_t m_frameImage = 0;
    QSize m_frameSize;
    uint64_t m_nodeImage = 0;
    QSGTexture *m_nodeTex = nullptr;  // the node's (not owned by it)
    struct Retired { QSGTexture *tex; int frames; };
    std::vector<Retired> m_retired;
};

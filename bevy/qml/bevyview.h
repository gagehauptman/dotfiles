// BevyView: a Qt Quick item that shows a Bevy app rendered in-process on the
// same Vulkan device as the scene graph. The app is a cdylib built with the
// quickshell-bevy harness (../harness) and loaded at runtime from `library`.
#pragma once
#include <vulkan/vulkan.h>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSGTexture>
#include <QtQml/qqmlregistration.h>
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
};
struct BevyWidget;
typedef BevyWidget *(*bevy_create_fn)(const BevyWidgetInit *init, char *err, uint32_t err_len);
typedef uint64_t (*bevy_frame_fn)(BevyWidget *w, uint32_t width, uint32_t height);
typedef void (*bevy_pointer_fn)(BevyWidget *w, float x, float y, bool down);
typedef void (*bevy_destroy_fn)(BevyWidget *w);
}
// The four entry points of one loaded app library
struct BevyApi {
    bevy_create_fn create = nullptr;
    bevy_frame_fn frame = nullptr;
    bevy_pointer_fn pointer = nullptr;
    bevy_destroy_fn destroy = nullptr;
};

class BevyView : public QQuickItem
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString library READ library WRITE setLibrary NOTIFY libraryChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
    Q_PROPERTY(bool ready READ ready NOTIFY readyChanged)
public:
    BevyView();
    ~BevyView() override;
    QString library() const { return m_library; }
    void setLibrary(const QString &path);
    QString error() const { return m_error; }
    bool ready() const { return m_ready; }
    Q_INVOKABLE void pointer(qreal x, qreal y, bool down);

signals:
    void libraryChanged();
    void errorChanged();
    void readyChanged();

protected:
    QSGNode *updatePaintNode(QSGNode *node, UpdatePaintNodeData *) override;
    void itemChange(ItemChange change, const ItemChangeData &value) override;
    void releaseResources() override;

private:
    void attach(QQuickWindow *win);
    void detach();
    void beforeRendering();   // render thread
    void afterRendering();    // render thread
    void invalidate();        // render thread
    void fail(const QString &msg);

    QQuickWindow *m_window = nullptr;
    std::vector<QMetaObject::Connection> m_conns;
    QString m_library;
    BevyApi m_api;
    BevyWidget *m_bevy = nullptr;
    bool m_failed = false;
    bool m_ready = false;
    QString m_error;

    // Written on the render thread in beforeRendering, read in the sync phase
    uint64_t m_frameImage = 0;
    QSize m_frameSize;
    uint64_t m_nodeImage = 0;
    struct Retired { QSGTexture *tex; int frames; };
    std::vector<Retired> m_retired;
};

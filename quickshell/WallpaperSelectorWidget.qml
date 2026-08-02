import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import QtQuick.Effects
import Quickshell
import Quickshell.Services.Pipewire
import Quickshell.Widgets
import Quickshell.Hyprland
import Quickshell.Wayland
import Qt.labs.folderlistmodel
import Qt5Compat.GraphicalEffects
import Quickshell.Io
import "themes"

// Wallpaper Selector
Item {
    id: wallpaperSelectorWidget

    readonly property bool isOpen: bar.state === "wallpaper_selector"

    // Key navigation is broadcast from root; only the leader (first-opened
    // window) applies the step. Its index changes publish to
    // root.wallpaperSharedIndex, which the other open selectors adopt below —
    // absolute positions, so they can't drift apart. Only the leader queues
    // the wallpaper script.
    Connections {
        target: root
        function onWallpaperNavCounterChanged() {
            if (!wallpaperSelectorWidget.isOpen || carousel.count === 0)
                return;
            if (root.selectorWindows[0] !== barWindow)
                return;

            if (root.wallpaperNavDir < 0)
                carousel.decrementCurrentIndex();
            else
                carousel.incrementCurrentIndex();
        }

        function onWallpaperSharedIndexChanged() {
            if (!wallpaperSelectorWidget.isOpen || carousel.count === 0)
                return;

            let idx = root.wallpaperSharedIndex;
            if (idx < 0 || idx >= carousel.count || idx === carousel.currentIndex)
                return;

            if (root.selectorWindows[0] === barWindow) {
                // Another monitor drove the selection (e.g. by mouse); adopt it
                // unsuppressed so this instance queues the wallpaper change.
                carousel.positionViewAtIndex(idx, PathView.Center);
                carousel.currentIndex = idx;
                return;
            }

            restoringSelection = true;
            carousel.positionViewAtIndex(idx, PathView.Center);
            carousel.currentIndex = idx;
            Qt.callLater(() => restoringSelection = false);
        }
    }

    visible: isOpen

    anchors.fill: parent

    FolderListModel {
        id: wallpaperModel
        folder: "file://" + Quickshell.env("HOME") + "/.config/wallpapers"
        nameFilters: ["*.jpg", "*.png", "*.jpeg", "*.webp"]
        showDirs: false
    }

    property int selectedIndex: 0
    property bool restoringSelection: false
    property string savedWallpaperPath: ""
    property string pendingWallpaperPath: ""

    function normalizedPath(path) {
        return String(path || "").replace(/[\r\n]+/gm, "");
    }

    function queueWallpaper(path) {
        let cleanPath = normalizedPath(path);
        if (cleanPath.length === 0 || cleanPath === savedWallpaperPath)
            return;

        pendingWallpaperPath = cleanPath;
        wallpaperDebounce.restart();
    }

    function runPendingWallpaper() {
        if (pendingWallpaperPath.length === 0)
            return;

        let cleanPath = pendingWallpaperPath;
        pendingWallpaperPath = "";
        savedWallpaperPath = cleanPath;
        // Fire-and-forget: a tracked Process re-couples the selector to daemon
        // startup time (a booting dynamic wallpaper blocks the queue for
        // seconds). The script serializes concurrent runs itself via flock.
        Quickshell.execDetached([
            Quickshell.env("HOME") + "/.config/scripts/wallpaper/wallpaper_select.sh",
            cleanPath
        ]);
    }

    FileView {
        id: savedWallpaperReader
        path: Quickshell.env("HOME") + "/.config/scripts/wallpaper/wpsave.txt"
    }

    // While the view is still settling (animation or drag), StrictlyEnforceRange
    // keeps rewriting currentIndex from the view position, so firing on the raw
    // debounce can run the script for transient indices — under load (e.g. a
    // dynamic wallpaper booting) that cascades into a kill/spawn war between
    // wallpaper daemons. Re-arm until the offset stops moving, then run once.
    property real debounceLastOffset: -1

    Timer {
        id: wallpaperDebounce
        interval: 150
        repeat: false
        onTriggered: {
            if (carousel.offset !== wallpaperSelectorWidget.debounceLastOffset) {
                wallpaperSelectorWidget.debounceLastOffset = carousel.offset;
                restart();
                return;
            }
            runPendingWallpaper();
        }
    }

    onVisibleChanged: {
        savedWallpaperReader.reload();

        if (visible) {
            savedWallpaperPath = normalizedPath(savedWallpaperReader.text());
            
            let applySelection = () => {
                restoringSelection = true;
                let found = false;

                // A selector already open on another monitor wins over the save
                // file — its position can be ahead of the last completed script.
                let shared = root.wallpaperSharedIndex;
                if (root.selectorWindows[0] !== barWindow && shared >= 0 && shared < wallpaperModel.count) {
                    carousel.positionViewAtIndex(shared, PathView.Center);
                    carousel.currentIndex = shared;
                    found = true;
                } else {
                    for (let i = 0; i < wallpaperModel.count; i++) {
                        if (normalizedPath(wallpaperModel.get(i, "filePath")) === savedWallpaperPath) {
                            carousel.positionViewAtIndex(i, PathView.Center);
                            carousel.currentIndex = i;
                            found = true;
                            break;
                        }
                    }
                }

                if (found)
                    Qt.callLater(() => restoringSelection = false);
                else
                    restoringSelection = false;
            };

            // Deferred so the window registry (leader order) settles before the
            // leader-vs-follower decision — both react to the same state change.
            let findIndex = () => Qt.callLater(applySelection);

            if (wallpaperModel.status === FolderListModel.Ready) {
                findIndex();
            } else {
                const onReady = () => {
                    if (wallpaperModel.status === FolderListModel.Ready) {
                        findIndex();
                        wallpaperModel.statusChanged.disconnect(onReady);
                    }
                };
                wallpaperModel.statusChanged.connect(onReady);
            }
        }
    }

    PathView {
        id: carousel
        width: parent.width * 0.99
        height: parent.height
        anchors {
            horizontalCenter: parent.horizontalCenter
            verticalCenter: parent.verticalCenter
        }

        focus: visible

        Keys.onLeftPressed: root.wallpaperNav(-1)
        Keys.onRightPressed: root.wallpaperNav(1)
        Keys.onUpPressed: root.wallpaperNav(-1)
        Keys.onDownPressed: root.wallpaperNav(1)
        Keys.onReturnPressed: root.closeWallpaperSelectors()
        Keys.onEnterPressed: root.closeWallpaperSelectors()
        Keys.onEscapePressed: root.closeWallpaperSelectors()

        model: wallpaperModel
        
        pathItemCount: 5
        cacheItemCount: 25
        
        preferredHighlightBegin: 0.5
        preferredHighlightEnd: 0.5
        highlightRangeMode: PathView.StrictlyEnforceRange
        
        snapMode: PathView.SnapToItem
        dragMargin: metrics.s(200)

        clip: true

        onCurrentIndexChanged: {
            if (currentIndex < 0 || currentIndex >= model.count)
                return;

            // Publish even suppressed changes: followers re-publish the value
            // they were told (a no-op), while restores seed the shared state.
            if (wallpaperSelectorWidget.isOpen)
                root.wallpaperSharedIndex = currentIndex;

            if (restoringSelection || root.selectorWindows[0] !== barWindow)
                return;

            queueWallpaper(model.get(currentIndex, "filePath"));
        }

        delegate: Rectangle {
            id: wallpaperDelegate
            width: metrics.isVertical ? carousel.width * 0.6 : carousel.width / 6
            height: width * 9/16 + metrics.s(30)
            
            scale: PathView.iconScale 
            z: PathView.iconZ
            property bool isCurrentItem: PathView.isCurrentItem
            opacity: isCurrentItem ? 1 : 0.5

            Behavior on opacity {
                NumberAnimation {
                    duration: 100 // adjust speed in milliseconds
                    easing.type: Easing.OutQuad
                }
            }
            
            color: "transparent"

            Image {
                id: img
                width: parent.width
                height: width * 9/16
                // anchors.margins: PathView.isCurrentItem ? 6 : 0
                
                // source is static per delegate! It never changes, so no reloading.
                source: fileUrl 
                
                // Keep the optimization to ensure initial load is fast
                sourceSize.width: 0
                sourceSize.height: 400
                
                asynchronous: true
                cache: true
                clip: true
                fillMode: Image.PreserveAspectCrop

                layer.enabled: true
                layer.effect: OpacityMask {
                    maskSource: Rectangle {
                        width: img.width
                        height: img.height
                        radius: wallpaperDelegate.isCurrentItem ? metrics.radiusNormal : metrics.radiusSmall
                        visible: false 
                        Behavior on radius {
                            NumberAnimation {
                                duration: 150 // adjust speed in milliseconds
                                easing.type: Easing.OutQuad
                            }
                        }
                    }
                }
            }

            Text {
                anchors.top: img.bottom
                anchors.topMargin: metrics.spacingSmall
                anchors.left: parent.left
                anchors.right: parent.right
                text: fileBaseName
                color: Theme.colors.textSecondary
                font.family: "Noto Sans"
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
            }
            
            // Click to select
            MouseArea {
                anchors.fill: parent
                onClicked: carousel.currentIndex = index
            }
        }

        // 6. The Path the items float along: horizontal on a top bar, vertical on
        //    a side bar (start/end swap axes; the middle point is the same center).
        path: Path {
            startX: metrics.isVertical ? carousel.width / 2 : 0
            startY: metrics.isVertical ? 0 : carousel.height / 2

            // Start of path (Scale 0.95)
            PathAttribute { name: "iconScale"; value: 0.95 }
            PathAttribute { name: "iconZ"; value: 0 }

            // Middle of screen (Scale 1.1, Z-index 100 to stay on top)
            PathLine { x: carousel.width / 2; y: carousel.height / 2 }
            PathAttribute { name: "iconScale"; value: 1.1 }
            PathAttribute { name: "iconZ"; value: 100 }

            // End of path (Scale 0.95)
            PathLine {
                x: metrics.isVertical ? carousel.width / 2 : carousel.width
                y: metrics.isVertical ? carousel.height : carousel.height / 2
            }
            PathAttribute { name: "iconScale"; value: 0.95 }
            PathAttribute { name: "iconZ"; value: 0 }
        }
    }
}
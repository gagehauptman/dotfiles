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
        if (pendingWallpaperPath.length === 0 || wallpaperProcess.running)
            return;

        let cleanPath = pendingWallpaperPath;
        pendingWallpaperPath = "";
        savedWallpaperPath = cleanPath;
        wallpaperProcess.command = [
            Quickshell.env("HOME") + "/.config/scripts/wallpaper/wallpaper_select.sh",
            cleanPath
        ];
        wallpaperProcess.running = true;
    }

    FileView {
        id: savedWallpaperReader
        path: Quickshell.env("HOME") + "/.config/scripts/wallpaper/wpsave.txt"
    }

    Timer {
        id: wallpaperDebounce
        interval: 150
        repeat: false
        onTriggered: runPendingWallpaper()
    }

    onVisibleChanged: {
        savedWallpaperReader.reload();
        
        if (visible) {
            savedWallpaperPath = normalizedPath(savedWallpaperReader.text());
            
            let findIndex = () => {
                restoringSelection = true;
                let found = false;

                for (let i = 0; i < wallpaperModel.count; i++) {
                    if (normalizedPath(wallpaperModel.get(i, "filePath")) === savedWallpaperPath) {
                        carousel.positionViewAtIndex(i, PathView.Center);
                        carousel.currentIndex = i;
                        found = true;
                        break;
                    }
                }

                if (found)
                    Qt.callLater(() => restoringSelection = false);
                else
                    restoringSelection = false;
            };

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

        Keys.onLeftPressed: decrementCurrentIndex()
        Keys.onRightPressed: incrementCurrentIndex()
        Keys.onUpPressed: decrementCurrentIndex()
        Keys.onDownPressed: incrementCurrentIndex()
        Keys.onReturnPressed: bar.state = "normal"
        Keys.onEnterPressed: bar.state = "normal"
        Keys.onEscapePressed: bar.state = "normal"

        model: wallpaperModel
        
        pathItemCount: 5
        cacheItemCount: 25
        
        preferredHighlightBegin: 0.5
        preferredHighlightEnd: 0.5
        highlightRangeMode: PathView.StrictlyEnforceRange
        
        snapMode: PathView.SnapToItem
        dragMargin: metrics.s(200)

        clip: true

        Process {
            id: wallpaperProcess
            onExited: (code, status) => runPendingWallpaper()
        }

        onCurrentIndexChanged: {
            if (restoringSelection || currentIndex < 0 || currentIndex >= model.count)
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
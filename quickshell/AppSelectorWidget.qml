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
import QtQml.Models 

Item {
    id: appSelectorWidget
    visible: bar.state === "app_selector"
    
    anchors {
        top: parent.top
        topMargin: bar.dropdownWidgetPadding
        horizontalCenter: parent.horizontalCenter
    }
    
    width: parent.width - (bar.dropdownWidgetPadding * 2)
    height: parent.height - (bar.dropdownWidgetPadding * 2)  // Fill available space like power menu

    // Layout constants
    readonly property int searchBarHeight: 32
    readonly property int separatorY: searchBarHeight + 8  // 8px below search bar
    readonly property int gridY: separatorY + 2 + 8  // 8px below separator
    readonly property int gridHeight: bar.appSelectorRowsPerPage * bar.appSelectorCellHeightConst
    readonly property int pageIndicatorHeight: 20

    onVisibleChanged: {
        currentPage = 0;
        resultsGrid.currentIndex = 0;
        resultsGrid.contentY = 0; 
        searchBox.text = "";
        searchBox.forceActiveFocus();
        filteredAppModel.search("");
    }

    DelegateModel {
        id: filteredAppModel
        model: DesktopEntries.applications

        groups: [
            DelegateModelGroup {
                id: visibleItems
                name: "visible"
                includeByDefault: true
            }
        ]

        filterOnGroup: "visible"

        function search(text) {
            var lowerText = text.toLowerCase();
            
            for (var i = 0; i < items.count; ++i) {
                var item = items.get(i);
                var data = item.model.modelData
                var appName = data.name ? data.name : "";
                
                if (text === "" || appName.toLowerCase().includes(lowerText) || data.command.some(element => element.toLowerCase().includes(lowerText)) || data.categories.some(element => element.toLowerCase().includes(lowerText))) {
                    item.inVisible = true;
                } else {
                    item.inVisible = false;
                }
            }
            
            appSelectorWidget.currentPage = 0;
        }
    }

    property int currentPage: 0
    property int columns: 3
    property int itemsPerPage: columns * bar.appSelectorRowsPerPage
    property var appModel: filteredAppModel 
    property int totalPages: Math.ceil(appModel.count / itemsPerPage)

    onTotalPagesChanged: if (currentPage >= totalPages) currentPage = 0

    // Background
    Rectangle {
        anchors.fill: parent
        color: "#181825"
        radius: 15
    }

    // Search bar
    Rectangle {
        id: searchBar
        x: 15
        y: 15
        width: parent.width - 30
        height: appSelectorWidget.searchBarHeight
        color: "#313244"
        radius: 8

        Text {
            id: searchIcon
            x: 12
            anchors.verticalCenter: parent.verticalCenter
            text: "󰍉"
            color: "#89b4fa"
            font.pixelSize: 14
            font.family: "monospace"
        }

        Text {
            x: searchIcon.x + searchIcon.width + 8
            anchors.verticalCenter: parent.verticalCenter
            text: "Search applications..."
            color: "#6c7086"
            font.pixelSize: 14
            font.family: "monospace"
            visible: !searchBox.text && !searchBox.activeFocus
        }

        TextInput {
            id: searchBox
            x: searchIcon.x + searchIcon.width + 8
            width: parent.width - x - 12
            anchors.verticalCenter: parent.verticalCenter
            
            color: "#cdd6f4"
            font.pixelSize: 14
            font.family: "monospace"
            clip: true
            
            onTextChanged: {
                filteredAppModel.search(text)
                resultsGrid.currentIndex = 0
                resultsGrid.contentY = 0
            }

            focus: true 

            Keys.onPressed: (event) => {
                if (event.key === Qt.Key_Up) {
                    resultsGrid.moveCurrentIndexUp();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Down) {
                    resultsGrid.moveCurrentIndexDown();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Left) {
                    resultsGrid.moveCurrentIndexLeft();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Right) {
                    resultsGrid.moveCurrentIndexRight();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Escape) {
                    bar.state = "normal";
                    event.accepted = true;
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    if (resultsGrid.currentItem) {
                        var item = visibleItems.get(resultsGrid.currentIndex);
                        var app = item.model.modelData || item.model;
                        if (app.execute) app.execute();
                        bar.state = "normal";
                    }
                    event.accepted = true;
                }
            }
        }
    }

    // Separator
    Rectangle {
        x: 15
        y: 15 + appSelectorWidget.separatorY
        width: parent.width - 30
        height: 2
        color: "#45475a"
    }

    // Grid
    GridView {
        id: resultsGrid
        x: 15
        y: 15 + appSelectorWidget.gridY
        width: parent.width - 30
        height: appSelectorWidget.gridHeight

        cellWidth: width / appSelectorWidget.columns
        cellHeight: bar.appSelectorCellHeightConst

        model: appSelectorWidget.appModel
        
        interactive: false 
        clip: true
        keyNavigationEnabled: true 

        Behavior on contentY {
            NumberAnimation { duration: 300; easing.type: Easing.InOutQuad }
        }

        onCurrentIndexChanged: {
            if (appSelectorWidget.itemsPerPage > 0) {
                var newPage = Math.floor(currentIndex / appSelectorWidget.itemsPerPage)
                if (newPage !== appSelectorWidget.currentPage) {
                    appSelectorWidget.currentPage = newPage
                    appSelectorWidget.updateGridPosition()
                }
            }
        }

        highlight: Rectangle { 
            color: "#313244"
            radius: 10
            border.width: 2
            border.color: "#89b4fa"
        }
        highlightFollowsCurrentItem: true

        delegate: Item {
            width: resultsGrid.cellWidth
            height: resultsGrid.cellHeight

            property var appData: model.modelData || model 
            property bool isSelected: GridView.isCurrentItem

            Column {
                anchors.centerIn: parent
                spacing: 6
                
                Image {
                    width: 32
                    height: 32
                    anchors.horizontalCenter: parent.horizontalCenter
                    source: {
                        var icon = appData.icon || "";
                        var name = appData.name || "";

                        if (!icon) return "image://icon/application-x-executable";
                        if (name === "JetBrains Toolbox") return "image://icon/jetbrains-toolbox"; 
                        
                        if (icon.startsWith("/") || icon.startsWith("file://")) {
                            var fileName = icon.split("/").pop(); 
                            var iconName = fileName.replace(/\.[^/.]+$/, ""); 
                            return "image://icon/" + iconName;
                        }
                        return "image://icon/" + icon;
                    }

                    sourceSize.width: width
                    sourceSize.height: height
                    mipmap: true
                    smooth: true
                }

                Text {
                    text: appData.name
                    color: "#cdd6f4"
                    font.pixelSize: 11
                    font.bold: isSelected
                    font.family: "monospace"
                    anchors.horizontalCenter: parent.horizontalCenter
                    elide: Text.ElideRight
                    width: resultsGrid.cellWidth - 16
                    horizontalAlignment: Text.AlignHCenter
                }
            }

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (resultsGrid.currentIndex === index) {
                        appData.execute();
                        bar.state = "normal"
                    } else {
                        resultsGrid.currentIndex = index;
                        searchBox.forceActiveFocus();
                    }
                }

                onDoubleClicked: {
                    appData.execute();
                    bar.state = "normal"
                }
            }
        }
    }

    // Page indicator
    Text {
        anchors {
            bottom: parent.bottom
            horizontalCenter: parent.horizontalCenter
            bottomMargin: 10
        }
        text: (appSelectorWidget.currentPage + 1) + " / " + appSelectorWidget.totalPages
        color: "#6c7086"
        font.pixelSize: 11
        font.family: "monospace"
        visible: appSelectorWidget.totalPages > 1
    }

    function nextPage() {
        var nextIndex = (currentPage + 1) * itemsPerPage;
        if (nextIndex < appModel.count) {
            resultsGrid.currentIndex = nextIndex;
        } else if (currentPage < totalPages - 1) {
            resultsGrid.currentIndex = appModel.count - 1;
        }
    }

    function prevPage() {
        var prevIndex = (currentPage - 1) * itemsPerPage;
        if (prevIndex >= 0) {
            resultsGrid.currentIndex = prevIndex;
        } else {
            resultsGrid.currentIndex = 0;
        }
    }

    function updateGridPosition() {
        var startRow = Math.floor((currentPage * itemsPerPage) / columns);
        resultsGrid.contentY = startRow * resultsGrid.cellHeight - resultsGrid.topMargin;
    }
}

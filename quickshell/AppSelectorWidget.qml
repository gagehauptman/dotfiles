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
// 1. Import Models for DelegateModel
import QtQml.Models 

Item {
    id: appSelectorWidget
    visible: bar.state === "app_selector"
    anchors.fill: parent

    onVisibleChanged: {
        currentPage = 0;
        resultsGrid.currentIndex = 0;
        resultsGrid.contentY = 0; 
        searchBox.text = "";
        searchBox.forceActiveFocus();
        // Ensure filter resets when opening
        filteredAppModel.search("");
    }

    // 2. Wrap the source model in a DelegateModel for filtering
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
            
            // Iterate over all items in the base model
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

    // --- Pagination Logic ---
    property int currentPage: 0
    property int columns: 3
    property int itemsPerPage: columns * bar.appSelectorRowsPerPage
    // 3. Update appModel to use the filtered model
    property var appModel: filteredAppModel 
    // Calculate total pages based on the FILTERED count
    property int totalPages: Math.ceil(appModel.count / itemsPerPage)

    onTotalPagesChanged: if (currentPage >= totalPages) currentPage = 0

    // --- Search Bar ---
    Rectangle {
        id: searchBarContainer
        y: 0
        width: parent.width
        height: bar.barHeight
        color: "transparent"

        TextInput {
            id: searchBox
            anchors.fill: parent
            anchors.leftMargin: 20
            anchors.rightMargin: 20
            verticalAlignment: TextInput.AlignVCenter
            
            color: "white"
            font.pixelSize: 14
            clip: true
            
            // 4. Trigger filter on text change
            onTextChanged: filteredAppModel.search(text)

            Text {
                text: "Search..."
                color: "#888"
                visible: !searchBox.text && !searchBox.activeFocus
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
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
                        // FIX: Use 'visibleItems.get()' instead of 'appModel.items.get()'
                        // 'visibleItems' contains only the currently filtered results matching the view.
                        var item = visibleItems.get(resultsGrid.currentIndex);
                        
                        // Handle the specific data structure (DelegateModel wraps data)
                        var app = item.model.modelData || item.model;

                        if (app.execute) app.execute();
                        
                        bar.state = "normal";
                    }
                    event.accepted = true;
                }
            }
        }
    }

    GridView {
        id: resultsGrid
        width: parent.width
        height: bar.appSelectorRowsPerPage * bar.appSelectorCellHeightConst
        y: bar.barHeight + bar.appSelectorOffsetFromBar

        cellWidth: width / columns 
        cellHeight: bar.appSelectorCellHeightConst

        model: appModel // Uses filteredAppModel
        
        interactive: false 
        clip: true
        keyNavigationEnabled: true 

        Behavior on contentY {
            NumberAnimation { duration: 300; easing.type: Easing.InOutQuad }
        }

        onCurrentIndexChanged: {
            if (itemsPerPage > 0) {
                var newPage = Math.floor(currentIndex / itemsPerPage)
                if (newPage !== currentPage) {
                    appSelectorWidget.currentPage = newPage
                    appSelectorWidget.updateGridPosition()
                }
            }
        }

        highlight: Rectangle { color: "lightsteelblue"; radius: bar.dropdownCornerRadius; clip: true }

        delegate: Item {
            width: resultsGrid.cellWidth
            height: resultsGrid.cellHeight

            // 6. Data Access in Delegate
            // In DelegateModel, roles are exposed directly. 
            // We create a helper property to access the data object cleanly
            property var appData: model.modelData || model 

            Column {
                anchors.centerIn: parent
                spacing: 8
                
                Image {
                    id: img
                    width: parent.width / 6
                    height: width
                    anchors.horizontalCenter: parent.horizontalCenter
                    source: {
                        // Access via appData or direct roles (name, icon)
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
                    text: appData.name // Access via helper or direct 'name' role
                    color: "white"
                    font.pointSize: 10
                    anchors.horizontalCenter: parent.horizontalCenter
                    elide: Text.ElideRight
                    width: parent.parent.width - 10
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

    // --- Navigation Functions ---
    // (Unchanged logic, but now works on filtered count)
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

    Text {
        anchors {
            bottom: parent.bottom
            horizontalCenter: parent.horizontalCenter
            bottomMargin: 5
        }
        text: (currentPage + 1) + " / " + totalPages
        color: "white"
        font.pixelSize: 12
        visible: totalPages > 1
    }
}
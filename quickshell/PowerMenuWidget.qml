import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Power Menu
Item {
    id: powerMenuWidget

    readonly property bool isOpen: bar.state === "power_menu"
    visible: isOpen

    anchors {
        top: parent.top
        topMargin: bar.dropdownWidgetPadding
        horizontalCenter: parent.horizontalCenter
    }

    width: parent.width - (bar.dropdownWidgetPadding * 2)
    height: parent.height - (bar.dropdownWidgetPadding * 2)

    property int selectedIndex: 0

    focus: visible
    
    Keys.onLeftPressed: selectedIndex = Math.max(0, selectedIndex - 1)
    Keys.onRightPressed: selectedIndex = Math.min(3, selectedIndex + 1)
    Keys.onReturnPressed: activateSelected()
    Keys.onEnterPressed: activateSelected()
    Keys.onEscapePressed: bar.state = "normal"
    
    function activateSelected() {
        if (selectedIndex === 0) shutdownProc.running = true
        else if (selectedIndex === 1) rebootProc.running = true
        else if (selectedIndex === 2) lockProc.running = true
        else if (selectedIndex === 3) logoutProc.running = true
        bar.state = "normal"
    }

    Process { id: shutdownProc; command: ["systemctl", "poweroff"] }
    Process { id: rebootProc; command: ["systemctl", "reboot"] }
    Process { id: lockProc; command: ["hyprlock"] }
    Process { id: logoutProc; command: ["hyprctl", "dispatch", "exit"] }

    Rectangle {
        anchors.fill: parent
        color: "#181825"
        radius: 15

        ColumnLayout {
            anchors {
                fill: parent
                margins: 15
            }
            spacing: 8

            // Title
            Text {
                text: "Power Options"
                color: "#cdd6f4"
                font.pixelSize: 16
                font.bold: true
                font.family: "monospace"
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
            }

            // Separator
            Rectangle {
                Layout.fillWidth: true
                height: 2
                color: "#45475a"
            }

            // Power options row
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 10

                // Shutdown
                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    color: (powerMenuWidget.selectedIndex === 0) ? "#313244" : "transparent"
                    radius: 10
                    border.width: (powerMenuWidget.selectedIndex === 0) ? 2 : 0
                    border.color: "#f38ba8"

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 6

                        Text {
                            text: "󰐥"
                            color: "#f38ba8"
                            font.pixelSize: 28
                            font.family: "monospace"
                            Layout.alignment: Qt.AlignHCenter
                        }

                        Text {
                            text: "Shutdown"
                            color: "#cdd6f4"
                            font.pixelSize: 11
                            font.bold: true
                            Layout.alignment: Qt.AlignHCenter
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: {
                            powerMenuWidget.selectedIndex = 0
                        }
                        onClicked: {
                            powerMenuWidget.selectedIndex = 0
                            powerMenuWidget.activateSelected()
                        }
                    }
                }

                // Reboot
                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    color: (powerMenuWidget.selectedIndex === 1) ? "#313244" : "transparent"
                    radius: 10
                    border.width: (powerMenuWidget.selectedIndex === 1) ? 2 : 0
                    border.color: "#fab387"

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 6

                        Text {
                            text: "󰜉"
                            color: "#fab387"
                            font.pixelSize: 28
                            font.family: "monospace"
                            Layout.alignment: Qt.AlignHCenter
                        }

                        Text {
                            text: "Reboot"
                            color: "#cdd6f4"
                            font.pixelSize: 11
                            font.bold: true
                            Layout.alignment: Qt.AlignHCenter
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: {
                            powerMenuWidget.selectedIndex = 1
                        }
                        onClicked: {
                            powerMenuWidget.selectedIndex = 1
                            powerMenuWidget.activateSelected()
                        }
                    }
                }

                // Lock
                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    color: (powerMenuWidget.selectedIndex === 2) ? "#313244" : "transparent"
                    radius: 10
                    border.width: (powerMenuWidget.selectedIndex === 2) ? 2 : 0
                    border.color: "#89b4fa"

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 6

                        Text {
                            text: "󰌾"
                            color: "#89b4fa"
                            font.pixelSize: 28
                            font.family: "monospace"
                            Layout.alignment: Qt.AlignHCenter
                        }

                        Text {
                            text: "Lock"
                            color: "#cdd6f4"
                            font.pixelSize: 11
                            font.bold: true
                            Layout.alignment: Qt.AlignHCenter
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: {
                            powerMenuWidget.selectedIndex = 2
                        }
                        onClicked: {
                            powerMenuWidget.selectedIndex = 2
                            powerMenuWidget.activateSelected()
                        }
                    }
                }

                // Logout
                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    color: (powerMenuWidget.selectedIndex === 3) ? "#313244" : "transparent"
                    radius: 10
                    border.width: (powerMenuWidget.selectedIndex === 3) ? 2 : 0
                    border.color: "#f9e2af"

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 6

                        Text {
                            text: "󰍃"
                            color: "#f9e2af"
                            font.pixelSize: 28
                            font.family: "monospace"
                            Layout.alignment: Qt.AlignHCenter
                        }

                        Text {
                            text: "Logout"
                            color: "#cdd6f4"
                            font.pixelSize: 11
                            font.bold: true
                            Layout.alignment: Qt.AlignHCenter
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: {
                            powerMenuWidget.selectedIndex = 3
                        }
                        onClicked: {
                            powerMenuWidget.selectedIndex = 3
                            powerMenuWidget.activateSelected()
                        }
                    }
                }
            }
        }
    }
}

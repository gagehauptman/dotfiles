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
    property var powerActions: [
        {
            label: "Shutdown",
            icon: "󰐥",
            color: "#f38ba8",
            command: ["systemctl", "poweroff"]
        },
        {
            label: "Reboot",
            icon: "󰜉",
            color: "#fab387",
            command: ["systemctl", "reboot"]
        },
        {
            label: "Lock",
            icon: "󰌾",
            color: "#89b4fa",
            command: ["hyprlock"]
        },
        {
            label: "Logout",
            icon: "󰍃",
            color: "#f9e2af",
            command: ["hyprctl", "dispatch", "exit"]
        }
    ]

    focus: visible

    Keys.onLeftPressed: selectedIndex = Math.max(0, selectedIndex - 1)
    Keys.onRightPressed: selectedIndex = Math.min(powerActions.length - 1, selectedIndex + 1)
    Keys.onReturnPressed: activateSelected()
    Keys.onEnterPressed: activateSelected()
    Keys.onEscapePressed: bar.state = "normal"

    function activateSelected() {
        actionProc.command = powerActions[selectedIndex].command
        actionProc.running = true
        bar.state = "normal"
    }

    Process {
        id: actionProc
        running: false
    }

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

            Text {
                text: "Power Options"
                color: "#cdd6f4"
                font.pixelSize: 16
                font.bold: true
                font.family: "monospace"
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
            }

            Rectangle {
                Layout.fillWidth: true
                height: 2
                color: "#45475a"
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 10

                Repeater {
                    model: powerMenuWidget.powerActions

                    delegate: Rectangle {
                        required property int index
                        required property var modelData

                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        color: powerMenuWidget.selectedIndex === index ? "#313244" : "transparent"
                        radius: 10
                        border.width: powerMenuWidget.selectedIndex === index ? 2 : 0
                        border.color: modelData.color

                        ColumnLayout {
                            anchors.centerIn: parent
                            spacing: 6

                            Text {
                                text: modelData.icon
                                color: modelData.color
                                font.pixelSize: 28
                                font.family: "monospace"
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Text {
                                text: modelData.label
                                color: "#cdd6f4"
                                font.pixelSize: 11
                                font.bold: true
                                Layout.alignment: Qt.AlignHCenter
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            onEntered: powerMenuWidget.selectedIndex = index
                            onClicked: {
                                powerMenuWidget.selectedIndex = index
                                powerMenuWidget.activateSelected()
                            }
                        }
                    }
                }
            }
        }
    }
}

// Dashboard card hosting an in-process Bevy app (bevy/ in the dotfiles).
// `options.app` names an app built by bevy/build.sh (apps/<name>); the `Bevy`
// QML module only exists on machines that ran it, so it is loaded indirectly
// and a missing module or app shows a hint instead of breaking the preset.
// Toggles and buttons the app declares are drawn along the bottom, its
// readouts in the title line, and its settings behind a gear at the end of
// the pill row. Settings and toggles are remembered per device in
// $XDG_STATE_HOME/quickshell/bevy-<app>.json and handed back to the app at
// the next start as options.settings. `options.controls` / `options.info` =
// false hide the pills and readouts.
import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import Quickshell
import Quickshell.Io
import "themes"

Item {
  id: bevyWidget
  property var options: ({})
  property string app: ""            // set by a registry entry's props; else from the preset options
  readonly property string appName: app !== "" ? app : (bevyWidget.options.app ?? "planet")
  readonly property string library: root.home + "/.config/quickshell/modules/Bevy/apps/" + appName + "/lib" + appName + ".so"
  // Options for the app: the preset entry's object plus the shell's colours
  readonly property string optionsJson: {
    let c = Theme.colors, hex = v => "#" + [v.r, v.g, v.b].map(x => Math.round(x * 255).toString(16).padStart(2, "0")).join("")
    let theme = { background: hex(c.background), panel: hex(c.panel), panelDeep: hex(c.panelDeep), inset: hex(c.inset), border: hex(c.border),
                  textPrimary: hex(c.textPrimary), textSecondary: hex(c.textSecondary), textMuted: hex(c.textMuted),
                  red: hex(c.red), orange: hex(c.orange), yellow: hex(c.yellow), green: hex(c.green), teal: hex(c.teal), cyan: hex(c.cyan),
                  blue: hex(c.blue), indigo: hex(c.indigo), violet: hex(c.violet), lavender: hex(c.lavender), pink: hex(c.pink) }
    return JSON.stringify(Object.assign({}, bevyWidget.options, { theme: theme, scale: Screen.devicePixelRatio, settings: bevyWidget.saved }))
  }
  readonly property var ui: view.item && view.item.ui ? view.item.ui : ({})
  readonly property var controls: (bevyWidget.options.controls ?? true) && Array.isArray(ui.controls) ? ui.controls : []
  readonly property var settings: Array.isArray(ui.settings) ? ui.settings : []
  readonly property var infos: (bevyWidget.options.info ?? true) && Array.isArray(ui.info) ? ui.info : []
  property bool settingsOpen: false

  // Remembered control values, id -> string, per app and device
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (root.home + "/.local/state")) + "/quickshell"
  readonly property string statePath: stateDir + "/bevy-" + appName + ".json"
  property var saved: ({})
  property bool savedLoaded: false
  FileView {
    id: stateFile
    path: bevyWidget.statePath
    printErrors: false
    onLoaded: {
      try {
        let s = JSON.parse(text())
        if (s && typeof s === "object") bevyWidget.saved = s
      } catch (e) {
        console.warn("bevy " + bevyWidget.appName + ": ignoring invalid " + bevyWidget.statePath + ": " + e.message)
      }
      bevyWidget.savedLoaded = true
    }
    onLoadFailed: bevyWidget.savedLoaded = true
    onSaveFailed: error => console.error("bevy " + bevyWidget.appName + ": could not write " + bevyWidget.statePath + " (FileViewError " + error + ")")
  }
  Timer { interval: 700; running: !bevyWidget.savedLoaded; onTriggered: bevyWidget.savedLoaded = true }
  onSavedLoadedChanged: if (savedLoaded && view.status === Loader.Null) view.setSource("BevyCard.qml", { library: Qt.binding(() => bevyWidget.library), options: Qt.binding(() => bevyWidget.optionsJson) })

  function persistable(id) {
    let c = bevyWidget.controls.concat(bevyWidget.settings).find(c => c.id === id)
    return c !== undefined && c.type !== "button"
  }
  function send(id, value) {
    if (view.item) view.item.send(id, value)
    let s = Object.assign({}, bevyWidget.saved)
    if (id === "settings.reset") s = {}
    else if (persistable(id)) s[id] = String(value)
    else return
    bevyWidget.saved = s
    stateFile.setText(JSON.stringify(s, null, 1) + "\n")
  }
  function withAlpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  // Settings grouped by section, in declaration order
  readonly property var sections: {
    let out = [], byName = {}
    for (let s of bevyWidget.settings) {
      let name = s.section ?? ""
      if (!(name in byName)) { byName[name] = { name: name, items: [] } out.push(byName[name]) }
      byName[name].items.push(s)
    }
    return out
  }

  Rectangle {
    anchors.fill: parent
    color: Theme.colors.panel
    radius: metrics.radiusLarge

    Text {
      id: title
      anchors { top: parent.top; left: parent.left; margins: metrics.spacingLarge }
      text: "󰊗  " + (bevyWidget.options.title ?? bevyWidget.appName)
      color: Theme.colors.textPrimary
      font.pixelSize: metrics.fontLarge
      font.bold: true
      font.family: Theme.fonts.mono
    }

    // Readouts: "label value" pairs from the app, right of the title
    Row {
      anchors { right: parent.right; verticalCenter: title.verticalCenter; rightMargin: metrics.spacingLarge }
      spacing: metrics.spacingSmall * 2
      Repeater {
        model: bevyWidget.infos
        Row {
          spacing: 5
          Text {
            visible: text !== ""
            text: modelData.label ?? ""
            color: Theme.colors.textMuted
            font.pixelSize: metrics.fontSmall
            font.family: Theme.fonts.mono
          }
          Text {
            text: modelData.value ?? ""
            color: Theme.colors.textSecondary
            font.pixelSize: metrics.fontSmall
            font.family: Theme.fonts.mono
          }
        }
      }
    }

    Loader {
      id: view
      anchors { top: title.bottom; left: parent.left; right: parent.right; bottom: parent.bottom; margins: metrics.spacingSmall }
      // created once the remembered settings are in (see onSavedLoadedChanged)
    }

    // Settings panel: the app's sections of sliders, choices, text and toggles
    Rectangle {
      id: panel
      visible: bevyWidget.settingsOpen && bevyWidget.settings.length > 0
      anchors { top: title.bottom; right: parent.right; bottom: pills.top; margins: metrics.spacingSmall }
      width: Math.min(360, parent.width * 0.55)
      radius: metrics.radiusLarge / 2
      color: bevyWidget.withAlpha(Theme.colors.panelDeep, 0.96)
      border.width: Theme.bw(1)
      border.color: Theme.colors.border
      MouseArea { anchors.fill: parent; hoverEnabled: true; onWheel: wheel => wheel.accepted = true }   // keeps the globe from zooming under it
      Flickable {
        anchors { fill: parent; margins: metrics.spacingSmall }
        contentHeight: settingsColumn.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Column {
          id: settingsColumn
          width: parent.width
          spacing: metrics.spacingSmall
          Repeater {
            model: bevyWidget.sections
            Column {
              width: settingsColumn.width
              spacing: metrics.spacingSmall / 2
              Text {
                visible: modelData.name !== ""
                text: modelData.name
                color: Theme.colors.textMuted
                font.pixelSize: metrics.fontSmall
                font.bold: true
                font.family: Theme.fonts.mono
                topPadding: metrics.spacingSmall
              }
              Repeater {
                model: modelData.items
                Loader {
                  width: settingsColumn.width
                  property var setting: modelData
                  sourceComponent: modelData.type === "slider" ? sliderRow
                                 : modelData.type === "select" ? selectRow
                                 : modelData.type === "multi" ? multiRow
                                 : modelData.type === "text" ? textRow
                                 : modelData.type === "button" ? buttonRow : toggleRow
                }
              }
            }
          }
        }
      }
    }

    // Controls: pill toggles and buttons over the bottom of the scene, then the gear
    Flow {
      id: pills
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: metrics.spacingLarge }
      spacing: metrics.spacingSmall
      visible: bevyWidget.controls.length > 0 || bevyWidget.settings.length > 0
      Repeater {
        model: bevyWidget.controls
        Rectangle {
          readonly property bool isToggle: modelData.type === "toggle"
          readonly property bool on: isToggle && modelData.on === true
          height: metrics.fontSmall + 10
          width: pillText.implicitWidth + 16
          radius: height / 2
          color: on ? bevyWidget.withAlpha(Theme.colors.accent, 0.28) : bevyWidget.withAlpha(Theme.colors.panelDeep, 0.78)
          border.width: Theme.bw(1)
          border.color: on ? Theme.colors.accent : Theme.colors.border
          opacity: pillArea.pressed ? 0.6 : 1
          Text {
            id: pillText
            anchors.centerIn: parent
            text: modelData.label ?? modelData.id
            color: on ? Theme.colors.textPrimary : Theme.colors.textSecondary
            font.pixelSize: metrics.fontSmall
            font.family: Theme.fonts.mono
          }
          MouseArea {
            id: pillArea
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: bevyWidget.send(modelData.id, isToggle ? (on ? "false" : "true") : "")
          }
        }
      }
      Rectangle {
        visible: bevyWidget.settings.length > 0
        height: metrics.fontSmall + 10
        width: height
        radius: height / 2
        color: bevyWidget.settingsOpen ? bevyWidget.withAlpha(Theme.colors.accent, 0.28) : bevyWidget.withAlpha(Theme.colors.panelDeep, 0.78)
        border.width: Theme.bw(1)
        border.color: bevyWidget.settingsOpen ? Theme.colors.accent : Theme.colors.border
        Text {
          anchors.centerIn: parent
          text: "\u{f0493}"   // nf-md-cog
          color: bevyWidget.settingsOpen ? Theme.colors.textPrimary : Theme.colors.textSecondary
          font.pixelSize: metrics.fontSmall + 2
          font.family: Theme.fonts.mono
        }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: bevyWidget.settingsOpen = !bevyWidget.settingsOpen }
      }
    }
  }

  // ---- settings rows. Each Loader sets `setting` (the control) and sends events through bevyWidget.send.
  component SettingLabel: Text {
    color: Theme.colors.textSecondary
    font.pixelSize: metrics.fontSmall
    font.family: Theme.fonts.mono
    elide: Text.ElideRight
  }
  component Pill: Rectangle {
    property bool on: false
    property string label: ""
    signal clicked()
    height: metrics.fontSmall + 8
    width: pillLabel.implicitWidth + 14
    radius: height / 2
    color: on ? bevyWidget.withAlpha(Theme.colors.accent, 0.28) : bevyWidget.withAlpha(Theme.colors.panel, 0.9)
    border.width: Theme.bw(1)
    border.color: on ? Theme.colors.accent : Theme.colors.border
    Text { id: pillLabel; anchors.centerIn: parent; text: parent.label; color: parent.on ? Theme.colors.textPrimary : Theme.colors.textSecondary; font.pixelSize: metrics.fontSmall; font.family: Theme.fonts.mono }
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: parent.clicked() }
  }

  Component {
    id: toggleRow
    Item {
      height: metrics.fontSmall + 12
      SettingLabel { anchors { left: parent.left; verticalCenter: parent.verticalCenter } width: parent.width - 60; text: setting.label }
      Pill { anchors { right: parent.right; verticalCenter: parent.verticalCenter } on: setting.on === true; label: on ? "on" : "off"; onClicked: bevyWidget.send(setting.id, on ? "false" : "true") }
    }
  }
  Component {
    id: buttonRow
    Item {
      height: metrics.fontSmall + 14
      Pill { anchors { left: parent.left; verticalCenter: parent.verticalCenter } label: setting.label; onClicked: bevyWidget.send(setting.id, "") }
    }
  }
  Component {
    id: sliderRow
    Column {
      spacing: 3
      // the app's value, or the handle while it is being dragged
      property bool dragging: false
      property real dragValue: 0
      readonly property real live: dragging ? dragValue : Number(setting.value)
      Item {
        width: parent.width; height: metrics.fontSmall + 4
        SettingLabel { anchors.left: parent.left; width: parent.width - 70; text: setting.label }
        SettingLabel { anchors.right: parent.right; text: Number(live).toLocaleString(Qt.locale("C"), "f", setting.step >= 1 ? 0 : (setting.step >= 0.1 ? 1 : 2)); color: Theme.colors.textPrimary }
      }
      Item {
        id: track
        width: parent.width; height: 16
        Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 3; radius: 1.5; color: Theme.colors.border }
        Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width * Math.max(0, Math.min(1, (live - setting.min) / (setting.max - setting.min))); height: 3; radius: 1.5; color: Theme.colors.accent }
        Rectangle { x: parent.width * Math.max(0, Math.min(1, (live - setting.min) / (setting.max - setting.min))) - 6; anchors.verticalCenter: parent.verticalCenter; width: 12; height: 12; radius: 6; color: Theme.colors.textPrimary }
        MouseArea {
          anchors.fill: parent
          function at(x) {
            let f = Math.max(0, Math.min(1, x / width))
            let v = setting.min + f * (setting.max - setting.min)
            let st = setting.step > 0 ? setting.step : 0
            if (st > 0) v = Math.round(v / st) * st
            return Math.max(setting.min, Math.min(setting.max, v))
          }
          onPressed: mouse => { dragging = true; dragValue = at(mouse.x) }
          onPositionChanged: mouse => { if (pressed) dragValue = at(mouse.x) }
          onReleased: mouse => { let v = at(mouse.x); dragging = false; bevyWidget.send(setting.id, String(Math.round(v * 10000) / 10000)) }
        }
      }
    }
  }
  Component {
    id: selectRow
    Column {
      spacing: 3
      SettingLabel { width: parent.width; text: setting.label }
      Flow {
        width: parent.width; spacing: 4
        Repeater {
          model: setting.options
          Pill { on: modelData === setting.value; label: modelData; onClicked: bevyWidget.send(setting.id, modelData) }
        }
      }
    }
  }
  Component {
    id: multiRow
    Column {
      spacing: 3
      SettingLabel { width: parent.width; text: setting.label }
      Flow {
        width: parent.width; spacing: 4
        Repeater {
          model: setting.options
          Pill {
            on: (setting.values ?? []).indexOf(modelData) >= 0
            label: modelData
            onClicked: {
              let vs = (setting.values ?? []).slice()
              let i = vs.indexOf(modelData)
              if (i >= 0) vs.splice(i, 1); else vs.push(modelData)
              bevyWidget.send(setting.id, vs.join(","))
            }
          }
        }
      }
    }
  }
  Component {
    id: textRow
    Column {
      spacing: 3
      SettingLabel { width: parent.width; text: setting.label }
      Rectangle {
        width: parent.width; height: metrics.fontSmall + 12
        radius: 4
        color: bevyWidget.withAlpha(Theme.colors.panel, 0.9)
        border.width: Theme.bw(1)
        border.color: field.activeFocus ? Theme.colors.accent : Theme.colors.border
        TextInput {
          id: field
          anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
          verticalAlignment: TextInput.AlignVCenter
          text: setting.value ?? ""
          color: Theme.colors.textPrimary
          font.pixelSize: metrics.fontSmall
          font.family: Theme.fonts.mono
          clip: true
          selectByMouse: true
          onEditingFinished: if (text !== (setting.value ?? "")) bevyWidget.send(setting.id, text)
          Text { visible: !field.text && !field.activeFocus; anchors.fill: parent; verticalAlignment: Text.AlignVCenter; text: setting.hint ?? ""; color: Theme.colors.textMuted; font: field.font }
        }
      }
    }
  }

    Text {
      visible: view.status === Loader.Error || (view.item && view.item.error !== "")
      anchors.centerIn: parent
      width: parent.width - metrics.spacingLarge * 2
      wrapMode: Text.WordWrap
      horizontalAlignment: Text.AlignHCenter
      text: view.status === Loader.Error
          ? "Bevy module not built — run bevy/build.sh, then restart quickshell with QSG_RHI_BACKEND=vulkan and QML2_IMPORT_PATH=~/.config/quickshell/modules"
          : (view.item ? view.item.error : "")
      color: Theme.colors.textMuted
      font.pixelSize: metrics.fontSmall
      font.family: Theme.fonts.mono
    }
}

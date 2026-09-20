// Dashboard card hosting an in-process Bevy app (bevy/ in the dotfiles).
// `options.app` names an app built by bevy/build.sh (apps/<name>); the `Bevy`
// QML module only exists on machines that ran it, so it is loaded indirectly
// and a missing module or app shows a hint instead of breaking the preset.
import QtQuick
import QtQuick.Layouts
import "themes"

Item {
  id: bevyWidget
  property var options: ({})
  readonly property string app: bevyWidget.options.app ?? "planet"
  readonly property string library: root.home + "/.config/quickshell/modules/Bevy/apps/" + app + "/lib" + app + ".so"

  Rectangle {
    anchors.fill: parent
    color: Theme.colors.panel
    radius: metrics.radiusLarge

    Text {
      id: title
      anchors { top: parent.top; left: parent.left; margins: metrics.spacingLarge }
      text: "󰊗  " + (bevyWidget.options.title ?? bevyWidget.app)
      color: Theme.colors.textPrimary
      font.pixelSize: metrics.fontLarge
      font.bold: true
      font.family: "monospace"
    }

    Loader {
      id: view
      anchors { top: title.bottom; left: parent.left; right: parent.right; bottom: parent.bottom; margins: metrics.spacingSmall }
      Component.onCompleted: setSource("BevyCard.qml", { library: Qt.binding(() => bevyWidget.library) })
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
      font.family: "monospace"
    }
  }
}

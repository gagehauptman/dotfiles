import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"

ThreeRowWidget {
  id: weatherWidget

  title: "󰋜  " + cityName

  property string cityName: "..."
  property int weatherCode: 0
  property real temperature: 0
  property int humidity: 0
  property real windSpeed: 0

  function weatherIcon(code) {
    if (code === 0) return "󰖙"
    if (code <= 3) return "󰖐"
    if (code <= 49) return "󰖑"
    if (code <= 59) return "󰖗"
    if (code <= 69) return "󰖖"
    if (code <= 79) return "󰖘"
    if (code <= 84) return "󰖖"
    if (code <= 86) return "󰖘"
    if (code >= 95) return "󰖓"
    return "󰖐"
  }

  function weatherDesc(code) {
    if (code === 0) return "Clear"
    if (code === 1) return "Mostly Clear"
    if (code === 2) return "Partly Cloudy"
    if (code === 3) return "Overcast"
    if (code <= 49) return "Foggy"
    if (code <= 55) return "Drizzle"
    if (code <= 59) return "Freezing Drizzle"
    if (code <= 63) return "Rain"
    if (code <= 65) return "Heavy Rain"
    if (code <= 67) return "Freezing Rain"
    if (code <= 75) return "Snow"
    if (code <= 77) return "Snow Grains"
    if (code <= 82) return "Rain Showers"
    if (code <= 86) return "Snow Showers"
    if (code >= 95) return "Thunderstorm"
    return "Unknown"
  }

  function weatherColor(code) {
    if (code === 0) return "#f9e2af"
    if (code <= 3) return "#9399b2"
    if (code <= 49) return "#9399b2"
    if (code <= 69) return "#89b4fa"
    if (code <= 79) return "#cdd6f4"
    if (code <= 86) return "#cdd6f4"
    if (code >= 95) return "#f38ba8"
    return "#cdd6f4"
  }

  Process {
    id: weatherProc
    command: ["bash", root.home + "/.config/scripts/polls/weatherpoll.sh"]
    running: true

    stdout: StdioCollector {
      onStreamFinished: {
        let parts = this.text.trim().split('|')
        if (parts.length === 5) {
          weatherWidget.cityName = parts[0]
          weatherWidget.weatherCode = parseInt(parts[1])
          weatherWidget.temperature = parseFloat(parts[2])
          weatherWidget.humidity = parseInt(parts[3])
          weatherWidget.windSpeed = parseFloat(parts[4])
        }
      }
    }
  }

  Timer {
    interval: 300000
    running: true
    repeat: true
    onTriggered: weatherProc.running = true
  }

  middleContent: Component {
    RowLayout {
      spacing: 10

      Text {
        text: weatherWidget.weatherIcon(weatherWidget.weatherCode)
        color: weatherWidget.weatherColor(weatherWidget.weatherCode)
        font.pixelSize: 38
        font.family: "monospace"
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.alignment: Qt.AlignVCenter
        spacing: 2

        Text {
          text: weatherWidget.temperature.toFixed(1) + "°C"
          color: "#cdd6f4"
          font.pixelSize: 28
          font.bold: true
          font.family: "Noto Sans"
        }

        Text {
          text: weatherWidget.weatherDesc(weatherWidget.weatherCode)
          color: weatherWidget.weatherColor(weatherWidget.weatherCode)
          font.pixelSize: 12
          font.family: "Noto Sans"
        }
      }
    }
  }

  footerContent: Component {
    RowLayout {
      spacing: 15

      RowLayout {
        spacing: 4
        Text { text: "󰖎"; color: "#94e2d5"; font.pixelSize: 12; font.family: "monospace"; font.bold: true }
        Text { text: weatherWidget.humidity + "%"; color: "#a6adc8"; font.pixelSize: 11 }
      }

      RowLayout {
        spacing: 4
        Text { text: "󰖝"; color: "#89b4fa"; font.pixelSize: 12; font.family: "monospace"; font.bold: true }
        Text { text: weatherWidget.windSpeed.toFixed(0) + " km/h"; color: "#a6adc8"; font.pixelSize: 11 }
      }
    }
  }

  Component.onCompleted: {
    weatherProc.running = true
  }
}

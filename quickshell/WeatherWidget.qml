import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"
import "themes"

ThreeRowWidget {
  id: weatherWidget

  title: "󰋜  " + cityName

  // Preset options: { "location": "lat,lon" | "Place name", "label": "Shown name" }.
  // Empty location = geolocate by IP (the script's default).
  readonly property string location: typeof options.location === "string" ? options.location : ""
  readonly property string label: typeof options.label === "string" ? options.label : ""

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
    if (code === 0) return Theme.colors.yellow
    if (code <= 3) return Theme.colors.textMuted
    if (code <= 49) return Theme.colors.textMuted
    if (code <= 69) return Theme.colors.blue
    if (code <= 79) return Theme.colors.textPrimary
    if (code <= 86) return Theme.colors.textPrimary
    if (code >= 95) return Theme.colors.red
    return Theme.colors.textPrimary
  }

  PollProcess {
    id: weatherProc
    command: ["bash", root.home + "/.config/scripts/polls/weatherpoll.sh", weatherWidget.location, weatherWidget.label]
    interval: 300000
    onOutput: text => {
      let parts = text.split('|')
      if (parts.length === 5) {
        weatherWidget.cityName = parts[0]
        weatherWidget.weatherCode = parseInt(parts[1])
        weatherWidget.temperature = parseFloat(parts[2])
        weatherWidget.humidity = parseInt(parts[3])
        weatherWidget.windSpeed = parseFloat(parts[4])
      }
    }
  }

  middleContent: Component {
    RowLayout {
      spacing: metrics.spacingNormal

      Text {
        text: weatherWidget.weatherIcon(weatherWidget.weatherCode)
        color: weatherWidget.weatherColor(weatherWidget.weatherCode)
        font.pixelSize: metrics.fontHuge
        font.family: "monospace"
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.alignment: Qt.AlignVCenter
        spacing: metrics.spacingTiny

        Text {
          text: weatherWidget.temperature.toFixed(1) + "°C"
          color: Theme.colors.textPrimary
          font.pixelSize: metrics.fontXL
          font.bold: true
          font.family: "Noto Sans"
        }

        Text {
          text: weatherWidget.weatherDesc(weatherWidget.weatherCode)
          color: weatherWidget.weatherColor(weatherWidget.weatherCode)
          font.pixelSize: metrics.fontSmall
          font.family: "Noto Sans"
        }
      }
    }
  }

  footerContent: Component {
    RowLayout {
      spacing: metrics.spacingLarge

      RowLayout {
        spacing: metrics.spacingTiny
        Text { text: "󰖎"; color: Theme.colors.teal; font.pixelSize: metrics.fontSmall; font.family: "monospace"; font.bold: true }
        Text { text: weatherWidget.humidity + "%"; color: Theme.colors.textSecondary; font.pixelSize: metrics.fontTiny }
      }

      RowLayout {
        spacing: metrics.spacingTiny
        Text { text: "󰖝"; color: Theme.colors.blue; font.pixelSize: metrics.fontSmall; font.family: "monospace"; font.bold: true }
        Text { text: weatherWidget.windSpeed.toFixed(0) + " km/h"; color: Theme.colors.textSecondary; font.pixelSize: metrics.fontTiny }
      }
    }
  }
}

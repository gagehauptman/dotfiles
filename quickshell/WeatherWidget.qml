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
        if (typeof dashState !== "undefined") {
          let c = weatherWidget.weatherCode
          let l = c >= 95 ? Status.caution : (c === 65 || c === 67 || c === 75 || c === 82 || c === 86) ? Status.advisory : Status.nominal
          dashState.report("wx", "WX", "weather", l, l > 0 ? weatherWidget.weatherDesc(c).toUpperCase() : "", 1000000)
        }
      }
    }
  }

  middleContent: Component {
    RowLayout {
      spacing: weatherWidget.fs(metrics.spacingNormal)

      Text {
        text: weatherWidget.weatherIcon(weatherWidget.weatherCode)
        color: weatherWidget.weatherColor(weatherWidget.weatherCode)
        font.pixelSize: weatherWidget.fs(weatherWidget.compact ? metrics.fontXL : metrics.fontHuge)
        font.family: Theme.fonts.mono
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.alignment: Qt.AlignVCenter
        Layout.fillWidth: true
        spacing: metrics.spacingTiny

        Text {
          Layout.fillWidth: true
          // Whole degrees when squished; the decimal is the first thing to go
          text: weatherWidget.temperature.toFixed(weatherWidget.compact ? 0 : 1) + "°C"
          color: Theme.colors.textPrimary
          font.pixelSize: weatherWidget.fs(weatherWidget.compact ? metrics.fontLarge * 1.25 : metrics.fontXL)
          font.bold: true
          font.family: Theme.fonts.ui
          font.features: { "tnum": 1, "lnum": 1 }
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          visible: weatherWidget.middleHeight >= weatherWidget.fs(metrics.fontXL + metrics.fontSmall)
          text: weatherWidget.weatherDesc(weatherWidget.weatherCode)
          color: weatherWidget.weatherColor(weatherWidget.weatherCode)
          font.pixelSize: weatherWidget.fs(metrics.fontSmall)
          font.family: Theme.fonts.ui
          elide: Text.ElideRight
        }
      }
    }
  }

  footerContent: Component {
    RowLayout {
      spacing: weatherWidget.fs(weatherWidget.compact ? metrics.spacingNormal : metrics.spacingLarge)

      RowLayout {
        spacing: metrics.spacingTiny
        Text { text: "󰖎"; color: Theme.colors.teal; font.pixelSize: weatherWidget.fs(metrics.fontSmall); font.family: Theme.fonts.mono; font.bold: true }
        Text { font.family: Theme.fonts.ui; font.features: { "tnum": 1, "lnum": 1 }; text: weatherWidget.humidity + "%"; color: Theme.colors.textSecondary; font.pixelSize: weatherWidget.fs(metrics.fontTiny) }
      }

      RowLayout {
        spacing: metrics.spacingTiny
        Layout.fillWidth: true
        Text { text: "󰖝"; color: Theme.colors.blue; font.pixelSize: weatherWidget.fs(metrics.fontSmall); font.family: Theme.fonts.mono; font.bold: true }
        Text { font.family: Theme.fonts.ui; font.features: { "tnum": 1, "lnum": 1 }; text: weatherWidget.windSpeed.toFixed(0) + " km/h"; color: Theme.colors.textSecondary; font.pixelSize: weatherWidget.fs(metrics.fontTiny); Layout.fillWidth: true; elide: Text.ElideRight }
      }
    }
  }
}

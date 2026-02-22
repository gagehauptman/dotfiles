import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

Item {
  id: weatherWidget
  
  visible: bar.state === "dashboard"
  
  property string cityName: "..."
  property int weatherCode: 0
  property real temperature: 0
  property int humidity: 0
  property real windSpeed: 0
  
  implicitHeight: 190
  
  // WMO weather code to icon + description
  function weatherIcon(code) {
    if (code === 0) return "󰖙"          // Clear sky
    if (code <= 3) return "󰖐"          // Partly cloudy / overcast
    if (code <= 49) return "󰖑"         // Fog
    if (code <= 59) return "󰖗"         // Drizzle
    if (code <= 69) return "󰖖"         // Rain
    if (code <= 79) return "󰖘"         // Snow
    if (code <= 84) return "󰖖"         // Rain showers
    if (code <= 86) return "󰖘"         // Snow showers
    if (code >= 95) return "󰖓"         // Thunderstorm
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
    if (code === 0) return "#f9e2af"      // Yellow - clear
    if (code <= 3) return "#9399b2"       // Gray - cloudy
    if (code <= 49) return "#9399b2"      // Gray - fog
    if (code <= 69) return "#89b4fa"      // Blue - rain
    if (code <= 79) return "#cdd6f4"      // White - snow
    if (code <= 86) return "#cdd6f4"      // White - snow showers
    if (code >= 95) return "#f38ba8"      // Red - thunderstorm
    return "#cdd6f4"
  }
  
  // Weather poller
  Process {
    id: weatherProc
    command: ["bash", "/storage/git/dotfiles/scripts/polls/weatherpoll.sh"]
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
    interval: 300000  // Poll every 5 minutes
    running: true
    repeat: true
    onTriggered: weatherProc.running = true
  }
  
  Rectangle {
    anchors.fill: parent
    color: "#181825"
    radius: 15
    
    ColumnLayout {
      anchors {
        top: parent.top
        left: parent.left
        right: parent.right
        margins: 15
      }
      spacing: 8
      
      // Title
      Text {
        text: "󰋜  " + weatherWidget.cityName
        color: "#cdd6f4"
        font.pixelSize: 16
        font.bold: true
        font.family: "monospace"
        Layout.fillWidth: true
        elide: Text.ElideRight
      }
      
      // Separator
      Rectangle {
        Layout.fillWidth: true
        height: 2
        color: "#45475a"
      }
      
      // Big temperature + icon
      RowLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: 10
        
        // Weather icon
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
          
          // Temperature
          Text {
            text: weatherWidget.temperature.toFixed(1) + "°C"
            color: "#cdd6f4"
            font.pixelSize: 28
            font.bold: true
            font.family: "Noto Sans"
          }
          
          // Condition text
          Text {
            text: weatherWidget.weatherDesc(weatherWidget.weatherCode)
            color: weatherWidget.weatherColor(weatherWidget.weatherCode)
            font.pixelSize: 12
            font.family: "Noto Sans"
          }
        }
      }
      
      // Separator
      Rectangle {
        Layout.fillWidth: true
        height: 2
        color: "#45475a"
      }
      
      // Bottom stats row
      RowLayout {
        Layout.fillWidth: true
        spacing: 15
        
        // Humidity
        RowLayout {
          spacing: 4
          Text {
            text: "󰖎"
            color: "#94e2d5"
            font.pixelSize: 12
            font.family: "monospace"
            font.bold: true
          }
          Text {
            text: weatherWidget.humidity + "%"
            color: "#a6adc8"
            font.pixelSize: 11
          }
        }
        
        // Wind
        RowLayout {
          spacing: 4
          Text {
            text: "󰖝"
            color: "#89b4fa"
            font.pixelSize: 12
            font.family: "monospace"
            font.bold: true
          }
          Text {
            text: weatherWidget.windSpeed.toFixed(0) + " km/h"
            color: "#a6adc8"
            font.pixelSize: 11
          }
        }
      }
    }
  }
  
  Component.onCompleted: {
    weatherProc.running = true
  }
}

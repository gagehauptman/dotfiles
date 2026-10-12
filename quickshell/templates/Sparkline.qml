// History trace: a 1 px polyline over the last N samples (oldest at the left),
// optionally with a faint fill, drawn at low contrast so it reads as texture.
// `mirror` draws a second series (`values2`) below a centre baseline, the
// oscilloscope look used for rx/tx. Repaints only when a sample arrives, never
// per frame. Scale: `max` > 0 fixes the top, else the window's peak (with a floor).
// Feed it from the poll handler: values = values.concat([v]).slice(-Dash.traceSamples)

import QtQuick
import "../themes"

Canvas {
  id: spark

  property var values: []
  property var values2: []
  property bool mirror: false
  property int samples: Dash.traceSamples
  property real max: 0
  property real floor: 1
  property color color: Theme.colors.textSecondary
  property color color2: Theme.colors.textSecondary
  property real lineOpacity: Dash.traceOpacity
  property real fillOpacity: Dash.traceFill
  readonly property real peak: {
    let m = floor
    for (let v of values) m = Math.max(m, v)
    if (mirror) for (let v of values2) m = Math.max(m, v)
    return max > 0 ? max : m
  }

  visible: Dash.tracesEnabled
  renderStrategy: Canvas.Cooperative
  antialiasing: true

  onValuesChanged: requestPaint()
  onValues2Changed: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()
  onColorChanged: requestPaint()
  onVisibleChanged: if (visible) requestPaint()

  function trace(ctx, vals, col, base, span, dir) {
    if (vals.length < 2) return
    let step = (width - 1) / Math.max(1, samples - 1)
    let x0 = width - 1 - (vals.length - 1) * step
    let y = v => base - dir * Math.max(0, Math.min(1, v / peak)) * span
    ctx.beginPath()
    ctx.moveTo(x0, base)
    for (let i = 0; i < vals.length; i++) ctx.lineTo(x0 + i * step, y(vals[i]))
    ctx.lineTo(x0 + (vals.length - 1) * step, base)
    ctx.closePath()
    ctx.fillStyle = Qt.rgba(col.r, col.g, col.b, fillOpacity)
    ctx.fill()
    ctx.beginPath()
    for (let i = 0; i < vals.length; i++) {
      if (i === 0) ctx.moveTo(x0, y(vals[0])); else ctx.lineTo(x0 + i * step, y(vals[i]))
    }
    ctx.strokeStyle = Qt.rgba(col.r, col.g, col.b, lineOpacity)
    ctx.lineWidth = 1
    ctx.stroke()
  }

  onPaint: {
    let ctx = getContext("2d")
    ctx.reset()
    if (!visible || width < 4 || height < 4) return
    if (mirror) {
      let mid = Math.round(height / 2) + 0.5
      ctx.fillStyle = Qt.rgba(Theme.colors.border.r, Theme.colors.border.g, Theme.colors.border.b, 0.6)
      ctx.fillRect(0, mid - 0.5, width, 1)
      trace(ctx, values, color, mid - 1, mid - 2, 1)
      trace(ctx, values2, color2, mid + 1, height - mid - 2, -1)
    } else {
      trace(ctx, values, color, height - 0.5, height - 1.5, 1)
    }
  }
}

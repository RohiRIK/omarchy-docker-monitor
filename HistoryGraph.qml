import QtQuick
import qs.Commons
import "Model.js" as Model

Column {
  id: root
  property var samples: []
  property color foreground: Color.foreground
  property string metric: "cpu"
  readonly property real peak: Math.max(0,
      ...samples.map(function(s) { return s[root.metric] || 0 }))
  spacing: Style.space(3)
  Text {
    textFormat: Text.PlainText
    width: parent.width
    text: (root.metric === "cpu" ? "CPU" : "RAM") + " · peak " +
          (root.metric === "cpu" ? Math.round(root.peak * 10) / 10 + "%" : Model.formatBytes(root.peak))
    color: root.foreground
    font.pixelSize: Style.font.caption
    font.family: Style.font.family
  }
  Canvas {
    id: graph
    width: parent.width
    height: Style.space(38)
    onWidthChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.strokeStyle = Qt.alpha(root.foreground, 0.2)
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(0, height - 1)
      ctx.lineTo(width, height - 1)
      ctx.stroke()
      ctx.strokeStyle = root.metric === "cpu" ? Color.accent : root.foreground
      ctx.lineWidth = 1.5
      ctx.beginPath()
      var connected = false
      root.samples.forEach(function(s, i) {
        var value = s[root.metric]
        if (value === null) { connected = false; return }
        var x = width * i / Math.max(1, root.samples.length - 1)
        var y = height - 2 - (height - 4) * value / Math.max(1, root.peak)
        if (connected) ctx.lineTo(x, y)
        else ctx.moveTo(x, y)
        connected = true
      })
      ctx.stroke()
    }
    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      visible: root.samples.length < 2
      text: "Collecting…"
      color: Qt.alpha(root.foreground, 0.6)
      font.pixelSize: Style.font.caption
    }
  }
  onSamplesChanged: graph.requestPaint()
  onForegroundChanged: graph.requestPaint()
}

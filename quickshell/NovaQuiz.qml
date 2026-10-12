import QtQuick
import "themes"
import "NovaLatex.js" as Latex
import "NovaQuiz.js" as QuizFmt

// One quiz from a ```quiz block in Nova's reply (format and parsing: NovaQuiz.js), drawn inside the chat bubble:
// radio buttons, checkboxes or text fields per question, then Submit, which hands the answers message to the
// chat panel to send as a normal typed turn (Nova grades it; nothing is graded here). Once sent (or found sent in
// the history) the quiz locks and shows what was answered. Answers in progress live in the panel (draft), so a
// delegate scrolled away and back keeps them.
Column {
  id: qz

  property var entry: ({})              // {key, quiz} from QuizFmt.find
  property var draft: ({})              // id -> answer, shared with the panel
  property bool submitted: false
  property bool canSubmit: true         // false while Nova is busy with a turn
  signal edited(var draft)
  signal submit(string message)

  readonly property var quiz: entry.quiz || { title: "", questions: [] }
  property int rev: 0                   // bumped on every answer change (draft is a plain JS object)
  function val(id) { rev; return draft[id] }
  function setVal(id, v) {
    if (submitted) return
    let d = Object.assign({}, draft); d[id] = v; draft = d
    rev++
    edited(draft)
  }
  readonly property int answered: {
    rev
    let n = 0
    for (let q of quiz.questions) {
      let a = draft[q.id]
      if (q.type === "multiple_choice" ? (typeof a === "number" && a >= 0) : q.type === "multi_select" ? (a && a.length) : (a && String(a).trim() !== "")) n++
    }
    return n
  }

  // LaTeX ($..$, $$..$$, \(..\), \[..\]) as rich text, the same renderer as the chat bubbles
  // (a field that is a single $..$ is always math, so a choice like "$2x$" isn't taken for a price)
  function rich(s) {
    let whole = /^\s*\$([^$]+)\$\s*$/.exec(s || "")
    if (whole) return Latex.toHtml(whole[1].trim())
    let ex = Latex.extract(s || ""); return Latex.restore(ex.text, ex.math)
  }

  spacing: metrics.s(8)
  topPadding: metrics.s(4)

  Rectangle { width: parent.width; height: 1; color: Theme.colors.border }

  Row {
    spacing: metrics.spacingSmall
    width: parent.width
    Text {
      id: qicon
      text: qz.submitted ? "󰄬" : "󰠗"
      color: qz.submitted ? Theme.colors.green : Theme.colors.violet
      font.pixelSize: metrics.fontLarge
      font.family: Theme.fonts.mono
    }
    TextEdit {
      width: parent.width - qicon.width - parent.spacing
      text: "**" + qz.rich(qz.quiz.title) + "**" + (qz.submitted ? "  ·  submitted" : "  ·  " + qz.quiz.questions.length + " question" + (qz.quiz.questions.length === 1 ? "" : "s"))
      textFormat: TextEdit.MarkdownText
      readOnly: true; selectByMouse: true
      wrapMode: TextEdit.Wrap
      color: Theme.colors.textPrimary
      font.pixelSize: metrics.fontNormal
      font.family: Theme.fonts.mono
    }
  }
  TextEdit {
    visible: qz.quiz.intro !== ""
    width: parent.width
    text: qz.rich(qz.quiz.intro)
    textFormat: TextEdit.MarkdownText
    readOnly: true; selectByMouse: true
    wrapMode: TextEdit.Wrap
    color: Theme.colors.textMuted
    font.pixelSize: metrics.fontSmall
    font.family: Theme.fonts.mono
  }

  Repeater {
    model: qz.quiz.questions
    Column {
      id: qrow
      required property var modelData
      required property int index
      readonly property var q: modelData
      width: qz.width
      spacing: metrics.s(5)

      TextEdit {
        width: parent.width
        text: "**" + (qrow.index + 1) + ".** " + qz.rich(qrow.q.prompt)
              + (qrow.q.type === "multi_select" ? "  *(select all that apply)*" : "")
        textFormat: TextEdit.MarkdownText
        readOnly: true; selectByMouse: true
        wrapMode: TextEdit.Wrap
        color: Theme.colors.textSecondary
        font.pixelSize: metrics.fontNormal
        font.family: Theme.fonts.mono
      }
      TextEdit {
        visible: qrow.q.hint !== "" && !qz.submitted
        width: parent.width
        leftPadding: metrics.s(14)
        text: "*hint: " + qz.rich(qrow.q.hint) + "*"
        textFormat: TextEdit.MarkdownText
        readOnly: true
        wrapMode: TextEdit.Wrap
        color: Theme.colors.textMuted
        font.pixelSize: metrics.fontSmall
        font.family: Theme.fonts.mono
      }

      // choices: radio (one) or checkbox (several)
      Repeater {
        model: (qrow.q.type === "multiple_choice" || qrow.q.type === "multi_select") ? qrow.q.choices : []
        Rectangle {
          id: opt
          required property string modelData
          required property int index
          readonly property bool multi: qrow.q.type === "multi_select"
          readonly property bool on: {
            let a = qz.val(qrow.q.id)
            return multi ? !!(a && a.indexOf(index) >= 0) : a === index
          }
          x: metrics.s(8)
          width: qrow.width - x
          height: Math.max(optText.implicitHeight, metrics.s(18)) + metrics.s(10)
          radius: metrics.radiusSmall
          color: opt.on ? Qt.rgba(Theme.colors.blue.r, Theme.colors.blue.g, Theme.colors.blue.b, 0.14)
                 : optMouse.containsMouse && !qz.submitted ? Theme.colors.inset : "transparent"
          border.width: opt.on ? 1 : 0
          border.color: Theme.colors.blue
          Rectangle {                        // the radio dot / checkbox
            id: mark
            x: metrics.s(8)
            anchors.verticalCenter: parent.verticalCenter
            width: metrics.s(16); height: width
            radius: opt.multi ? metrics.s(3) : width / 2
            color: "transparent"
            border.width: Math.max(1, metrics.s(1.5))
            border.color: opt.on ? Theme.colors.blue : Theme.colors.textMuted
            Rectangle {
              visible: opt.on && !opt.multi
              anchors.centerIn: parent
              width: parent.width * 0.5; height: width; radius: width / 2
              color: Theme.colors.blue
            }
            Text {
              visible: opt.on && opt.multi
              anchors.centerIn: parent
              text: "󰄬"
              color: Theme.colors.blue
              font.pixelSize: metrics.fontSmall
              font.family: Theme.fonts.mono
            }
          }
          Text {
            id: optText
            x: mark.x + mark.width + metrics.s(8)
            width: parent.width - x - metrics.s(8)
            anchors.verticalCenter: parent.verticalCenter
            text: "**" + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".charAt(opt.index) + ".** " + qz.rich(opt.modelData)
            textFormat: Text.MarkdownText
            wrapMode: Text.Wrap
            color: opt.on ? Theme.colors.textPrimary : Theme.colors.textSecondary
            font.pixelSize: metrics.fontNormal
            font.family: Theme.fonts.mono
          }
          MouseArea {
            id: optMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: !qz.submitted
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (!opt.multi) { qz.setVal(qrow.q.id, opt.index); return }
              let a = (qz.val(qrow.q.id) || []).slice(), k = a.indexOf(opt.index)
              if (k >= 0) a.splice(k, 1); else a.push(opt.index)
              qz.setVal(qrow.q.id, a)
            }
          }
        }
      }

      // typed answers: one line (short / numeric) or a growing box (long)
      Rectangle {
        id: field
        visible: qrow.q.type === "short_answer" || qrow.q.type === "numeric" || qrow.q.type === "long_answer"
        readonly property bool long: qrow.q.type === "long_answer"
        x: metrics.s(8)
        width: qrow.width - x
        height: (long ? Math.max(longEdit.contentHeight, metrics.s(18) * 3) : metrics.s(18)) + metrics.s(14)
        radius: metrics.radiusSmall
        color: Theme.colors.inset
        border.width: (shortEdit.activeFocus || longEdit.activeFocus) ? 1 : 0
        border.color: Theme.colors.blue
        Text {
          x: metrics.s(10); y: metrics.s(7)
          visible: !qz.submitted && (field.long ? longEdit.text === "" : shortEdit.text === "")
          text: qrow.q.type === "numeric" ? "number…" : field.long ? "your answer (Enter for a new line)…" : "your answer…"
          color: Theme.colors.textMuted
          font.pixelSize: metrics.fontNormal
          font.family: Theme.fonts.mono
        }
        TextInput {
          id: shortEdit
          visible: !field.long
          x: metrics.s(10); y: metrics.s(7)
          width: parent.width - metrics.s(20)
          clip: true
          readOnly: qz.submitted
          text: field.long ? "" : (qz.val(qrow.q.id) || "")
          color: Theme.colors.textPrimary
          selectionColor: Theme.colors.blue
          selectByMouse: true
          font.pixelSize: metrics.fontNormal
          font.family: Theme.fonts.mono
          inputMethodHints: qrow.q.type === "numeric" ? Qt.ImhFormattedNumbersOnly : Qt.ImhNone
          onTextEdited: qz.setVal(qrow.q.id, text)
        }
        TextEdit {
          id: longEdit
          visible: field.long
          x: metrics.s(10); y: metrics.s(7)
          width: parent.width - metrics.s(20)
          readOnly: qz.submitted
          wrapMode: TextEdit.Wrap
          selectByMouse: true
          text: field.long ? (qz.val(qrow.q.id) || "") : ""
          color: Theme.colors.textPrimary
          selectionColor: Theme.colors.blue
          font.pixelSize: metrics.fontNormal
          font.family: Theme.fonts.mono
          onTextChanged: if (activeFocus && text !== (qz.val(qrow.q.id) || "")) qz.setVal(qrow.q.id, text)
        }
        MouseArea {                          // focus the field on click anywhere in the box
          anchors.fill: parent
          enabled: !qz.submitted
          cursorShape: Qt.IBeamCursor
          acceptedButtons: Qt.LeftButton
          onPressed: mouse => { (field.long ? longEdit : shortEdit).forceActiveFocus(); mouse.accepted = false }
        }
      }
    }
  }

  // submit row
  Row {
    spacing: metrics.spacingNormal
    visible: !qz.submitted
    Rectangle {
      id: submitBtn
      readonly property bool ok: qz.canSubmit
      width: submitLabel.implicitWidth + metrics.s(28)
      height: metrics.s(32)
      radius: metrics.radiusNormal
      color: ok ? (submitMouse.containsMouse ? Theme.colors.blue : Qt.rgba(Theme.colors.blue.r, Theme.colors.blue.g, Theme.colors.blue.b, 0.8))
                : Theme.colors.inset
      Text {
        id: submitLabel
        anchors.centerIn: parent
        text: "󰒊  Submit"
        color: submitBtn.ok ? Theme.colors.background : Theme.colors.textMuted
        font.pixelSize: metrics.fontNormal
        font.family: Theme.fonts.mono
        font.weight: Font.DemiBold
      }
      MouseArea {
        id: submitMouse
        anchors.fill: parent
        hoverEnabled: true
        enabled: submitBtn.ok
        cursorShape: Qt.PointingHandCursor
        onClicked: qz.submit(QuizFmt.answers(qz.entry, qz.draft))
      }
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: !qz.canSubmit ? "Nova is busy, submit when she's done"
            : qz.answered + " / " + qz.quiz.questions.length + " answered"
      color: Theme.colors.textMuted
      font.pixelSize: metrics.fontSmall
      font.family: Theme.fonts.mono
    }
  }
  Text {
    visible: qz.submitted
    text: "Answers sent to Nova for grading."
    color: Theme.colors.textMuted
    font.pixelSize: metrics.fontSmall
    font.family: Theme.fonts.mono
  }
}

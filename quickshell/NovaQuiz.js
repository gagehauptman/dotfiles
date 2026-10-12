.pragma library

// Quizzes in Nova's replies (rendered by NovaQuiz.qml inside the chat bubble). Nova writes a fenced block:
//
//   ```quiz
//   {"title": "Derivatives", "questions": [
//     {"id": "q1", "type": "multiple_choice", "prompt": "What is $\\frac{d}{dx}x^2$?", "choices": ["$x$", "$2x$"]},
//     {"id": "q2", "type": "numeric", "prompt": "$\\int_0^1 2x\\,dx$ = ?"}]}
//   ```
//
// types: multiple_choice | multi_select | short_answer | numeric | long_answer (aliases accepted, see TYPES).
// The parser is tolerant: smart quotes, trailing commas, unquoted keys, and LaTeX written with single
// backslashes inside JSON strings ("\frac", "\theta": JSON would read \f and \t as escapes) all still work.
// On Submit the widget sends answers() as a normal typed message; parseAnswers() reads it back from history so
// a submitted quiz stays locked and shows what was sent after a reload.

var TYPES = {
  multiple_choice: "multiple_choice", mc: "multiple_choice", single: "multiple_choice", single_choice: "multiple_choice",
  radio: "multiple_choice", choice: "multiple_choice", true_false: "multiple_choice", truefalse: "multiple_choice",
  multi_select: "multi_select", multiple_select: "multi_select", multi: "multi_select", checkbox: "multi_select",
  checkboxes: "multi_select", select_all: "multi_select", multiple_answer: "multi_select",
  short_answer: "short_answer", short: "short_answer", text: "short_answer", fill_in: "short_answer", fill_in_the_blank: "short_answer",
  numeric: "numeric", number: "numeric", numerical: "numeric",
  long_answer: "long_answer", long: "long_answer", essay: "long_answer", free_response: "long_answer", proof: "long_answer"
}
var LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

// ```quiz ... ``` blocks (also "~~~quiz"); an unclosed one at the end is still streaming in
var BLOCK = /^[ \t]*(```+|~~~+)[ \t]*quiz[^\n]*\n([\s\S]*?)^[ \t]*\1[ \t]*$/gm
var OPEN = /^[ \t]*(```+|~~~+)[ \t]*quiz[^\n]*(?:\n|$)/m

function hash(s) {
  var h = 5381
  for (var i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0
  return ("00000" + h.toString(16)).slice(-6)
}

// JSON string contents: keep real escapes, double every backslash that is LaTeX instead
function fixEscapes(src) {
  var out = "", inStr = false
  for (var i = 0; i < src.length; i++) {
    var c = src.charAt(i)
    if (!inStr) { if (c === "\"") inStr = true; out += c; continue }
    if (c === "\"") { inStr = false; out += c; continue }
    if (c === "\n") { out += "\\n"; continue }                 // raw newline inside a string
    if (c === "\t") { out += "\\t"; continue }
    if (c !== "\\") { out += c; continue }
    var d = src.charAt(i + 1), e = src.charAt(i + 2)
    if (d === "\\" || d === "\"" || d === "/") { out += c + d; i++; continue }
    if (d === "u" && /^[0-9a-fA-F]{4}$/.test(src.substr(i + 2, 4))) { out += c + d; i++; continue }
    // \n \t \b \f \r before a lowercase letter is LaTeX (\nabla \theta \beta \frac \rho); else a real escape
    if (/[bfnrt]/.test(d) && !/[a-z]/.test(e)) { out += c + d; i++; continue }
    out += "\\\\"                                             // LaTeX or a stray backslash: keep it literally
  }
  return out
}

function looseJson(src) {
  var s = src.trim().replace(/[“”„‟]/g, "\"")
  if (!/^[\[{]/.test(s)) { var k = s.search(/[\[{]/); if (k >= 0) s = s.slice(k) }
  s = fixEscapes(s)
  try { return JSON.parse(s) } catch (e) {}
  var t = s.replace(/,(\s*[}\]])/g, "$1")                          // trailing commas
  try { return JSON.parse(t) } catch (e) {}
  t = t.replace(/([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:/g, "$1\"$2\":")  // unquoted keys
  try { return JSON.parse(t) } catch (e) {}
  t = t.replace(/[‘’]/g, "'").replace(/'([^'\\\n]*)'(\s*[:,}\]])/g, "\"$1\"$2")   // 'single' quotes
  return JSON.parse(t)
}

function str(x) { return x === undefined || x === null ? "" : (typeof x === "string" ? x : String(x)) }

function normalize(o) {
  if (Array.isArray(o)) o = { questions: o }
  var qs = o.questions || o.items || o.quiz || []
  var seen = {}, out = []
  for (var i = 0; i < qs.length; i++) {
    var q = typeof qs[i] === "string" ? { prompt: qs[i] } : (qs[i] || {})
    var ch = q.choices || q.options || q.answers || []
    if (!Array.isArray(ch)) ch = []
    ch = ch.map(function (c) { return typeof c === "object" && c ? str(c.text || c.label || c.value) : str(c) })
    var tp = TYPES[str(q.type).toLowerCase().replace(/[\s-]+/g, "_")] || (ch.length ? (q.multiple ? "multi_select" : "multiple_choice") : "short_answer")
    if ((tp === "multiple_choice" || tp === "multi_select") && !ch.length)
      ch = /true|false/i.test(str(q.type)) ? ["True", "False"] : []
    if ((tp === "multiple_choice" || tp === "multi_select") && !ch.length) tp = "short_answer"
    var id = str(q.id || q.name) || ("q" + (i + 1))
    id = id.replace(/\s+/g, "_")
    while (seen[id]) id += "_"
    seen[id] = true
    out.push({ id: id, type: tp, prompt: str(q.prompt || q.question || q.q || q.text), choices: ch,
               hint: str(q.hint), points: q.points })
  }
  return { title: str(o.title || o.name) || "Quiz", intro: str(o.intro || o.instructions || o.description), questions: out }
}

// -> [{key, quiz | error}] for every complete block, plus {pending: true} for one still arriving
function find(text) {
  var res = [], m
  BLOCK.lastIndex = 0
  var lastEnd = 0
  while ((m = BLOCK.exec(text)) !== null) {
    var item = { key: hash(m[2].replace(/\s+/g, "")) }
    try {
      item.quiz = normalize(looseJson(m[2]))
      if (!item.quiz.questions.length) throw new Error("no questions")
    } catch (e) {
      item.error = String(e && e.message || e)
      item.raw = m[2]
    }
    res.push(item)
    lastEnd = m.index + m[0].length
  }
  if (OPEN.test(text.slice(lastEnd))) res.push({ key: "", pending: true })
  return res
}

// the reply text without its quiz blocks (an unclosed one is cut from its fence on)
function strip(text) {
  BLOCK.lastIndex = 0
  var s = text.replace(BLOCK, "")
  var m = OPEN.exec(s)
  if (m) s = s.slice(0, m.index)
  return s
}

function oneLine(s, n) {
  s = str(s).replace(/\s+/g, " ").replace(/→/g, "->").trim()
  return s.length > n ? s.slice(0, n - 1) + "…" : s
}

// the message sent back to Nova. ans: id -> index (multiple_choice) | [indexes] (multi_select) | string
function answers(item, ans) {
  var q = item.quiz, lines = ["Quiz answers (" + oneLine(q.title, 80) + ") [quiz " + item.key + "]:"]
  for (var i = 0; i < q.questions.length; i++) {
    var x = q.questions[i], a = ans[x.id], v
    if (x.type === "multiple_choice") {
      v = (typeof a === "number" && a >= 0) ? LETTERS.charAt(a) + ": " + x.choices[a] : ""
    } else if (x.type === "multi_select") {
      v = (a || []).slice().sort(function (p, r) { return p - r })
            .map(function (k) { return LETTERS.charAt(k) + ": " + x.choices[k] }).join(" | ")
    } else {
      v = str(a).trim().replace(/\n/g, "\n    ")              // long answers: continuation lines indented
    }
    lines.push(x.id + " · " + oneLine(x.prompt, 70) + " → " + (v || "(no answer)"))
  }
  return lines.join("\n")
}

function keyOf(msg) {
  var m = /^Quiz answers \(.*\) \[quiz ([0-9a-f]{6})\]:/.exec(msg)
  return m ? m[1] : ""
}

// a sent answers message back into id -> value, for the quiz it belongs to
function parseAnswers(item, msg) {
  var out = {}, cur = null, raw = {}
  var lines = msg.split("\n").slice(1)
  for (var i = 0; i < lines.length; i++) {
    var m = /^(\S+) · .*? → (.*)$/.exec(lines[i])
    if (m) { cur = m[1]; raw[cur] = m[2]; continue }
    if (cur && /^    /.test(lines[i])) raw[cur] += "\n" + lines[i].slice(4)
  }
  var qs = item.quiz.questions
  for (var j = 0; j < qs.length; j++) {
    var x = qs[j], r = raw[x.id]
    if (r === undefined || r === "(no answer)") continue
    if (x.type === "multiple_choice") {
      var l = /^([A-Z]): /.exec(r); if (l) out[x.id] = LETTERS.indexOf(l[1])
    } else if (x.type === "multi_select") {
      var re = /(?:^|\| )([A-Z]): /g, k, arr = []
      while ((k = re.exec(r)) !== null) arr.push(LETTERS.indexOf(k[1]))
      out[x.id] = arr
    } else out[x.id] = r
  }
  return out
}

// a spoken reply's cut (chars read aloud) never splits a quiz block: inside one, it moves to the block's start
function safeCut(text, cut) {
  if (cut < 0) return cut
  BLOCK.lastIndex = 0
  var m, lastEnd = 0
  while ((m = BLOCK.exec(text)) !== null) {
    if (cut > m.index && cut < m.index + m[0].length) { BLOCK.lastIndex = 0; return m.index }
    lastEnd = m.index + m[0].length
  }
  var o = OPEN.exec(text.slice(lastEnd))               // still streaming in
  if (o && cut > lastEnd + o.index) return lastEnd + o.index
  return cut
}

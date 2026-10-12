#!/bin/bash
# Show a sample quiz in the Nova chat panel without asking Nova: appends a display-only "report" event to the
# panel's live event feed ($XDG_RUNTIME_DIR/nova-voice/events.jsonl). Nothing is sent to Nova until you press
# Submit (then your answers go to her as a normal typed turn). The sample is gone after the panel reloads its history.
# Usage: nova_quiz_test.sh [file-with-a-reply-containing-a-```quiz-block]
set -euo pipefail
d="${XDG_RUNTIME_DIR:-/tmp}/nova-voice"
if [ $# -ge 1 ]; then reply=$(cat "$1"); else reply=$(cat <<'Q'
Test quiz from nova_quiz_test.sh.
```quiz
{"title": "Quiz panel test", "intro": "Recall $\\frac{d}{dx}x^n = n x^{n-1}$.",
 "questions": [
  {"id": "q1", "type": "multiple_choice", "prompt": "What is $\\frac{d}{dx}\\left(x^3\\right)$?", "choices": ["$3x^2$", "$x^2$", "$3x$", "$x^3/3$"]},
  {"id": "q2", "type": "multi_select", "prompt": "Which are continuous on $\\mathbb{R}$?", "choices": ["$\\sin x$", "$1/x$", "$e^x$", "$|x|$"]},
  {"id": "q3", "type": "numeric", "prompt": "Evaluate $$\\int_0^2 x\\,dx$$", "hint": "Area of a triangle."},
  {"id": "q4", "type": "short_answer", "prompt": "Name the limit $\\lim_{n\\to\\infty}(1+1/n)^n$."},
  {"id": "q5", "type": "long_answer", "prompt": "Why does gradient descent step along $-\\nabla f$?"}
 ]}
```
Q
); fi
mkdir -p "$d"
python3 -c 'import json,sys; print(json.dumps({"type": "report", "text": sys.argv[1]}))' "$reply" >> "$d/events.jsonl"
echo "sent a sample quiz to the chat panel (open it with SUPER+A)"

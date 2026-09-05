#!/bin/bash
# Full end-to-end pass against a freshly launched MacBud. Requires `make build` first.
# Usage: OUT=/tmp/macbud-e2e SHOTS=/path/to/test/media scripts/e2e-run.sh
set -u
cd "$(dirname "$0")/.."
export OUT=${OUT:-/tmp/macbud-e2e}; mkdir -p "$OUT"
source scripts/e2e.sh
SHOTS=${SHOTS:-$OUT/shots}
APP="$PWD/build/Build/Products/Debug/MacBud.app"

section() { echo; echo "=== $1 ==="; }
field() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d
for k in sys.argv[2].split("."): v=v[k]
print(v)' "$OUT/dump.json" "$1" 2>/dev/null; }
check() { if [ "$2" == "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1: expected [$3] got [$2]"; FAILED=1; fi; }
FAILED=0

pkill -x MacBud 2>/dev/null; sleep 0.4
defaults delete com.rangrik.macbud 2>/dev/null
rm -rf "$HOME/Library/Application Support/MacBud" "$HOME/Library/Logs/MacBud.log"
defaults write com.rangrik.macbud screenshotFolders -array "$SHOTS"
defaults write com.rangrik.macbud hasSeenWelcome -bool false
MACBUD_AUTOMATION=1 open -g -a "$APP"; sleep 2.5

section "welcome"
dump >/dev/null; check "welcome shown" "$(field welcome)" "True"; snap welcome
keys return 0.5; dump >/dev/null; check "welcome dismissed" "$(field welcome)" "False"
check "island shows content after welcome" "$(field phase)" "expanded"
keys escape 0.4

section "clipboard capture"
printf 'hello world from the shell' | pbcopy; sleep 0.7
printf 'https://developer.apple.com/documentation/swiftui/glasseffectcontainer' | pbcopy; sleep 0.7
printf 'func greet(name: String) -> String {\n    return "Hello, \\(name)!"\n}\n' | pbcopy; sleep 0.7
printf 'Second hello: meeting notes for Friday' | pbcopy; sleep 0.9
mb open section=clipboard; sleep 0.8; dump >/dev/null
check "4 items captured" "$(field results | python3 -c 'import ast,sys; print(len(ast.literal_eval(sys.stdin.read())))')" "4"
check "newest first" "$(field selected)" "Second hello: meeting notes for Friday"
snap clipboard_list
typetext hel; dump >/dev/null
check "query typed" "$(field query)" "hel"
check "prefix match ranks first" "$(field selected)" "hello world from the shell"
snap clipboard_search
keys down 0.3; keys return 0.9
check "copied second match" "$(pbpaste)" "Second hello: meeting notes for Friday"
dump >/dev/null; check "closed after copy" "$(field phase)" "collapsed"; check "toast shown" "$(field toast)" "Copied"
snap toast base; snap idle_tab base

section "pin + delete"
mb open section=clipboard; sleep 0.6
keys cmd+p 0.3; dump >/dev/null; check "pinned floats to top" "$(field selectedIndex)" "0"
keys down,cmd+backspace 0.4; dump >/dev/null
check "3 items after delete" "$(field results | python3 -c 'import ast,sys; print(len(ast.literal_eval(sys.stdin.read())))')" "3"
keys escape 0.5

section "snippets"
mb open section=snippets; sleep 0.7; dump >/dev/null
check "starter snippets" "$(field results | python3 -c 'import ast,sys; print(len(ast.literal_eval(sys.stdin.read())))')" "3"
snap snippets_list
keys cmd+n 0.4; dump >/dev/null; check "editor open" "$(field editing)" "True"
typetext "Standup"; keys tab 0.2; typetext "su"; keys tab 0.2; typetext "Yesterday: {clipboard} Today: {cursor}"
dump >/dev/null; check "draft name" "$(field draft.name)" "Standup"; check "draft keyword" "$(field draft.keyword)" "su"
snap snippet_editor
keys cmd+s 0.5; dump >/dev/null; check "editor closed" "$(field editing)" "False"
check "4 snippets" "$(field results | python3 -c 'import ast,sys; print(len(ast.literal_eval(sys.stdin.read())))')" "4"
typetext su; dump >/dev/null; check "keyword match first" "$(field selected)" "Standup"
keys return 0.9
check "snippet expanded with current clipboard" "$(pbpaste)" "Yesterday: Second hello: meeting notes for Friday Today: "

section "screenshots"
mb open section=screenshots; sleep 1.0; dump >/dev/null
check "5 media files" "$(field results | python3 -c 'import ast,sys; print(len(ast.literal_eval(sys.stdin.read())))')" "5"
snap screenshots
keys right,right 0.5; dump >/dev/null; check "moved right twice" "$(field selectedIndex)" "2"
snap screenshots_third
keys return 1.0
"$OUT/pbtypes" | head -8
n=$( "$OUT/pbtypes" | /usr/bin/grep -c "public.file-url" ); check "file URL on pasteboard" "$n" "1"
n=$( "$OUT/pbtypes" | /usr/bin/grep -c "public.png\|public.tiff\|public.jpeg" ); check "image data alongside file URL" "$([ "$n" -ge 1 ] && echo yes || echo no)" "yes"

section "dictation (file)"
if [ -f "$SHOTS/../speech.wav" ]; then
  mb dictate-file "path=$SHOTS/../speech.wav" paste=0; sleep 0.25; dump >/dev/null; check "dictation pill opens" "$(field phase)" "dictation"; snap dictation
  sleep 6; dump >/dev/null; echo "transcript: $(field dictation.transcript)"
  check "dictated text copied" "$(pbpaste | /usr/bin/grep -c 'dictation test')" "1"
  check "dictation closed" "$(field phase)" "collapsed"
fi

section "trace"
/usr/bin/sed -E 's/"path": "[^"]*"//' "$HOME/Library/Logs/MacBud.log" | /usr/bin/grep -E "resigned|DidBecomeActive|open |close" | tail -6
echo; [ $FAILED -eq 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"

#!/usr/bin/env bash
# Run: bash tests/engine.test.sh
# Exercises bin/omarchy-assistant's safety checks, apply, undo and automatic
# revert in a throwaway HOME with stand-in hyprctl/omarchy commands, so the
# real desktop and config are never touched. No AI is called.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" XDG_STATE_HOME="$tmp/state" FAKE="$tmp/fake"
mkdir -p "$HOME/.config/hypr" "$HOME/.config/omarchy/plugins/someone.else" "$HOME/.config/gh" "$FAKE" "$tmp/bin"
pass=0 fail=0
check() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "   expected: $3"; echo "   got:      $2"; fi; }
contains() { if [[ "$2" == *"$3"* ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (missing: $3)"; echo "   got: $2"; fi; }

# Stand-ins. hyprctl reports a config error when looknfeel.lua contains BROKEN.
cat >"$tmp/bin/hyprctl" <<'S'
#!/usr/bin/env bash
case "$1" in
  reload) echo reload >>"$FAKE/calls" ;;
  configerrors) grep -q BROKEN "$HOME/.config/hypr/looknfeel.lua" 2>/dev/null && echo "looknfeel.lua:1: unexpected symbol" ;;
esac
exit 0
S
cat >"$tmp/bin/omarchy" <<'S'
#!/usr/bin/env bash
case "$*" in
  "theme current") cat "$FAKE/theme" 2>/dev/null || echo "Tokyo Night" ;;
  "theme set "*) shift 2; echo "$*" >"$FAKE/theme" ;;
  "version") echo 4.0 ;;
esac
exit 0
S
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:/usr/bin:/bin"
for c in hyprctl omarchy; do [[ "$(command -v $c)" == "$tmp/bin/$c" ]] || { echo "refusing to run: $c is not the stand-in"; exit 1; }; done
A="$here/bin/omarchy-assistant"

printf -- '-- look\n-- hl.config({ general = { gaps_in = 0 } })\n' >"$HOME/.config/hypr/looknfeel.lua"
printf 'token: secret\n' >"$HOME/.config/gh/hosts.yml"
original=$(sha256sum "$HOME/.config/hypr/looknfeel.lua")
P="$tmp/p.json"

# 1. Safety: only the user's own config, exact single matches, listed commands.
cat >"$P" <<EOF
{"summary":"t","answer":"","changes":[
 {"file":"/etc/hosts","find":"a","replace":"b"},
 {"file":"~/.bashrc","find":"a","replace":"b"},
 {"file":"~/.config/../.bashrc","find":"a","replace":"b"},
 {"file":"~/.config/gh/hosts.yml","find":"token","replace":"x"},
 {"file":"~/.config/omarchy/plugins/someone.else/Bar.qml","create":"x"},
 {"file":"~/.config/hypr/looknfeel.lua","find":"--","replace":"x"},
 {"file":"~/.config/hypr/looknfeel.lua","find":"not there","replace":"x"}],
 "commands":["rm -rf ~","hyprctl dispatch exec foot","omarchy theme set Nord; rm -rf ~"]}
EOF
out=$("$A" preview "$P")
check "nothing applicable" "$(jq -r .canApply <<<"$out")" "false"
check "every bad edit and command refused" "$(jq '.problems | length' <<<"$out")" "10"
contains "system file" "$out" "/etc/hosts: outside your config"
contains "dotfile outside .config" "$out" "~/.bashrc: outside your config"
contains "credentials" "$out" "looks like a credentials file"
contains "plugin code" "$out" "plugin code is never edited"
contains "ambiguous edit" "$out" "found 2 times"
contains "missing text" "$out" "found 0 times"
contains "shell injection in a command" "$out" "command not allowed: omarchy theme set Nord; rm -rf ~"
check "refused apply changes nothing" "$("$A" apply "$P" | jq -r .ok)" "false"
check "file untouched" "$(sha256sum "$HOME/.config/hypr/looknfeel.lua")" "$original"

# 2. A good change applies, records history, and undo restores it byte for byte.
cat >"$P" <<'EOF'
{"summary":"Gaps","answer":"","changes":[{"file":"~/.config/hypr/looknfeel.lua","find":"-- hl.config({ general = { gaps_in = 0 } })","replace":"hl.config({ general = { gaps_in = 2 } })"}],"commands":["hyprctl reload"]}
EOF
check "preview allows it" "$("$A" preview "$P" | jq -r .canApply)" "true"
contains "preview shows the diff" "$("$A" preview "$P" | jq -r '.files[0].diff')" "+hl.config({ general = { gaps_in = 2 } })"
r=$("$A" apply "$P")
check "apply ok" "$(jq -r .ok <<<"$r")" "true"
contains "file changed" "$(cat "$HOME/.config/hypr/looknfeel.lua")" "gaps_in = 2"
check "history records it" "$("$A" history | jq -r '.[0].status')" "applied"
check "state dir is private" "$(stat -c %a "$XDG_STATE_HOME/omarchy-assistant")" "700"
check "undo ok" "$("$A" undo last | jq -r .ok)" "true"
check "undo restores the exact file" "$(sha256sum "$HOME/.config/hypr/looknfeel.lua")" "$original"
check "nothing left to undo" "$("$A" undo last | jq -r .ok)" "false"

# 3. A change that breaks the config is put back automatically.
cat >"$P" <<'EOF'
{"summary":"Broken","answer":"","changes":[{"file":"~/.config/hypr/looknfeel.lua","find":"-- look","replace":"BROKEN"}],"commands":[]}
EOF
r=$("$A" apply "$P")
check "broken change reverted" "$(jq -r '.ok,.reverted' <<<"$r" | tr '\n' ' ')" "false true "
contains "says why" "$r" "Hyprland reported errors"
check "file back as it was" "$(sha256sum "$HOME/.config/hypr/looknfeel.lua")" "$original"

# 4. Undo refuses to overwrite an edit made after the change (unless forced).
cat >"$P" <<'EOF'
{"summary":"Gaps","answer":"","changes":[{"file":"~/.config/hypr/looknfeel.lua","find":"-- look","replace":"-- look (assistant)"}],"commands":[]}
EOF
"$A" apply "$P" >/dev/null
echo "-- my own edit" >>"$HOME/.config/hypr/looknfeel.lua"
r=$("$A" undo last)
check "undo refuses over a later edit" "$(jq -r '.ok,.canForce' <<<"$r" | tr '\n' ' ')" "false true "
check "forced undo works" "$("$A" undo last --force | jq -r .ok)" "true"

# 5. New files can be created and undo removes them; themes are undone too.
cat >"$P" <<'EOF'
{"summary":"Theme","answer":"","changes":[{"file":"~/.config/hypr/extra.lua","create":"-- new\n"}],"commands":["omarchy theme set Nord"]}
EOF
echo "Tokyo Night" >"$FAKE/theme"
check "create + theme ok" "$("$A" apply "$P" | jq -r .ok)" "true"
check "theme changed" "$(cat "$FAKE/theme")" "Nord"
"$A" undo last >/dev/null
check "new file removed on undo" "$([[ -e $HOME/.config/hypr/extra.lua ]] && echo exists || echo gone)" "gone"
check "theme restored on undo" "$(cat "$FAKE/theme")" "Tokyo Night"

# 6. Probes refuse anything but their fixed checks.
check "unknown probe refused" "$("$A" probe 'rm' >/dev/null; echo $?)" "2"
check "injected probe argument refused" "$("$A" probe option '$(touch /tmp/x)' >/dev/null; echo $?)" "2"

echo "engine: $pass passed, $fail failed"
[[ $fail -eq 0 ]]

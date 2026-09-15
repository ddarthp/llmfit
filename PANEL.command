#!/bin/zsh
# macOS entry point for the panel. The Linux sibling is PANEL.sh, which also
# knows about Gaming Mode; here there is only one kind of session.
source "${0:A:h}/lib/bootstrap.zsh"

url="$("$LLMFIT_PWSH" -NoProfile -File "$LLMFIT_ROOT/ui.ps1" -WhereIsIt | head -1)"
if ! curl -s -m 2 -o /dev/null "$url/api/state"; then
  nohup "$LLMFIT_PWSH" -NoProfile -File "$LLMFIT_ROOT/ui.ps1" \
    > "$LLMFIT_ROOT/llmfit-panel.log" 2>&1 < /dev/null &
  for _ in {1..40}; do
    curl -s -m 2 -o /dev/null "$url/api/state" && break
    sleep 0.5
  done
fi
open "$url"
print ""
print "  Panel: $url"
print "  It keeps running after this window closes. Stop it with: pkill -f ui.ps1"
print ""

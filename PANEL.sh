#!/usr/bin/env bash
# Opens the llmfit panel, from the Steam library or from a terminal.
#
# The reason this is a script and not just a URL: in Gaming Mode there is no
# desktop to open a browser on, and Steam's own browser is reached by asking
# Steam rather than by launching anything. In Desktop Mode there is no Steam
# overlay to ask. So it looks at which session it is in and does the right one.
#
# To put it in your Steam library: Desktop Mode -> Steam -> Games -> Add a
# Non-Steam Game -> Browse -> pick this file. It then launches in Gaming Mode
# like anything else, and the controller drives the cursor over the panel.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/bootstrap.sh"

# The panel binds every interface, so the address to OPEN is the loopback, not
# whatever the server bound to. ui.ps1 -WhereIsIt answers with the loopback
# first; see lib/net.ps1 for why those are not the same string.
url="$("$LLMFIT_PWSH" -NoProfile -File "$LLMFIT_ROOT/ui.ps1" -WhereIsIt | head -1)"
[ -n "$url" ] || llmfit::die "Could not work out where the panel would listen."

# Already up from an earlier launch? Then this is just "show it to me again",
# and starting a second one would fail on the port anyway.
if ! curl -s -m 2 -o /dev/null "$url/api/state"; then
  nohup "$LLMFIT_PWSH" -NoProfile -File "$LLMFIT_ROOT/ui.ps1" \
    > "$LLMFIT_ROOT/llmfit-panel.log" 2>&1 < /dev/null &
  for _ in $(seq 1 40); do
    curl -s -m 2 -o /dev/null "$url/api/state" && break
    sleep 0.5
  done
fi

curl -s -m 2 -o /dev/null "$url/api/state" || llmfit::die \
  "The panel did not come up. Its log is at $LLMFIT_ROOT/llmfit-panel.log"

open_in_gaming_mode() {
  # Steam's built-in browser. steam://openurl/ is what the client itself uses
  # for every external link in Gaming Mode, and it is the only browser there.
  command -v steam >/dev/null 2>&1 || return 1
  steam "steam://openurl/$url" >/dev/null 2>&1 &
  return 0
}

open_on_the_desktop() {
  # --kiosk gives the panel the whole screen with no chrome around it, which is
  # what makes it feel like an appliance rather than a web page. Firefox is what
  # SteamOS ships; anything xdg-open resolves to is the fallback.
  if flatpak info org.mozilla.firefox >/dev/null 2>&1; then
    nohup flatpak run org.mozilla.firefox --kiosk "$url" >/dev/null 2>&1 &
    return 0
  fi
  if command -v firefox >/dev/null 2>&1; then
    nohup firefox --kiosk "$url" >/dev/null 2>&1 &
    return 0
  fi
  command -v xdg-open >/dev/null 2>&1 || return 1
  nohup xdg-open "$url" >/dev/null 2>&1 &
}

# pgrep for gamescope rather than an environment variable: a shortcut launched
# from the Steam library inherits Steam's environment either way, and the
# compositor actually running is the thing that decides which browser exists.
if pgrep -x gamescope >/dev/null 2>&1; then
  open_in_gaming_mode || open_on_the_desktop
else
  open_on_the_desktop || open_in_gaming_mode
fi

# printf, not print: print is a zsh builtin and this file is bash, the same
# split lib/bootstrap.sh and lib/bootstrap.zsh exist for.
printf '\n  Panel: %s\n' "$url"
"$LLMFIT_PWSH" -NoProfile -File "$LLMFIT_ROOT/ui.ps1" -WhereIsIt | tail -n +2 | while read -r other; do
  printf '  Also:  %s\n' "$other"
done
printf '\n  It keeps running after this window closes. Stop it with: pkill -f ui.ps1\n\n'

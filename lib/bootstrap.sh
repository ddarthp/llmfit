#!/usr/bin/env bash
# Provisions the PowerShell runtime the launcher runs on, then gets out of the
# way. Sourced by the .sh entry points and by bin/llmfit.
#
# The macOS sibling is lib/bootstrap.zsh and the reasoning is identical: the fit
# arithmetic lives in one PowerShell codebase rather than being reimplemented
# per operating system, so a machine without PowerShell downloads a portable
# copy exactly the way it already downloads llama.cpp - fetched, verified by
# SHA-256, extracted, never installed. Nothing is written outside this folder
# and no package manager is involved, which is what keeps this runnable on a
# locked-down box, a Steam Deck with a read-only root, or any distro at all.
#
# It is bash rather than zsh because bash is the one shell every Linux
# distribution ships; zsh is the one macOS ships. That is the whole difference,
# and it is why the two files are separate instead of one lowest-common
# denominator script that would be worse on both.
#
# On success it exports LLMFIT_ROOT and LLMFIT_PWSH. It exits on failure.

set -u -o pipefail

# BASH_SOURCE resolves to this file even when sourced, which $0 does not.
LLMFIT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export LLMFIT_ROOT

llmfit::die() {
  printf '\n' >&2
  local line
  for line in "$@"; do printf '  %s\n' "$line" >&2; done
  printf '\n' >&2
  exit 1
}

# ------------------------------------------------------------ platform guard

if [ "$(uname -s)" != "Linux" ]; then
  llmfit::die "This entry point is for Linux." \
    "On macOS use START.command and on Windows START.cmd; all three run the same llmfit.ps1."
fi

case "$(uname -m)" in
  x86_64|amd64) llmfit_arch="x64" ;;
  aarch64|arm64) llmfit_arch="arm64" ;;
  *) llmfit::die "Unsupported architecture: $(uname -m)." \
       "config/bootstrap.json carries PowerShell for linux x64 and arm64 only." ;;
esac

for tool in curl tar jq; do
  command -v "$tool" >/dev/null 2>&1 || llmfit::die "Missing required tool: $tool" \
    "Install it with your package manager, for example:" \
    "  sudo apt install $tool      (Debian, Ubuntu)" \
    "  sudo dnf install $tool      (Fedora, RHEL)" \
    "  sudo pacman -S $tool        (Arch, SteamOS)"
done

# coreutils has sha256sum; shasum is the perl script macOS ships and some
# minimal images carry instead. Either answers the only question asked here.
if command -v sha256sum >/dev/null 2>&1; then
  llmfit::sha256() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  llmfit::sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  llmfit::die "Missing required tool: sha256sum" \
    "It comes with coreutils, which is part of every base install."
fi

llmfit_config="$LLMFIT_ROOT/config/bootstrap.json"
[ -f "$llmfit_config" ] || llmfit::die "Missing configuration file: $llmfit_config"

# ------------------------------------------------------------- pwsh discovery

# Reading it out of config keeps this script free of values that belong in
# config/, the same rule the PowerShell side follows.
llmfit::config() { jq -r --arg a "$llmfit_arch" --arg k "$1" '.linux[$a][$k]' "$llmfit_config"; }

want_name="$(llmfit::config name)"
want_folder="$(llmfit::config folder)"
want_entry="$(llmfit::config entrypoint)"
want_url="$(llmfit::config url)"
want_sha="$(llmfit::config sha256)"
[ -n "$want_url" ] && [ "$want_url" != "null" ] || llmfit::die \
  "config/bootstrap.json declares no PowerShell for linux/$llmfit_arch."

vendored="$LLMFIT_ROOT/tools/$want_folder/$want_entry"

# A pwsh already on PATH is used as is. Someone whose distro packages PowerShell
# should not also be made to download 70 MB of it.
llmfit::usable() {
  [ -x "$1" ] || return 1
  local major
  major="$("$1" -NoProfile -NoLogo -Command '$PSVersionTable.PSVersion.Major' 2>/dev/null)" || return 1
  case "$major" in ''|*[!0-9]*) return 1 ;; esac
  [ "$major" -ge 7 ]
}

LLMFIT_PWSH=""
if command -v pwsh >/dev/null 2>&1 && llmfit::usable "$(command -v pwsh)"; then
  LLMFIT_PWSH="$(command -v pwsh)"
elif llmfit::usable "$vendored"; then
  LLMFIT_PWSH="$vendored"
fi

# ------------------------------------------------------------- provisioning

if [ -z "$LLMFIT_PWSH" ]; then
  archive="$LLMFIT_ROOT/downloads/$(basename "$want_url")"
  destination="$LLMFIT_ROOT/tools/$want_folder"
  mkdir -p "$(dirname "$archive")" "$destination" || llmfit::die "Cannot create $destination"

  printf '\n'
  printf '  %s is not on this machine. Fetching it once.\n' "$want_name"
  printf '  It is extracted into tools/, not installed: nothing outside this folder changes.\n'
  printf '\n'

  # The hash is the contract, not whether the file exists and not whether curl
  # exited cleanly. Attempts 1 and 2 resume where the transfer stopped; attempt
  # 3 starts over in case the partial data itself is bad. Same rule as
  # Ensure-Artifact in llmfit.ps1, because it is the same problem.
  actual=""
  for attempt in 1 2 3; do
    if [ -f "$archive" ]; then
      actual="$(llmfit::sha256 "$archive")"
      [ "$actual" = "$want_sha" ] && break
      if [ "$attempt" -lt 3 ]; then
        printf '  Incomplete download. Resuming (attempt %s of 3)...\n' "$attempt"
      else
        printf '  Still does not match. Downloading from scratch...\n'
        rm -f "$archive"
      fi
    fi
    curl -L --fail --show-error --progress-bar -C - \
      --retry 5 --retry-delay 3 --retry-all-errors -o "$archive" "$want_url" \
      || printf '  Transfer interrupted (curl exit %s).\n' "$?"
  done

  actual="$(llmfit::sha256 "$archive" 2>/dev/null)" || actual=""
  [ "$actual" = "$want_sha" ] || llmfit::die \
    "Could not download $want_name after 3 attempts." \
    "Expected: $want_sha" \
    "Got:      ${actual:-nothing}" \
    "URL:      $want_url"

  tar -xzf "$archive" -C "$destination" || llmfit::die "Could not extract $archive"
  chmod +x "$vendored" 2>/dev/null

  # The portable build is framework-dependent on nothing but libicu and
  # libssl, which every desktop distro has - but not every container image
  # does, and the failure there is a linker message nobody reads as "install
  # icu". Say it here instead of letting the launcher die further down.
  llmfit::usable "$vendored" || llmfit::die \
    "$want_name was extracted but will not run: $vendored" \
    "Run it by hand to see why. The usual cause on a minimal image is a missing" \
    "libicu; on Debian and Ubuntu 'sudo apt install libicu-dev' resolves it."
  LLMFIT_PWSH="$vendored"
  printf '  OK: %s ready.\n' "$want_name"
fi

export LLMFIT_PWSH

[ -n "${LLMFIT_DEBUG:-}" ] && printf '  [debug] root=%s pwsh=%s\n' "$LLMFIT_ROOT" "$LLMFIT_PWSH" >&2

# ------------------------------------------------------------------- handoff

# A file manager that runs a .sh on double-click opens a terminal that closes on
# exit, taking the error message with it. Keep it up when something failed.
llmfit::run() {
  local script="$LLMFIT_ROOT/$1"; shift
  [ -f "$script" ] || llmfit::die "Missing script: $script"
  "$LLMFIT_PWSH" -NoProfile -ExecutionPolicy Bypass -File "$script" "$@"
  local exit_code=$?
  if [ "$exit_code" -ne 0 ] && [ -t 0 ]; then
    printf '\n'
    printf '  Exited with code %s. Press Return to close.\n' "$exit_code"
    read -r _
  fi
  return $exit_code
}

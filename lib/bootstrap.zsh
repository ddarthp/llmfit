#!/bin/zsh
# Provisions the PowerShell runtime the launcher runs on, then gets out of the
# way. Sourced by the .command entry points and by bin/llmfit.
#
# Why this file exists at all: there is no runtime both Windows and macOS ship.
# Windows has PowerShell and no shell; macOS has zsh and no PowerShell. Rather
# than maintain the fit arithmetic twice and let two implementations drift, the
# launcher stays a single PowerShell codebase and macOS downloads a portable
# copy of PowerShell exactly the way it already downloads llama.cpp: fetched,
# verified by SHA-256, extracted, never installed. Nothing is written outside
# this folder and no package manager is involved.
#
# On success it exports LLMFIT_ROOT and LLMFIT_PWSH. It exits on failure.

emulate -L zsh
setopt no_unset pipe_fail

# %x resolves to this file even when sourced, which $0 does not do reliably.
LLMFIT_ROOT="${${(%):-%x}:A:h:h}"
export LLMFIT_ROOT

llmfit::die() {
  print -u2 ""
  print -u2 "  $1"
  shift
  for line in "$@"; do print -u2 "  $line"; done
  print -u2 ""
  exit 1
}

# ------------------------------------------------------------ platform guard

if [[ "$(uname -s)" != "Darwin" ]]; then
  llmfit::die "This entry point is for macOS." \
    "On Windows use START.cmd, which runs the same llmfit.ps1."
fi

typeset -r llmfit_arch="$(uname -m)"
if [[ "$llmfit_arch" != "arm64" ]]; then
  llmfit::die "llmfit needs Apple Silicon; this machine reports '$llmfit_arch'." \
    "Only the macos-arm64 build of llama.cpp is in the catalog. An Intel Mac" \
    "would need the macos-x64 archive added to config/backends.json."
fi

for tool in curl tar shasum jq; do
  (( $+commands[$tool] )) || llmfit::die "Missing required tool: $tool" \
    "It normally ships with macOS. Check that /usr/bin is on your PATH."
done

typeset -r llmfit_config="$LLMFIT_ROOT/config/bootstrap.json"
[[ -f "$llmfit_config" ]] || llmfit::die "Missing configuration file: $llmfit_config"

# ------------------------------------------------------------- pwsh discovery

# Reading it out of config keeps this script free of values that belong in
# config/, the same rule the PowerShell side follows.
llmfit::config() { jq -r --arg k "$1" '.macos.arm64[$k]' "$llmfit_config" }

typeset -r want_name="$(llmfit::config name)"
typeset -r want_folder="$(llmfit::config folder)"
typeset -r want_entry="$(llmfit::config entrypoint)"
typeset -r want_url="$(llmfit::config url)"
typeset -r want_sha="$(llmfit::config sha256)"

typeset -r vendored="$LLMFIT_ROOT/tools/$want_folder/$want_entry"

# A pwsh already on PATH is used as is. Someone who installed PowerShell with
# brew should not also be made to download 68 MB of it.
llmfit::usable() {
  [[ -x "$1" ]] || return 1
  local major
  major="$("$1" -NoProfile -NoLogo -Command '$PSVersionTable.PSVersion.Major' 2>/dev/null)" || return 1
  [[ "$major" == <-> ]] && (( major >= 7 ))
}

LLMFIT_PWSH=""
if (( $+commands[pwsh] )) && llmfit::usable "$commands[pwsh]"; then
  LLMFIT_PWSH="$commands[pwsh]"
elif llmfit::usable "$vendored"; then
  LLMFIT_PWSH="$vendored"
fi

# ------------------------------------------------------------- provisioning

if [[ -z "$LLMFIT_PWSH" ]]; then
  typeset -r archive="$LLMFIT_ROOT/downloads/${want_url:t:r:r}.tar.gz"
  typeset -r destination="$LLMFIT_ROOT/tools/$want_folder"
  mkdir -p "${archive:h}" "$destination" || llmfit::die "Cannot create $destination"

  print ""
  print "  $want_name is not on this machine. Fetching it once."
  print "  It is extracted into tools/, not installed: nothing outside this folder changes."
  print ""

  # The hash is the contract, not whether the file exists and not whether curl
  # exited cleanly. Attempts 1 and 2 resume where the transfer stopped; attempt
  # 3 starts over in case the partial data itself is bad. Same rule as
  # Ensure-Artifact in llmfit.ps1, because it is the same problem.
  typeset actual=""
  for attempt in 1 2 3; do
    if [[ -f "$archive" ]]; then
      actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
      [[ "$actual" == "$want_sha" ]] && break
      if (( attempt < 3 )); then
        print "  Incomplete download. Resuming (attempt $attempt of 3)..."
      else
        print "  Still does not match. Downloading from scratch..."
        rm -f "$archive"
      fi
    fi
    curl -L --fail --show-error --progress-bar -C - \
      --retry 5 --retry-delay 3 --retry-all-errors -o "$archive" "$want_url" \
      || print "  Transfer interrupted (curl exit $?)."
  done

  actual="$(shasum -a 256 "$archive" 2>/dev/null | awk '{print $1}')" || actual=""
  [[ "$actual" == "$want_sha" ]] || llmfit::die \
    "Could not download $want_name after 3 attempts." \
    "Expected: $want_sha" \
    "Got:      ${actual:-nothing}" \
    "URL:      $want_url"

  tar -xzf "$archive" -C "$destination" || llmfit::die "Could not extract $archive"
  chmod +x "$vendored" 2>/dev/null

  llmfit::usable "$vendored" || llmfit::die \
    "$want_name was extracted but will not run: $vendored"
  LLMFIT_PWSH="$vendored"
  print "  OK: $want_name ready."
fi

export LLMFIT_PWSH

[[ -n "${LLMFIT_DEBUG:-}" ]] && print -u2 "  [debug] root=$LLMFIT_ROOT pwsh=$LLMFIT_PWSH"

# ------------------------------------------------------------------- handoff

# Double-clicking a .command in Finder opens a Terminal window that closes on
# exit, taking the error message with it. Keep it up when something failed.
llmfit::run() {
  local script="$LLMFIT_ROOT/$1"; shift
  [[ -f "$script" ]] || llmfit::die "Missing script: $script"
  "$LLMFIT_PWSH" -NoProfile -ExecutionPolicy Bypass -File "$script" "$@"
  # Not named 'status': zsh reserves that as a read-only alias for $?.
  local exit_code=$?
  if (( exit_code != 0 )) && [[ -t 0 ]]; then
    print ""
    print "  Exited with code $exit_code. Press Return to close."
    read -r _
  fi
  return $exit_code
}

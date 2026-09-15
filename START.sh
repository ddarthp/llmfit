#!/usr/bin/env bash
# Linux entry point. Run it from a terminal, or double-click it in a file
# manager set to execute scripts.
# The macOS equivalent is START.command and the Windows one START.cmd; all three
# run the same llmfit.ps1.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/bootstrap.sh"
llmfit::run llmfit.ps1 "$@"

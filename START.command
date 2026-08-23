#!/bin/zsh
# macOS entry point. Double-click it in Finder or run it from a terminal.
# The Windows equivalent is START.cmd; both run the same llmfit.ps1.
source "${0:A:h}/lib/bootstrap.zsh"
llmfit::run llmfit.ps1 "$@"

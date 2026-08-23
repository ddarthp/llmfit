#!/bin/zsh
# Checks the SHA-256 of every model and binary that is installed.
source "${0:A:h}/lib/bootstrap.zsh"
llmfit::run verify.ps1 "$@"

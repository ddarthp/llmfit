#!/bin/zsh
# Puts bin/ on your PATH so 'llmfit' works from any folder.
source "${0:A:h}/lib/bootstrap.zsh"
llmfit::run install-path.ps1 "$@"

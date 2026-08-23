#!/bin/zsh
# Deletes already-extracted archives to reclaim disk.
source "${0:A:h}/lib/bootstrap.zsh"
llmfit::run clean.ps1 "$@"

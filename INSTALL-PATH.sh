#!/usr/bin/env bash
# Puts bin/ on your PATH so 'llmfit' works from any folder.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/bootstrap.sh"
llmfit::run install-path.ps1 "$@"

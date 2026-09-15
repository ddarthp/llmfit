#!/usr/bin/env bash
# Checks the SHA-256 of every model and binary that is installed.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/bootstrap.sh"
llmfit::run verify.ps1 "$@"

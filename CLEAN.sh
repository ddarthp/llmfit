#!/usr/bin/env bash
# Deletes already-extracted archives to reclaim disk.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/bootstrap.sh"
llmfit::run clean.ps1 "$@"

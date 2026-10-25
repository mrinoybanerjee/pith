#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift format lint --recursive --strict Sources Tests Package.swift
# Tests/Scripts does not exist until a task adds script tests.
shopt -s nullglob
for script in scripts/*.sh Tests/Scripts/*.sh; do
    bash -n "$script"
done
git diff --check

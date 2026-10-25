#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

./scripts/lint.sh && swift build -c release -Xswiftc -warnings-as-errors && ./scripts/test.sh

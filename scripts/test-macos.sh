#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p build/module-cache
swiftc -O -module-cache-path build/module-cache Sources/Snow.swift Sources/Desktop.swift Tests/main.swift -o build/test-snow
build/test-snow

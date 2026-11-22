#!/usr/bin/env bash
# Fetch + build ungive/mediaremote-adapter into vendor/ (macOS, needs cmake).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p vendor
[ -d vendor/mediaremote-adapter ] || git clone --depth 1 https://github.com/ungive/mediaremote-adapter.git vendor/mediaremote-adapter
cd vendor/mediaremote-adapter
cmake -S . -B build -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
ls build

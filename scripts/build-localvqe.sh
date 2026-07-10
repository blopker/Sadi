#!/bin/bash
# Rebuild Vendor/localvqe/liblocalvqe.dylib from source.
# Usage: scripts/build-localvqe.sh [ref]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF="${1:-main}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone --depth 1 --branch "$REF" https://github.com/localai-org/LocalVQE "$WORK/LocalVQE"
cd "$WORK/LocalVQE"
git submodule update --init --depth 1 ggml/vendor/ggml
cd ggml
cmake -B build -DCMAKE_BUILD_TYPE=Release -DLOCALVQE_BUILD_SHARED=ON
cmake --build build --target localvqe_shared -j"$(sysctl -n hw.ncpu)"

install -m 0644 build/liblocalvqe.0.1.0.dylib "$REPO_ROOT/Vendor/localvqe/liblocalvqe.dylib"
echo "installed: $REPO_ROOT/Vendor/localvqe/liblocalvqe.dylib"
shasum -a 256 "$REPO_ROOT/Vendor/localvqe/liblocalvqe.dylib"

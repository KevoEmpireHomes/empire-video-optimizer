#!/usr/bin/env bash
# Re-download the vendored ffmpeg.wasm assets at pinned versions and verify their
# checksums against vendor/CHECKSUMS.txt. Run from anywhere; paths are repo-relative.
#
# Why these files are vendored rather than pulled from a CDN at runtime:
#   - The UMD build spawns its worker relative to its own script URL. A cross-origin
#     (CDN) script makes that worker cross-origin, which browsers refuse to construct.
#   - Removes a runtime dependency on jsdelivr and pins exactly what ships (SOC 2 provenance).
#
# To bump a version: change the version vars below, run this script, then regenerate
# checksums with:  shasum -a 256 vendor/ffmpeg/*.js vendor/core/* > vendor/CHECKSUMS.txt
set -euo pipefail

FFMPEG_VERSION="0.12.10"   # @ffmpeg/ffmpeg (JS wrapper + worker chunk)
CORE_VERSION="0.12.6"      # @ffmpeg/core   (single-threaded wasm core)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FFMPEG_BASE="https://cdn.jsdelivr.net/npm/@ffmpeg/ffmpeg@${FFMPEG_VERSION}/dist/umd"
CORE_BASE="https://cdn.jsdelivr.net/npm/@ffmpeg/core@${CORE_VERSION}/dist/umd"

mkdir -p vendor/ffmpeg vendor/core

echo "Downloading @ffmpeg/ffmpeg@${FFMPEG_VERSION} and @ffmpeg/core@${CORE_VERSION}..."
curl -sSfL "${FFMPEG_BASE}/ffmpeg.js"        -o vendor/ffmpeg/ffmpeg.js
curl -sSfL "${FFMPEG_BASE}/814.ffmpeg.js"    -o vendor/ffmpeg/814.ffmpeg.js
curl -sSfL "${CORE_BASE}/ffmpeg-core.js"     -o vendor/core/ffmpeg-core.js
curl -sSfL "${CORE_BASE}/ffmpeg-core.wasm"   -o vendor/core/ffmpeg-core.wasm

echo "Verifying checksums against vendor/CHECKSUMS.txt..."
shasum -a 256 -c vendor/CHECKSUMS.txt

echo "Done. Vendored assets match pinned checksums."

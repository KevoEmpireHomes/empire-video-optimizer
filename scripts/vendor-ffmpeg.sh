#!/usr/bin/env bash
# Re-download the ffmpeg.wasm assets at pinned versions, verify their checksums against
# vendor/CHECKSUMS.txt, then gzip the wasm core for deployment. Run from anywhere.
#
# Why these files are vendored rather than pulled from a CDN at runtime:
#   - The UMD build spawns its worker relative to its own script URL. A cross-origin
#     (CDN) script makes that worker cross-origin, which browsers refuse to construct.
#   - Removes a runtime dependency on jsdelivr and pins exactly what ships (SOC 2 provenance).
#
# Why the wasm is gzipped: Cloudflare Pages caps individual files at 25 MiB and the raw
# core wasm is ~30.6 MiB. It ships as ffmpeg-core.wasm.gz (~9.7 MiB) and index.html
# inflates it in the browser via DecompressionStream into a same-origin blob URL.
#
# To bump a version: change the version vars, refresh the raw hashes in
# vendor/CHECKSUMS.txt, then run this script.
set -euo pipefail

FFMPEG_VERSION="0.12.10"   # @ffmpeg/ffmpeg (JS wrapper + worker chunk)
CORE_VERSION="0.12.6"      # @ffmpeg/core   (single-threaded wasm core)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FFMPEG_BASE="https://cdn.jsdelivr.net/npm/@ffmpeg/ffmpeg@${FFMPEG_VERSION}/dist/umd"
CORE_BASE="https://cdn.jsdelivr.net/npm/@ffmpeg/core@${CORE_VERSION}/dist/umd"

mkdir -p vendor/ffmpeg vendor/core

echo "Downloading @ffmpeg/ffmpeg@${FFMPEG_VERSION} and @ffmpeg/core@${CORE_VERSION}..."
curl -sSfL "${FFMPEG_BASE}/ffmpeg.js"      -o vendor/ffmpeg/ffmpeg.js
curl -sSfL "${FFMPEG_BASE}/814.ffmpeg.js"  -o vendor/ffmpeg/814.ffmpeg.js
curl -sSfL "${CORE_BASE}/ffmpeg-core.js"   -o vendor/core/ffmpeg-core.js
curl -sSfL "${CORE_BASE}/ffmpeg-core.wasm" -o vendor/core/ffmpeg-core.wasm

echo "Verifying checksums against vendor/CHECKSUMS.txt..."
shasum -a 256 -c vendor/CHECKSUMS.txt

echo "Compressing core wasm for deployment (Cloudflare Pages 25 MiB file limit)..."
gzip -9 -n -c vendor/core/ffmpeg-core.wasm > vendor/core/ffmpeg-core.wasm.gz
rm -f vendor/core/ffmpeg-core.wasm   # raw wasm is not deployed; only the .gz ships

echo "Done. vendor/core/ffmpeg-core.wasm.gz is $(du -h vendor/core/ffmpeg-core.wasm.gz | cut -f1)."

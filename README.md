# Empire Homes — Video Optimizer

A single-page tool that resizes and compresses listing videos entirely in the
browser. Video data never leaves the user's machine; all encoding runs client-side
via [ffmpeg.wasm](https://github.com/ffmpegwasm/ffmpeg.wasm).

## Structure

```
index.html            The whole app (UI + logic, no build step)
_headers              COOP/COEP headers (required, see below)
vendor/               Vendored ffmpeg.wasm assets, served same-origin
  ffmpeg/             @ffmpeg/ffmpeg 0.12.10 (JS wrapper + worker chunk)
  core/               @ffmpeg/core 0.12.6 (JS core + gzipped wasm)
  CHECKSUMS.txt       sha256 of the raw upstream artifacts
scripts/
  vendor-ffmpeg.sh    Re-download + checksum-verify the vendored assets
```

## Why ffmpeg is vendored, not loaded from a CDN

The UMD build of ffmpeg.wasm spawns its worker (`814.ffmpeg.js`) from a URL relative
to its own `<script>`. When that script is loaded from a CDN, the worker URL is
cross-origin, and browsers refuse to construct a `Worker` from a cross-origin URL
(`Failed to construct 'Worker'`). Serving the files same-origin from `vendor/` makes
the worker same-origin and fixes this. It also removes a runtime dependency on a
third-party CDN and pins exactly what ships.

## Why the wasm ships gzipped

Cloudflare Pages caps individual files at 25 MiB, and the raw core wasm is ~30.6 MiB.
It ships as `vendor/core/ffmpeg-core.wasm.gz` (~9.7 MiB) and `index.html` inflates it in
the browser with `DecompressionStream` into a same-origin blob URL before loading. The
file must be served as an opaque binary (Cloudflare Pages does this for `.gz`); it must
**not** be served with `Content-Encoding: gzip`, or the browser would double-decompress.

## Cross-origin isolation

`_headers` sets `Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp`. Keep this file at the root of whatever
directory is deployed. These headers are what the hosting platform (Cloudflare Pages
or Workers static assets) applies to responses.

## Local development

Because of the COOP/COEP headers and the same-origin worker, open the app through a
static server, not a `file://` URL:

```
npx serve .        # or: python3 -m http.server 8080
```

## Updating the vendored ffmpeg

```
./scripts/vendor-ffmpeg.sh
```

To bump a version, edit the version variables at the top of that script, refresh the raw
hashes in `vendor/CHECKSUMS.txt`, then run the script. It re-downloads, verifies the raw
artifacts, and regenerates the gzipped wasm.

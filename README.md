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
  core/               @ffmpeg/core 0.12.6 (single-threaded wasm core)
  CHECKSUMS.txt       sha256 of every vendored file
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

To bump a version, edit the version variables at the top of that script, run it, then
regenerate the checksums:

```
shasum -a 256 vendor/ffmpeg/*.js vendor/core/* > vendor/CHECKSUMS.txt
```

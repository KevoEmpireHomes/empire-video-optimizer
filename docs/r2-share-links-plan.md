# Planning Doc: R2 Share Links for the Video Optimizer

**Status:** Ready for implementation
**Owner (implementer):** Kevin Appiah
**Prepared by:** ZeroArc (AI Labs)
**Last updated:** 2026-07-24

This is an implementation plan, not finished code. Work through it top to bottom.
Each numbered task in the checklist at the end is meant to be a small, reviewable
change.

---

## 1. Goal

Add an optional "Get share link" step to the existing browser-based video
optimizer. After a user compresses a video locally, they can upload the
**compressed result** to Cloudflare R2 and receive a private, expiring link they
can send to a client. Uploaded files auto-delete after 24 hours.

> **Dev environment constraint (read first).** The Empire team cannot install
> wrangler on their managed devices. They write code and deploy through the
> **GitHub -> Cloudflare Pages Git integration** only. This plan is built around
> that: no local wrangler, no local build, no local secrets. All infra setup is
> done by ZeroArc in the Cloudflare dashboard; the dev iterates on **Pages
> preview deployments**. See §11 for the full loop.
>
> Production is live at **https://video-optimizer.empireailab.com** (custom
> domain). Only a **Production** environment exists today; a **Preview**
> environment needs the R2 binding attached so the dev can test (§6, §11).

## 2. Approach in one paragraph

Compression stays 100% in the browser. To share, the browser POSTs the finished
compressed file to a **Pages Function**, which writes it to R2 using an **R2
binding** (`env.BUCKET`), no credentials involved. The Function returns a private,
unguessable share link served by a second Function route that streams the object
back. A 24-hour R2 lifecycle rule deletes the object, which also expires the link
(it just starts returning 404). There are **no API tokens, no S3 credentials, no
presigned URLs, and no secrets** in this design. The one constraint is a **100 MB
per-file ceiling** on upload (Cloudflare's max request body size), which is fine
for compressed listing clips and enforced with a client-side guardrail.

## 3. What stays the same (do not touch)

- Compression still happens 100% in the browser with ffmpeg.wasm. The raw
  source video is never uploaded.
- The current local "Download compressed video" button stays exactly as-is.
- The Cloudflare **Pages** deployment stays. We are not moving to Workers or
  Containers.
- Vendored ffmpeg under `vendor/`, the `_headers` COOP/COEP file, and
  `scripts/vendor-ffmpeg.sh` all stay.

## 4. What changes

- Add **Pages Functions** (`/functions/...`) to the same repo. They run
  server-side on the same deploy and access R2 through the binding.
- Add an opt-in "Get share link" button that appears next to the existing
  download button after compression completes.
- Only the **compressed output** is uploaded, and only when the user clicks the
  button. Nothing uploads automatically.
- The share link is a private, same-origin URL that stops working after 24 hours
  (the object is deleted by the lifecycle rule). The R2 bucket stays private.
- Update the user-facing copy and README so the privacy claim is accurate: the
  source never leaves the machine, but a shared compressed file is stored in R2
  for up to 24 hours.

## 5. Why a server-side piece is still needed

The browser cannot talk to a private R2 bucket directly without credentials, and
we are deliberately not putting credentials anywhere. Instead, a small Pages
Function sits in front of R2 and uses the **R2 binding**, which grants object
read/write to server-side code with no keys. The Function mediates both hops:

- **Upload:** browser POSTs the file to the Function, the Function does
  `env.BUCKET.put()`.
- **Download:** the recipient hits a Function route, the Function does
  `env.BUCKET.get()` and streams it back.

Bindings only exist server-side, so nothing sensitive reaches the browser and
there is no long-lived credential to store, rotate, or leak. This is the reason
the binding-only design is both simpler and a better SOC 2 posture than the
presigned-URL approach we first considered.

## 6. Architecture and data flow

```
Browser                         Pages Function (binding: env.BUCKET)   R2 (private bucket)
  | 1. compress locally (ffmpeg.wasm) -> outputBlob                       |
  |                                          |                             |
  | 2. click "Get share link"                |                             |
  |    guardrail: blob <= ~95 MB             |                             |
  |-- POST /api/share  (body = blob) ------->|  validate size + type       |
  |                                          |  key = shared/{uuid}/{name} |
  |                                          |  env.BUCKET.put(key, body) ->|  store object
  |<-- { shareUrl } --------------------------|                             |
  |                                          |                             |
  | 3. show shareUrl + Copy button           |                             |
  |                                          |                             |
  | recipient GET /s/{uuid}/{name} --------->|  env.BUCKET.get(key) <-------|  read object
  |<-- streamed file (attachment) -----------|  404 after cleanup          |
  |                                          |                             |  24h lifecycle deletes
```

Notes:
- No credentials anywhere; the binding is the only access path and it is
  server-side only.
- Upload goes through the Function, capped at **100 MB** request body (platform
  limit). The client-side guardrail rejects anything over ~95 MB before posting.
- Download streams through the Function; response size is unlimited/streaming, so
  no ceiling on the download side.
- Link expiry is implicit: the URL 404s once the 24h lifecycle deletes the
  object. No expiry logic to write.
- The `{uuid}` in the key is the unguessable token that keeps links private.

## 7. Cloudflare resources (mostly done)

Provisioned by ZeroArc in the dashboard. Recorded here for the SOC 2 paper trail.

1. **R2 bucket** — `empire-video-optimizer`, private. **DONE.** Single bucket for
   both production and preview traffic (internal demo, isolation not needed).

2. **R2 binding** — the bucket is bound to the Pages project as `env.BUCKET`,
   attached to **both** the Production and Preview environments. **DONE.** The
   plan's code uses `env.BUCKET`.

3. **CORS policy** — **DONE, but no longer required.** With the binding-only
   design there is no direct browser->R2 request, so R2 never needs to send CORS
   headers. The policy you set is harmless and can be left in place or removed; it
   simply will not be exercised.

4. **Lifecycle rule** — delete objects 1 day after creation. **DONE.** The current
   rule applies to the whole bucket (no prefix), which is correct here because the
   bucket only ever holds share uploads. This is the entire cleanup mechanism; do
   not build a separate delete job.

5. **Secrets** — **none.** This design has no API token, no S3 credentials, and no
   environment secrets. Nothing to set in the dashboard beyond the binding.

## 8. Server-side: two Function routes

No `package.json`, no dependencies, no build step. Pages auto-builds anything
under `functions/`. Both files use only the R2 binding and standard Web APIs.

### 8a. Upload — `functions/api/share.js`

`onRequestPost` handler. Responsibilities:
1. Reject if `Content-Length` is missing or over the cap (~95 MB). The platform
   also hard-rejects bodies over 100 MB with a 413; treat both.
2. Validate `Content-Type` is `video/mp4`.
3. Read the intended filename from a header or query param, then **sanitize** it
   (strip path separators, keep a safe basename). Never trust it for the key.
4. Build the key: `shared/${crypto.randomUUID()}/${safeName}`.
5. `await env.BUCKET.put(key, request.body, { httpMetadata: { contentType:
   "video/mp4", contentDisposition: 'attachment; filename="' + safeName + '"' }})`.
6. Return `{ shareUrl }` where `shareUrl` is `${new URL(request.url).origin}/s/${uuid}/${encodeURIComponent(safeName)}`.

Sketch (pseudocode, verify binding name and API shapes):
```js
export async function onRequestPost({ request, env }) {
  const len = Number(request.headers.get("content-length") || 0);
  if (!len || len > 95 * 1024 * 1024)
    return new Response("File too large or missing", { status: 413 });
  if (request.headers.get("content-type") !== "video/mp4")
    return new Response("Unsupported type", { status: 415 });

  const raw = new URL(request.url).searchParams.get("name") || "video.mp4";
  const safeName = raw.replace(/[^\w.\-]+/g, "_").slice(-80) || "video.mp4";
  const uuid = crypto.randomUUID();
  const key = `shared/${uuid}/${safeName}`;

  await env.BUCKET.put(key, request.body, {
    httpMetadata: {
      contentType: "video/mp4",
      contentDisposition: `attachment; filename="${safeName}"`,
    },
  });

  const origin = new URL(request.url).origin;
  return Response.json({
    shareUrl: `${origin}/s/${uuid}/${encodeURIComponent(safeName)}`,
  });
}
```

### 8b. Download — `functions/s/[[path]].js`

Catch-all route so `/s/{uuid}/{name}` maps to the object. Responsibilities:
1. Rebuild the key from the path: `shared/${uuid}/${name}` (validate the uuid
   looks like a uuid; sanitize name the same way).
2. `const obj = await env.BUCKET.get(key)`.
3. If `null`, return 404 ("This link has expired or was not found").
4. Stream it back with the stored metadata and `Content-Disposition: attachment`
   so it downloads with the original filename. Set `Cache-Control: private, no-store`.

Sketch:
```js
export async function onRequestGet({ params, env }) {
  const parts = params.path; // ["<uuid>", "<name>"]
  if (!Array.isArray(parts) || parts.length !== 2)
    return new Response("Not found", { status: 404 });
  const [uuid, name] = parts;
  const key = `shared/${uuid}/${name.replace(/[^\w.\-]+/g, "_")}`;

  const obj = await env.BUCKET.get(key);
  if (!obj) return new Response("This link has expired or was not found", { status: 404 });

  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  headers.set("Cache-Control", "private, no-store");
  return new Response(obj.body, { headers });
}
```

## 9. Frontend changes (`index.html`)

The compressed output already exists as `outputBlob` after compression. Add to
the existing result box:

1. A second button, "Get share link" (opt-in, secondary style so the local
   download stays the primary action).
2. On click:
   - **Guardrail first:** if `outputBlob.size > 95 * 1024 * 1024`, do not upload.
     Show: "This file is too large to share (max ~95 MB). You can still download
     it locally." Keep the local download working.
   - Otherwise `POST` the blob to `/api/share?name=<encoded original name>.mp4`
     with header `Content-Type: video/mp4` and body `outputBlob`.
   - Show a progress indicator during the upload (reuse the existing progress bar
     styling; `fetch` upload progress is limited, so an indeterminate state or an
     `XMLHttpRequest` for real upload progress is fine).
   - On success, read `{ shareUrl }` and show it in a read-only field with a
     "Copy" button, plus text: "Link works for 24 hours, then the file is deleted."
3. Handle errors clearly (413 too large, 415 wrong type, network error). The local
   download must keep working regardless of share success.

Keep the change small and match the existing vanilla-JS style in the file. No
framework, no build step for the frontend.

## 10. Copy and messaging updates (required for accuracy / SOC 2)

The current UI says "your file never leaves your computer" and "videos are never
uploaded anywhere." That stays true for the source video, but a shared file does
go to R2. Update copy so it is accurate:

- Drop zone subtitle: keep "your file never leaves your computer" (still true for
  the source).
- Footer: change "videos are never uploaded anywhere" to something like:
  "Compression runs in your browser. If you choose to create a share link, the
  compressed file is stored securely for 24 hours, then deleted."
- Near the share button, one line: "Uploads the compressed file to a private link.
  Auto-deleted after 24 hours."
- Update `README.md`: add an "R2 share links" section describing the flow, the
  binding-based (no-credentials) model, and the 24-hour lifecycle cleanup.

## 11. Security and SOC 2 notes

- **No credentials at all.** The binding-only design means there is no API token,
  no S3 key, and no secret to store, rotate, or leak. This is the strongest part
  of the posture.
- **Private bucket, server-mediated access.** R2 is only reachable through the
  Function via the binding. Links are unguessable UUID paths.
- **Data minimization:** 24-hour lifecycle deletion, source never uploaded.
- **Bounded input:** enforce the ~95 MB cap and validate `video/mp4` server-side,
  not just in the browser.
- **The endpoint is publicly reachable.** Production is a public custom domain, so
  `/api/share` can be hit by anyone who finds it. Because there is no credential to
  steal, the main abuse vector is someone using it as free storage for arbitrary
  `video/mp4` blobs (auto-deleted in 24h). The size cap and content-type check are
  the first line of defense; a light rate limit or Turnstile is worth adding before
  this goes past demo use (§13).
- **Paper trail:** record bucket, binding, lifecycle rule, and the CORS entry in
  the project ticket.

## 12. Dev and deploy workflow (wrangler-free)

The Empire team cannot install wrangler on their managed devices, so there is no
`wrangler pages dev` and no local build. The entire loop runs through the
GitHub -> Cloudflare Pages Git integration.

**How the dev works:**
- Push a feature branch to GitHub. The Pages Git integration automatically builds
  a **preview deployment** at `https://<branch>.<project>.pages.dev` (plus a
  per-commit URL).
- Pages auto-detects and builds the `functions/` directory. No dependencies, so
  nothing to install; no local node or wrangler needed.
- Open the preview URL and test the real flow there. The static page, `/api/share`,
  and `/s/...` are all served from the same origin, so everything is same-origin
  with no CORS involved.
- Merge to the production branch to deploy to
  `https://video-optimizer.empireailab.com`.

**One-time setup (ZeroArc, dashboard):**
- Make sure the **R2 binding is attached to both Production and Preview**
  environments. Pages bindings are per-environment; a binding on Production only
  will make the Function throw on preview deploys. This is the one thing to verify
  now that only Production exists.
- Confirm preview builds are enabled for non-production branches (Settings >
  Builds & deployments).

**Test checklist (on a preview deploy):**
- Compress a small clip, click Get share link, confirm the object lands in the
  bucket under `shared/`.
- Open the share URL in an incognito window, confirm it downloads with the right
  filename.
- Try a file over ~95 MB and confirm the guardrail blocks it cleanly.
- Confirm the object is gone after the 24h lifecycle window (or delete manually to
  re-verify the 404 path).

**Iteration note:** because there is no local server, each change is validated by
pushing and waiting for the preview build. Batch changes to keep the loop
efficient.

## 13. Out of scope / future

- **Files over 100 MB.** If a rare 4K/long clip exceeds the cap after compression,
  the fallback is presigned multipart upload direct to R2 (which reintroduces an
  API token). Not needed for the demo; documented here so the ceiling is a known,
  deliberate limit rather than a surprise.
- Real upload progress (resumable / streamed).
- Turnstile or rate limiting on `/api/share`.
- Any server-side transcoding (explicitly rejected: keeps the demo simple and
  preserves the in-browser compression story).

## 14. Implementation checklist

**ZeroArc (dashboard, off the Empire team's machines):**
- [x] Create the R2 bucket, private (§7.1)
- [x] Bind the bucket to the Pages project (§7.2)
- [x] Set CORS + 24h lifecycle (§7.3, §7.4) — CORS not required but done
- [x] Binding variable name is `BUCKET` (§7.2)
- [x] Binding attached to **both** Production and Preview (§12)

**Empire dev (via GitHub -> Pages Git integration):**
- [ ] Add `functions/api/share.js` (upload) and `functions/s/[[path]].js` (download) (§8)
- [ ] Wire the "Get share link" button, guardrail, and upload flow in `index.html` (§9)
- [ ] Update UI copy and README for accuracy (§10)
- [ ] Test end to end on a preview deploy, then merge to production (§12)
- [ ] Verify the object is gone after 24h (lifecycle) (§12)
```

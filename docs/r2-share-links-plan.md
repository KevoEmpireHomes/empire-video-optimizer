# Planning Doc: R2 Share Links for the Video Optimizer

**Status:** Ready for implementation
**Owner (implementer):** Empire dev
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

## 2. What stays the same (do not touch)

- Compression still happens 100% in the browser with ffmpeg.wasm. The raw
  source video is never uploaded.
- The current local "Download compressed video" button stays exactly as-is.
- The Cloudflare **Pages** deployment stays. We are not moving to Workers or
  Containers.
- Vendored ffmpeg under `vendor/`, the `_headers` COOP/COEP file, and
  `scripts/vendor-ffmpeg.sh` all stay.

## 3. What changes

- Add **Pages Functions** (`/functions/api/...`) to the same repo. These run
  server-side on the same deploy and hold the R2 credentials. The browser never
  sees a secret.
- Add an opt-in "Get share link" button that appears next to the existing
  download button after compression completes.
- Only the **compressed output** is uploaded, and only when the user clicks the
  button. Nothing uploads automatically.
- The link is a **private, presigned GET URL** that expires in 24 hours. The R2
  bucket stays private (no public access).
- An R2 **lifecycle rule** deletes uploaded objects 24 hours after upload.
- Update the user-facing copy and README so the privacy claim is accurate: the
  source never leaves the machine, but a shared compressed file is stored in R2
  for up to 24 hours.

## 4. Why a server-side piece is unavoidable

R2 credentials (Access Key ID / Secret) can never ship to the browser. To let
the browser upload directly to R2 without exposing a secret, a small server-side
endpoint signs a short-lived **presigned URL**. The browser then PUTs the file
straight to R2 using that URL. The secret stays on the server (Pages Function),
the large file bytes never pass through our server.

Presigning is done with [`aws4fetch`](https://github.com/mhart/aws4fetch), a tiny
SigV4 library that runs fine in the Pages Functions (Workers) runtime. Do **not**
pull in the full `@aws-sdk` packages; they are large and unnecessary here.

## 5. Architecture and data flow

```
Browser                              Pages Function (server)          R2 (private bucket)
  |                                          |                              |
  | 1. compress video locally (ffmpeg.wasm)  |                              |
  |    (unchanged, produces outputBlob)      |                              |
  |                                          |                              |
  | 2. user clicks "Get share link"          |                              |
  |-- POST /api/create-share --------------->|                              |
  |    { filename, contentType, size }       | mint key: shared/{uuid}/name |
  |                                          | presign PUT (expires 5 min)  |
  |                                          | presign GET (expires 24 h,   |
  |                                          |   content-disposition=attach)|
  |<-- { uploadUrl, shareUrl, key } ---------|                              |
  |                                          |                              |
  | 3. PUT compressed blob directly to R2 ------------------------------->  | shared/{uuid}/name
  |    (uses uploadUrl, browser -> R2)       |                              |
  |                                          |                              |
  | 4. show shareUrl to user (copy button)   |                              |
  |                                          |                              |
  | 5. recipient opens shareUrl ---------------------------------------->   | streams file, then
  |                                          |                              | 24h lifecycle deletes
```

Notes:
- Both presigned URLs are generated in one request (step 2) so we only sign once.
- The upload URL is short-lived (a few minutes) because it is used immediately.
- The share (download) URL expiry matches the 24-hour retention so the link dies
  around the same time the object is cleaned up.

## 6. Cloudflare resources to provision

These are one-time setup steps done in the Cloudflare dashboard or via wrangler.
Daniel (ZeroArc) will provision, or grant the dev scoped access. Record these in
the project ticket for the SOC 2 paper trail.

1. **R2 bucket** — e.g. `empire-video-optimizer`. Keep it **private** (do not
   enable public r2.dev access).

2. **R2 API token** — scoped to **Object Read & Write on that one bucket only**
   (least privilege). This yields an **Access Key ID** and **Secret Access Key**
   plus the **Account ID**. Treat the secret like any other credential: never
   commit it, never log it.

3. **Bucket CORS policy** — required so the browser can PUT directly to R2.
   Restrict the origin to the Pages domain (and the local dev origin during
   development). Example:
   ```json
   [
     {
       "AllowedOrigins": [
         "https://<project>.pages.dev",
         "http://localhost:8788"
       ],
       "AllowedMethods": ["PUT", "GET"],
       "AllowedHeaders": ["content-type"],
       "ExposeHeaders": ["etag"],
       "MaxAgeSeconds": 3600
     }
   ]
   ```

4. **Lifecycle rule** — on the bucket, add a rule to **delete objects 1 day
   after creation**, scoped to the `shared/` prefix. R2 lifecycle rules are
   day-granular, so 24 hours maps to exactly one rule with no custom cron. This
   is the cleanup mechanism; do not build a separate delete job.

5. **Pages secrets** — set on the Pages project (Production and Preview):
   - `R2_ACCOUNT_ID`
   - `R2_ACCESS_KEY_ID`
   - `R2_SECRET_ACCESS_KEY`
   - `R2_BUCKET` (bucket name, can also be a plain var)

   Set via dashboard (Settings > Environment variables, mark as encrypted) or
   `wrangler pages secret put R2_ACCESS_KEY_ID`.

   Optional alternative: an **R2 binding** in `wrangler.toml` gives the Function
   direct bucket access, but presigning still needs the raw S3 credentials, so
   secrets are required regardless. Use secrets.

## 7. Server-side endpoint

Create `functions/api/create-share.js` (or `.ts`). One POST endpoint.

Responsibilities:
1. Validate input: `filename`, `contentType` (must be `video/mp4`), and `size`.
   Reject anything over a sane max (e.g. 500 MB) to bound abuse.
2. Sanitize the filename; never trust it for the key path.
3. Generate a key: `shared/{crypto.randomUUID()}/{safeName}`.
4. Build the R2 S3 endpoint:
   `https://{R2_ACCOUNT_ID}.r2.cloudflarestorage.com/{R2_BUCKET}/{key}`.
5. Use `aws4fetch`'s `AwsClient.sign(..., { aws: { signQuery: true } })` to
   produce:
   - a **presigned PUT** URL, expiry ~300s, signing the `content-type`.
   - a **presigned GET** URL, expiry 86400s, with
     `response-content-disposition=attachment; filename="..."` so the link
     downloads with a friendly name.
6. Return `{ uploadUrl, shareUrl, key, expiresAt }` as JSON.

Guardrails:
- CORS: the Function should only accept requests from our own origin. Same-origin
  by default on Pages, so no extra CORS headers needed for the Function itself
  (the CORS config in step 6.3 is for the browser -> R2 PUT, a different hop).
- Do not echo secrets or the full signed Secret Access Key anywhere.
- Region is `auto` for R2. Service is `s3`.

Presigning sketch (pseudocode, verify against current aws4fetch API):
```js
import { AwsClient } from "aws4fetch";

const client = new AwsClient({
  accessKeyId: env.R2_ACCESS_KEY_ID,
  secretAccessKey: env.R2_SECRET_ACCESS_KEY,
  service: "s3",
  region: "auto",
});

const base = `https://${env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${env.R2_BUCKET}/${key}`;

const put = await client.sign(
  new Request(`${base}?X-Amz-Expires=300`, { method: "PUT" }),
  { aws: { signQuery: true } }
);

const disp = `attachment; filename="${safeName}"`;
const get = await client.sign(
  `${base}?X-Amz-Expires=86400&response-content-disposition=${encodeURIComponent(disp)}`,
  { aws: { signQuery: true } }
);

return Response.json({ uploadUrl: put.url, shareUrl: get.url, key });
```

## 8. Frontend changes (`index.html`)

The compressed output already exists as `outputBlob` after compression. Add to
the existing result box:

1. A second button, "Get share link" (opt-in, secondary style so the local
   download stays the primary action).
2. On click:
   - POST to `/api/create-share` with `{ filename, contentType: 'video/mp4',
     size: outputBlob.size }`.
   - `PUT` `outputBlob` to the returned `uploadUrl` with header
     `Content-Type: video/mp4`.
   - Show a progress indicator during the PUT (reuse the existing progress bar
     styling; `fetch` upload progress is limited, so a simple indeterminate
     state or `XMLHttpRequest` for upload progress is fine).
   - On success, show the `shareUrl` in a read-only field with a "Copy" button,
     plus text: "Link works for 24 hours, then the file is deleted."
3. Handle errors clearly (network failure, oversized file, server error). Keep
   the local download working regardless of share success.

Keep the change small and match the existing vanilla-JS style in the file. No
framework, no build step for the frontend.

## 9. Copy and messaging updates (required for accuracy / SOC 2)

The current UI says "your file never leaves your computer" and "videos are never
uploaded anywhere." That stays true for the source video, but a shared file does
go to R2. Update copy so it is accurate:

- Drop zone subtitle: keep "your file never leaves your computer" (still true for
  the source).
- Footer: change "videos are never uploaded anywhere" to something like:
  "Compression runs in your browser. If you choose to create a share link, the
  compressed file is stored securely for 24 hours, then deleted."
- Near the share button, one line: "Uploads the compressed file to a private,
  expiring link. Auto-deleted after 24 hours."
- Update `README.md`: add an "R2 share links" section describing the flow, the
  presigned-URL model, the 24-hour lifecycle, and the required secrets/CORS.

## 10. Security and SOC 2 notes

- **Least privilege:** the R2 token is scoped to one bucket, read/write only.
- **No public bucket:** access is only via short-lived presigned URLs.
- **Data minimization:** 24-hour lifecycle deletion, source never uploaded.
- **Secret handling:** credentials live only as encrypted Pages secrets, never
  in the repo, never logged.
- **Bounded input:** enforce a max file size and validate content type server-side.
- **Paper trail:** record bucket name, token creation, CORS, and lifecycle rule
  in the project ticket.
- Consider a light rate limit or Turnstile on `/api/create-share` if the demo is
  ever exposed beyond the Empire team (future, see below).

## 11. Local development

- `npx wrangler pages dev .` serves the static site and Functions together and
  loads local secrets from a `.dev.vars` file (git-ignored). Populate `.dev.vars`
  with the four R2 values.
- Add `http://localhost:8788` (the wrangler pages dev origin) to the bucket CORS
  allowed origins during development.
- Test the full path: compress a small clip, click share, confirm the PUT lands
  in R2, open the share URL in an incognito window, confirm it downloads, then
  confirm the object disappears after the lifecycle window (or delete manually
  to verify the flow).

## 12. Out of scope / future

- Multipart upload for files larger than a single PUT (R2 single PUT handles up
  to 5 GiB; compressed listing clips are far smaller, so not needed now).
- Upload progress via streaming / resumable uploads.
- Turnstile or rate limiting on the share endpoint.
- Any server-side transcoding (explicitly rejected: keeps the demo simple and
  preserves the in-browser compression story).

## 13. Implementation checklist

- [ ] Provision R2 bucket, scoped API token, CORS, and 24h lifecycle rule (§6)
- [ ] Add the four Pages secrets (and local `.dev.vars`) (§6.5, §11)
- [ ] Add `aws4fetch` dependency and `functions/api/create-share` endpoint (§7)
- [ ] Wire the "Get share link" button and upload flow in `index.html` (§8)
- [ ] Update UI copy and README for accuracy (§9)
- [ ] Test end to end locally, then on a Pages preview deploy (§11)
- [ ] Verify the object is gone after 24h (lifecycle) (§11)
```

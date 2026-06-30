# File Storage Service

## Problem

A file storage service (Dropbox-style) lets users upload, download, share, and sync files across devices. The files are the hard part: they can be as large as 50GB. At that size the obvious design — send the bytes through an application server to a database or disk — stops working. A single request can't carry the file, the app tier can't sit in the data path, and a dropped connection can't mean restarting a 49GB upload. Almost all the design effort goes into moving large blobs reliably, not into the metadata around them.

## Requirements

Functional:

- Upload a file from any device.
- Download a file from any device.
- Share a file with other users, and see files shared with you.
- Files sync automatically across a user's devices.

Non-functional:

- Files up to 50GB.
- Availability preferred over consistency — a file uploaded in one region can take a few seconds to appear elsewhere.
- Durable and recoverable: files must survive loss or corruption.
- Low latency on upload, download, and sync.

The 50GB ceiling is the constraint that shapes everything below. Sharing and metadata are ordinary database work; the blob path is not.

## Data model and contracts

The file bytes and the file metadata are stored separately — bytes in blob storage, metadata in a database. The metadata row is what the service actually operates on.

- `FileMetadata`: `fileId` (PK, UUID), `name`, `size`, `mimeType`, `uploadedBy`, `status` (`uploading` | `uploaded`), `fingerprint` (content hash), `chunks[]` (per-chunk id + status), `s3Url`.
- `SharedFiles`: `userId` (PK), `fileId` — a separate table, so "files shared with me" is one query and isn't bounded by a row size limit.
- `User`.

`fingerprint` is a SHA-256 over the file content, not the file record. It identifies bytes, so the same file uploaded twice produces the same fingerprint — which is what makes dedup and resume possible. `fileId` stays a UUID so two users can own the same content independently.

Endpoints map to the functional requirements, but the upload endpoint is a control-plane call, not a data transfer:

```
POST  /files                      { name, size, mimeType, fingerprint, chunkFingerprints[] }
                                  -> { fileId, uploadId, presignedUrls[] }   (or existing chunk status, to resume)
PATCH /files/{fileId}/chunks      { chunkId, eTag, status }    -> verified chunk status
GET   /files/{fileId}             -> { metadata, downloadUrl }   (CDN signed URL)
POST  /files/{fileId}/share       { users[] }
GET   /files/changes?since={ts}   -> ChangeEvent[]              (sync: created | updated | deleted)
```

The file bytes never appear in a request body. `POST /files` returns presigned URLs; the client uploads chunks straight to blob storage with them.

## Design

The simplest design that satisfies "upload a file": the client POSTs the file to an application server, which writes the bytes to storage and the metadata to a database.

This is fine for small files and breaks on large ones in four specific ways:

- A 50GB file over a 100Mbps link takes ~1.1 hours in one request — past any client or server timeout.
- API gateways cap request bodies (Amazon API Gateway's hard limit is 10MB), so the single-POST upload isn't even allowed.
- A network blip restarts the whole upload from zero.
- The user sees a spinner with no progress.

Putting the app server in the data path also means every uploaded byte is paid for twice — once client→server, once server→storage — and the app tier has to scale with file volume.

So the first real design decision is to take the application servers out of the data path entirely, and the rest of the work is making a 50GB transfer survive the real world.

## Key decisions

### Keep the application tier out of the data path

- Decision: clients upload and download bytes directly to/from blob storage using presigned URLs. The service is a control plane — it authorizes, generates signed URLs, and records metadata; it never touches file bytes.
- Alternatives: proxy the bytes through the app servers (the naive design), or expose storage directly without signing.
- Trade-off: direct transfer removes the double bandwidth cost and lets the app tier scale with request count instead of data volume. Generating a presigned URL is a local cryptographic operation — no call to storage — so it's cheap. The cost is that the service no longer sees the bytes, so it can't validate content inline; it has to verify uploads after the fact (below).

### Chunked, resumable uploads

- Decision: the client splits the file into 5–10MB chunks and uploads them as a multipart upload; chunk state lives in `FileMetadata.chunks[]`.
- Alternatives: one large upload; or chunking on the server.
- Trade-off: chunking is what makes progress, parallelism, and resume possible — a dropped connection re-sends only the missing chunks, not 50GB. It also enables parallel chunk uploads to fill available bandwidth. Chunking *must* happen on the client; doing it on the server means the whole file already crossed the wire, which defeats the point. The cost is coordination: the system now tracks per-chunk state and has to assemble the parts. Blob stores provide this directly (S3 multipart upload), so most of the coordination is delegated rather than built.

### Fingerprinting for dedup and resume

- Decision: identify file content by a SHA-256 fingerprint (whole file + per chunk), separate from `fileId`.
- Alternatives: identify uploads by file name, or by `fileId` alone.
- Trade-off: names collide across users and tell you nothing about content, so resume and dedup can't key on them. A content fingerprint answers both "have I uploaded this before?" (skip it) and "which chunks already landed?" (resume from there). Per-chunk fingerprints make resume precise. The cost is hashing the file before upload, which is CPU the client pays up front — cheap next to transferring 50GB.

### Verify chunks server-side, not on the client's word

- Decision: when the client reports a chunk uploaded (`PATCH`), the service confirms it against the blob store (S3 `ListParts`) before marking it `uploaded`; the file flips to `uploaded` only after the store confirms assembly (`CompleteMultipartUpload`).
- Alternatives: trust the client's PATCH and mark chunks complete directly.
- Trade-off: trusting the client is simpler but lets a buggy or malicious client mark chunks done that never landed, producing a corrupt "complete" file. Verifying against the store costs an extra call per chunk and keeps the database honest about what's actually in storage. For a system whose non-functional requirement is reliability, that's the right side of the trade.

### Download through a CDN with signed URLs

- Decision: downloads are served from a CDN (CloudFront) via short-lived signed URLs, not directly from the origin store.
- Alternatives: serve from blob storage directly with a storage presigned URL.
- Trade-off: the CDN caches files at the edge, so repeat downloads come from a nearby node instead of the origin region — lower latency, the stated goal. Signed URLs with a short expiry (e.g. 5 minutes) keep a leaked link from being a permanent backdoor. Signed URLs are still bearer tokens, so the expiry bounds exposure rather than eliminating it; higher-security setups can add IP binding. The cost is CDN invalidation and the signing key management.

### Sync: push first, poll as a safety net

- Decision: each device holds one WebSocket connection for real-time change pushes, and also polls `GET /files/changes?since={ts}` every few minutes as a fallback.
- Alternatives: polling only (simple, laggy, wasteful), or push only (real-time but loses changes when a connection drops).
- Trade-off: push gives near-instant sync; polling guarantees eventual consistency when a socket silently drops or a message is missed. Running both means changes are fast in the common case and never permanently lost in the failure case. The cost is maintaining persistent connections plus a redundant polling path. Given availability is prioritized over consistency, the fallback is what makes "eventually" trustworthy.

## Final architecture

![Architecture](https://github.com/jovmlads/solution-architecture-articles/blob/main/file-storage/final%20design.png)

A request enters through a public **API gateway** (routing, auth, rate limiting, TLS) backed by a load balancer, which forwards to the stateless **File Service**. The File Service is the control plane: on upload it checks the fingerprint, initiates a multipart upload, writes `FileMetadata`, and returns presigned URLs; on download it issues a CDN signed URL; it reads and writes the **metadata DB** and verifies chunks against the blob store.

The data plane bypasses the gateway. The **uploader** sends chunks straight to **blob storage** with its presigned URLs; the store fires an **event on completion** back to the File Service to finalize status. The **downloader** pulls bytes from the **CDN**, which fetches from the origin store on a miss. This split — control plane through the gateway, bytes direct to storage — is the core shape of the system, and it's why a 50GB file never touches an application server.

The high-level Terraform in [`main.tf`](main.tf) provisions this architecture as infrastructure as code.

### Component → AWS service

| Component | AWS service |
|---|---|
| API gateway (routing, auth, rate limiting, TLS) | Amazon API Gateway (HTTP API), with **Amazon Cognito** as the JWT issuer |
| Load balancer (internal) | Application Load Balancer (ALB), internal, reached via a VPC link |
| File Service (control plane) | Amazon ECS on **Fargate**, scaled on request count |
| File metadata + shares | Amazon **DynamoDB** (`FileMetadata` and `SharedFiles` tables) |
| Blob storage | Amazon **S3** with multipart upload, SSE encryption, versioning for recovery |
| Upload-complete events | **S3 event notifications** → File Service (finalize status) |
| Content delivery | Amazon **CloudFront** with signed URLs, origin access to S3 |
| Real-time sync channel | Amazon API Gateway **WebSocket API** |
| Service config / signing keys | AWS **Secrets Manager** (injected into tasks, never plaintext) |

## Operational concerns

- Orphaned uploads: a `status: uploading` file whose chunks never complete leaves multipart parts in S3. An S3 lifecycle rule aborts incomplete multipart uploads after N days so they don't accrue storage cost.
- Corruption and recovery: S3 versioning plus server-side encryption cover the "recover lost or corrupted files" requirement; the chunk ETags caught a bad transfer before the file was ever marked complete.
- Consistency: file visibility is eventually consistent by design. The sync path's polling fallback bounds how stale a device can get even if its WebSocket drops.
- Delta sync at scale: fixed 5MB chunk boundaries make delta sync fragile — inserting one byte near the start shifts every later boundary and changes every downstream fingerprint. Content-defined chunking (a rolling hash like Rabin fingerprinting setting boundaries by content) keeps a small edit local to a few chunks, which is how delta sync stays cheap in practice. Deferred from the first build; noted as the extension point.
- Scaling limits: the File Service scales with request count, not data volume, because bytes never pass through it. S3 and CloudFront absorb the data-plane load. The metadata DB is the component to watch as file and share counts grow.
- Monitoring: upload completion rate and chunk-verification failures on the write path; CDN cache hit rate and download latency on the read path; WebSocket connection counts and poll volume on the sync path.

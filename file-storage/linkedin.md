A file storage service like Dropbox is easy to build until someone uploads a 50GB file.

At a small scale the design is obvious:

client → app server → storage.

That single arrow falls apart at 50GB.

A 50GB file over a 100Mbps connection takes over an hour in one request — past every timeout. API gateways cap request bodies (Amazon API Gateway's is 10MB), so the single upload isn't even allowed.

The system around it is mostly ordinary:

api gateway for auth and routing
a stateless file service for metadata
a database for file records
a CDN for fast downloads

The interesting part is what the file service deliberately does not do: touch the bytes.

Instead of proxying the upload, it hands the client a set of presigned URLs and gets out of the way. The client uploads chunks — 5 to 10MB each — directly to blob storage. The service only authorizes, tracks chunk state, and verifies the result.

That one move solves most of the problem at once. Chunks give you a progress bar, parallelism to fill the bandwidth, and resumability — a dropped connection re-sends a few missing chunks, not the whole file.

What makes resume work is the fingerprint: a content hash of the file, separate from its name. Names collide and say nothing about content. A fingerprint answers "have I uploaded this before?" and "which chunks already landed?" — so an interrupted 50GB upload picks up where it stopped.

Small detail, but important: the service verifies each chunk against the store before marking it done, rather than trusting the client — otherwise a buggy client can mark a corrupt file "complete."

The rest of the design — sharing, sync, CDN downloads — is in the full write-up, with a high-level Terraform file and diagram:
[GitHub link]

#SolutionArchitecture #SoftwareArchitecture #SystemDesign #DistributedSystems #CloudArchitecture #BackendEngineering

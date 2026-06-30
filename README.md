# Solution Architecture Articles

A collection of system design and solution architecture case studies.

Each article explores how to approach a real-world system from requirements through to a production-ready architecture:

- functional and non-functional requirements
- API and data modelling
- architecture decisions
- scaling strategies
- trade-offs and failure modes
- production considerations

The goal is not to present a single "perfect" architecture, but to show the reasoning behind technical decisions and the constraints that shape them.

---

## Articles

### 🔗 URL Shortener

Designing a URL shortening platform that can handle high redirect traffic.

Topics covered:

- read/write workload separation
- Redis caching strategy
- short-code generation
- base62 encoding
- database scaling
- counter allocation and trade-offs
- availability vs consistency decisions

[Read article →](https://github.com/jovmlads/solution-architecture-articles/tree/main/url-shortener)

---

### 📦 File Storage Service

Designing a Dropbox-style file storage service where the hard part is moving large files (up to 50GB) reliably.

Topics covered:

- keeping the application tier out of the data path
- direct-to-blob uploads with presigned URLs
- chunked, resumable uploads
- content fingerprinting for dedup and resume
- server-side chunk verification
- CDN downloads with signed URLs
- push/poll file sync

[Read article →](https://github.com/jovmlads/solution-architecture-articles/tree/main/file-storage)

---

## Approach

The designs follow a consistent architecture process:

1. Understand the requirements and constraints
2. Identify the core entities and APIs
3. Build the simplest design that satisfies the requirements
4. Scale and harden the system based on real bottlenecks
5. Document trade-offs and operational concerns

---

## About

These articles are written as architecture exercises focused on building systems that are scalable, reliable, and maintainable.

They cover patterns commonly used in modern backend and cloud systems:
- distributed systems
- caching
- event-driven architectures
- API design
- data storage strategies
- scalability patterns

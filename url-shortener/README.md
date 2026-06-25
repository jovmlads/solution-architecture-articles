# URL Shortener

## Problem

A URL shortener maps a long URL to a short code and redirects to the original when the code is visited. It optionally supports a custom alias and an expiration date. The interesting part is not the mapping — it's that lookups vastly outnumber creations, so most of the design effort goes into the read path and into generating codes that stay unique as the system grows.

## Requirements

Functional:

- Submit a long URL and get back a short URL.
- Optionally set a custom alias.
- Optionally set an expiration date.
- Visiting a short URL redirects to the original.

Non-functional:

- Short codes are unique — one code maps to exactly one long URL.
- Redirect latency under ~100ms.
- 99.99% availability, with availability preferred over consistency.
- Scale to 1B stored URLs and 100M daily active users.
- Read-heavy: roughly 1000 reads per write.

The read/write skew is the constraint that shapes everything below. Creation is rare; redirection is constant.

## Data model and contracts

One entity does the work: a URL mapping.

- `short_code` (or custom alias) — primary key
- `long_url`
- `creation_time`
- `expiration_time` (optional)
- `created_by` (optional)

Two endpoints cover the functional requirements:

```
POST /urls            { long_url, custom_alias?, expiration_date? } -> { short_url }
GET  /{short_code}    -> 302 Location: <long_url>   (410 if expired)
```

A 301 would let browsers cache the redirect and skip the server on repeat hits. That gives up the ability to expire links, retarget them, or count clicks later. A 302 keeps every request flowing through the service. The extra traffic is the price of keeping control, so redirects use 302.

## Design

The simplest version that satisfies the functional requirements: a stateless application server in front of a single relational database.

On a write, the server validates the URL, generates a code, and inserts the mapping. On a read, it looks up the code and returns a 302. One Postgres table keyed by `short_code`, with an index so lookups don't full-scan.

This is enough for the features. It falls short on two non-functional requirements once traffic climbs:

- redirect latency under read load, and
- code generation once the write side runs on more than one instance.

The decisions below address those, in that order.

## Key decisions

### Short code generation

- Decision: a monotonic counter encoded in base62.
- Alternatives: hash the long URL and truncate; or generate random codes.
- Trade-off: hashing and random both push collision handling into the write path — generate, check for existence, retry on conflict. A counter is unique by construction, and base62 keeps it short (62⁷ ≈ 3.5 trillion codes in 7 characters). The cost is that every writer now depends on a shared counter. Custom aliases are kept in a separate namespace and checked on write, so they can't collide with generated codes.

### Read path caching

- Decision: a Redis cache in front of the database, keyed `short_code → long_url`.
- Alternatives: rely on the database index alone.
- Trade-off: the index prevents full scans but still hits the database on every redirect. At 1000:1 skew, caching the lookup removes most of that load and keeps redirects inside the latency target. The cost is invalidation — a changed or deleted link can be served stale. Bounding the cache TTL by the URL's expiry keeps stale entries from outliving the link.

### Splitting read and write services

- Decision: separate read and write services behind a load balancer, scaled independently.
- Alternatives: one service scaled as a single unit.
- Trade-off: a combined service has to provision for read volume across a fleet that also carries writes it doesn't need to scale. Splitting adds routing and deployment overhead, but lets the read fleet grow with redirect traffic while the write side stays small (creation is ~1/sec at these numbers).

### Coordinating the counter across writers

- Decision: a central Redis counter with atomic `INCR`, leased to each write instance in batches of 1000.
- Alternatives: per-instance counters, or a database sequence.
- Trade-off: per-instance counters collide as soon as writes are horizontally scaled. A central counter is a single source of truth but adds a network hop per write and a shared dependency. Batch leasing amortizes the hop across 1000 writes. If an instance dies holding a batch, those numbers are lost — acceptable, because the requirement is uniqueness, not a gapless sequence. The `UNIQUE` constraint on `short_code` is the final backstop.

## Final architecture

![`Final Design`](https://github.com/jovmlads/solution-architecture-articles/blob/e2888573af391358bcb7dd3ebde332fa34ec67d3/url-shortener/final%20design.png)

Traffic enters through a load balancer and an API gateway that handles routing, auth, rate limiting, and TLS, then splits to two services. The write service leases a code from the Redis counter, encodes it, and writes the mapping to the database primary. The read service resolves codes through the Redis cache and falls back to a read replica on a miss, then returns the 302.

Storage is not a constraint here. At ~500 bytes per row, 1B rows is roughly 500GB, which fits on a single Postgres instance — so sharding is deferred until there's a real ceiling rather than built up front.

A high-level Terraform setup for this architecture lives in [`main.tf`](main.tf), mapping each component to a managed AWS service.

### Component → AWS service

| Component | AWS service |
|---|---|
| API gateway (routing, auth, rate limiting, TLS) | Amazon API Gateway (HTTP API), with **Amazon Cognito** as the JWT issuer for `POST /urls` |
| Load balancer (internal, path-based routing) | Application Load Balancer (ALB), internal, reached via a VPC link |
| Write / read services | Amazon ECS on **Fargate** — one image, `ROLE` env var selects behaviour; the read fleet scales independently |
| Global counter + lookup cache | Amazon **ElastiCache for Redis** (two replication groups) |
| URL store (primary + read replicas) | Amazon **RDS for PostgreSQL** (Multi-AZ primary + read replicas) |
| Service config / DB credentials | AWS **Secrets Manager** (injected into the tasks, never plaintext) |

## Operational concerns

- Counter failure: run Redis with replication and automatic failover (Sentinel or Cluster). A lost batch leaves gaps, never duplicates, and the `UNIQUE` constraint catches the rest.
- Database availability: read replicas carry redirect traffic and absorb the loss of a node; the primary handles writes with Multi-AZ failover and periodic backups.
- Cache staleness: TTL is bounded by URL expiry; a miss falls through to a replica.
- Scaling limits: the read fleet and replica count scale with redirect volume. The write side and counter are far from their limits at these rates. Multi-region is reachable by giving each region a disjoint counter range so writes stay local while reads serve from regional caches.
- Monitoring: redirect latency and cache hit rate on the read path; counter lease rate and Redis availability on the write path.

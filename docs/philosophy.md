# Philosophy

Doot exists because the modern web development ecosystem is over-provisioned for what most applications actually need. Non-technical and semi-technical users can get an AI coding agent to *write* a web app easily. The struggle starts after: choosing a runtime, choosing a framework, choosing a deployment target, configuring environment variables, and dealing with an ecosystem that assumes distributed infrastructure by default.

Doot is built on a single, clear belief: **the right way to make "write code then ship it" simple is to remove decisions, not add configuration options.**

---

## The 6 Core Rules

These are non-negotiable. They apply to every design decision, every feature, and every future version of Doot. They are not trade-offs to be revisited; they are the foundation the entire system is built on.

### Rule 1: Local-first. Monolith only. Always, forever.

No distributed systems. No multi-tenant architecture. No clustering. No microservices. No service mesh.

A Doot application runs as a single process on a single machine. This is not a limitation to be worked around; it is a deliberate architectural constraint that eliminates entire categories of complexity: network partitions, distributed consensus, service discovery, inter-service auth, eventual consistency, and deployment orchestration.

The target user does not need horizontal scaling. If they ever do, they have outgrown Doot, and that is perfectly fine (see [Graduation Path](#graduation-path) below).

### Rule 2: SQLite only.

No Postgres. No MySQL. No Redis. No MongoDB. No external database connectors of any kind.

SQLite is sufficient for 99% of the applications Doot targets. With single-writer queuing, batch flush, and `busy_timeout`, SQLite handles concurrent web traffic gracefully. The database lives on the same machine as the application, eliminating network latency, connection pooling complexity, and credential management for external services.

This constraint also means:

- No ORM abstraction layers designed to paper over database differences
- No database migration tooling that must account for multiple backends
- No "which database should I use?" decision for the user
- Background jobs, sessions, and scheduling all use the same SQLite instance

### Rule 3: One path for everything.

Never offer two ways to do the same thing. No runtime choice. No framework choice. No "pick your deployment target" dilemma. No package manager drama.

When there is one path, documentation is simple, debugging is predictable, and an AI agent can write correct code without disambiguation. Two paths means the user (or their agent) must understand the trade-offs between them. Doot removes that burden entirely.

This rule applies at every level:

- One way to define routes
- One way to query the database
- One way to handle auth
- One way to deploy
- One template engine
- One migration system (same for dev and prod)

### Rule 4: Secure/deny by default.

If something is ambiguous or the user forgets to configure it, the safe/restrictive behavior wins. Never the permissive one.

Concrete applications of this rule:

- All routes require authentication by default. A route must explicitly declare `auth: public` to be accessible without login.
- Template output is auto-escaped by default. Raw output requires deliberate opt-in.
- CORS is denied by default.
- Environment variables that are required but missing cause a fail-fast error at deploy time, not a silent runtime failure.

The failure mode of a forgotten configuration should always be "this does not work yet" rather than "this is open to everyone."

### Rule 5: Escape hatch exists but must not be the easy/obvious path.

Doot provides a `native do ... end` block that gives full access to the underlying Nim standard library. This exists because no DSL can cover every possible need. But the escape hatch is deliberately:

- Verbose in syntax (friction is intentional)
- Documented at the end of the docs, not in onboarding
- Block-scoped only (never file-level)
- Positioned as a last resort, not a first instinct

The goal is that 95%+ of Doot applications never need the escape hatch. When they do, it should feel like a conscious decision, not a casual shortcut.

See [docs/escape-hatch.md](escape-hatch.md) for full details.

### Rule 6: No Docker, no Kubernetes, no reverse proxy configuration exposed to the user.

No image layers. No compose files. No Traefik. No nginx configuration. No container orchestration of any kind.

These abstractions do not exist for the Doot user, so their failure modes cannot leak either. Deployment is: push code, `dootd` builds it, `dootd` runs it. The user never sees a Dockerfile, never writes a `docker-compose.yml`, never configures proxy headers.

If TLS is needed, users front their server with Cloudflare or similar. If native TLS is added post-v1, it will be built into `dootd` itself (e.g., built-in ACME/Let's Encrypt), never an external proxy dependency.

---

## The Core Bet

Doot is built on the belief that:

> **99% of the apps Doot will ever run do not need distributed infrastructure, multiple databases, or container orchestration.**

The modern web ecosystem treats distributed systems as the default starting point. Postgres, Redis, Docker, Kubernetes, message queues, CDNs, edge functions, serverless. These are presented as baseline requirements even for applications that will serve 10 users.

Doot rejects this framing. A single SQLite-backed binary on a single VPS is sufficient for:

- Internal team tools (10-200 users)
- Personal projects and side businesses
- MVPs and prototypes that need to ship fast
- Small SaaS products in their first years
- Community sites and forums
- Content management systems
- Dashboards and admin panels

The bet is not that these applications will *never* need more. The bet is that they do not need more *today*, and that starting with unnecessary complexity costs more than migrating later.

---

## Remove Decisions, Not Add Configuration

The core design principle is **subtraction, not addition**.

Every "obvious" feature of a modern web framework represents a decision the user must make:

| Traditional ecosystem | Doot equivalent |
|-|-|
| "Which database?" (Postgres, MySQL, Mongo, etc.) | SQLite. No choice needed. |
| "Which ORM?" (ActiveRecord, Prisma, Drizzle, etc.) | Auto-generated query interface from schema. |
| "Which template engine?" (EJS, Pug, Handlebars, etc.) | Built-in Pug-style templates. |
| "Which auth library?" (Passport, NextAuth, Devise, etc.) | Built-in auth system. |
| "Which job queue?" (Sidekiq, Bull, Celery, etc.) | Built-in SQLite-backed queue. |
| "How to deploy?" (Docker, Vercel, Fly, Railway, etc.) | `dootd` on a VPS. Push and done. |
| "Which bundler?" (Webpack, Vite, esbuild, etc.) | None. Serve static files as-is. |

Each row in the left column is a decision that produces documentation, tutorials, comparison articles, and configuration files. Each row in the right column is a decision that has already been made.

Configuration is not inherently bad, but *premature* configuration is. Doot's position is that configuration should only exist when there is a genuine, observed need for variation. Until then, the single default path is better than the most flexible set of options.

---

## Non-Goals

The following are explicitly, permanently out of scope. They are not "future features" or "post-v1 considerations." They are things Doot will never do.

- **Docker/container support** - No Dockerfiles, no container images, no compose files. Doot compiles to a native binary and runs directly on the host.
- **Kubernetes/orchestration** - No pod specs, no services, no ingress controllers. One binary, one machine.
- **Postgres/MySQL/external databases** - SQLite only, always. Not as a "development default" that switches in production. SQLite everywhere.
- **Redis/Memcached/external caches** - Session store, job queue, and caching all use SQLite. No external stores.
- **Multi-runtime JavaScript** - No Node.js, no Bun, no Deno. No server-side JS of any kind. No npm, no node_modules.
- **Bundlers and build pipelines** - No Webpack, no Vite, no esbuild. Static assets are served as-is (compressed at serve time).
- **Microservices architecture** - One monolith. Always.
- **Multi-tenant hosting** - One `dootd` instance manages apps for one user/team. Not a shared platform.
- **Reverse proxy configuration** - No nginx, no Traefik, no HAProxy configs exposed to or managed by the user.

---

## Graduation Path

Doot includes an honest, documented exit point. This is not a failure of Doot; it is a feature of Doot.

### When to leave Doot

You should consider graduating from Doot when:

- **Your SQLite database is genuinely bottlenecked.** Not "I think I might need Postgres someday" but "I have measured write contention that SQLite cannot handle." For most apps, this means thousands of concurrent writers, which is far beyond Doot's target audience.
- **You need true horizontal scaling.** Multiple servers, load balancers, distributed state. If your app serves enough traffic that one machine cannot handle it, you have outgrown the monolith.
- **You need a specialized database.** Time-series data at scale (use TimescaleDB), graph queries at scale (use Neo4j), full-text search at massive scale (use Elasticsearch). SQLite's built-in FTS is sufficient for small-to-medium search needs.
- **You need multi-region deployment.** If latency across continents matters to your users, you need infrastructure Doot will never provide.

### Where to go

Doot does not prescribe a specific "next step" framework, but honest recommendations include:

- **Rails** (Ruby) - Full-featured, mature, strong conventions
- **Laravel** (PHP) - Similar philosophy to Rails, excellent ecosystem
- **Phoenix** (Elixir) - If you need real concurrency and fault tolerance
- **Django** (Python) - If your team already knows Python

### The attitude

Graduating from Doot is success, not failure. It means the application grew beyond what a deliberately simple tool was designed to handle. Doot got you from zero to a working, deployed application without the overhead of the full ecosystem. Now you know exactly what your application needs, and you can choose the right tool with that knowledge.

The worst outcome is not "outgrowing Doot." The worst outcome is spending your first six months fighting Docker, Kubernetes, and Postgres configuration for an app that will serve 50 users.

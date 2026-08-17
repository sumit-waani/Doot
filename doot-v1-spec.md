# Doot — v1 Design Spec

## 1. Problem

Non-technical / semi-technical users can get an AI coding agent to *write* a web app easily. The struggle starts after: choosing a runtime, choosing a framework, choosing a deployment target (Cloudflare vs Vercel, each with its own quirks), configuring environment variables, and dealing with an ecosystem (npm/node_modules, Docker, Postgres, Redis) that's over-provisioned for what the app actually needs. Even technically capable people (systems background, etc.) struggle to navigate the modern web/JS ecosystem.

Two "obvious" fixes — build a new framework on an existing stack, or build a whole new programming language — are both rejected as not ideal for this problem.

## 2. Approach

Build a **DSL** (not a full language) for web projects, with:
- A **CLI** for local development
- A **web dashboard tool** (`dootd`) for production deployment/management on a single VPS

Why a DSL and not a framework or a language:
- Simple, constrained syntax — easy for both humans and agents to write correctly
- Uses the underlying stack's raw performance (compiles to a native binary)
- Deliberately **not Turing-complete-first** — constrained by design so there's one obvious way to do things
- Has an **escape hatch** for power users to drop into raw host-language code when truly needed

Core benefit: a compact, single-page spec that an agent can be fed, and it can write a full working project without ambiguity — using the escape hatch only when it genuinely knows it needs to.

## 3. Name

**Doot** — CLI binary name `doot`, file extension `.do`. Domain: `doot.run`.

## 4. Core Philosophy (non-negotiable rules)

1. **Local-first. Monolith only. Always, forever.** No distributed systems, no multi-tenant, no clustering.
2. **SQLite only.** No Postgres, no Redis, no external DB connectors of any kind.
   - Single-writer queue, batch flush, busy_timeout — sufficient for 99% of apps Doot targets.
   - Apps that outgrow this are explicitly told: "move to Rails/Laravel/Phoenix/whatever fits you better." This is a documented, honest exit point — not a failure of Doot.
3. **One path for everything.** Never offer two ways to do the same thing (no runtime choice, no framework choice, no "pick your deployment target" dilemma, no package manager drama).
4. **Secure/deny by default.** If something is ambiguous or the user forgets to configure it, the safe/restrictive behavior wins — never the permissive one.
5. **Escape hatch exists but must not be the easy/obvious path.** It should be deliberately harder to reach, buried at the end of docs, and never used just because "it sounds cool."
6. **No Docker, no Kubernetes, no reverse proxy configuration exposed to the user.** No image layers, no compose files, no Traefik — these abstractions don't exist for the Doot user, so their failure modes can't leak either.

## 5. Runtime / Language Choice

Doot's DSL compiles to a **single, self-contained native binary**. No runtime dependency, no node_modules, no package registry resolution at deploy time.

**Host/implementation language: Nim.**

Why Nim over alternatives considered:
- **Rust** — rejected. Borrow checker fights the "compile and ship fast" workflow; no benefit for this use case.
- **Zig** — rejected for v1. Too early/unstable (pre-1.0, frequent breaking changes); not enough maintainer bandwidth to chase upstream churn.
- **D** — close second. Mature, `vibe.d` is genuinely batteries-included for web. Rejected mainly on ecosystem/community momentum and multiple-compiler fragmentation.
- **C** — rejected. Would require hand-rolling a GC for the DSL runtime, too much foundational pain for no upside over Nim.
- **Nim (chosen)** — strong compile-time metaprogramming (macros/templates), C-level speed, Python-like readability, GC included (not fought), good C FFI for filling ecosystem gaps (e.g. bcrypt/argon2 bindings), and std lib + nimble already cover ~80% of what's needed (HTTP via `jester`/`mummy`, JSON, os/signals, `db_sqlite`).
- Ecosystem gaps (ORM, password hashing libs) are treated as "small things to fill via C FFI / macros," not blockers — deliberately evaluated as "what do we need, then how hard is it to get" rather than rejecting Nim on hypothetical ecosystem-size grounds.

## 6. CLI & Binary

**Single binary. Combines CLI (local dev) and dootd (production daemon + dashboard).** No separate binaries, no separate workflows to manage. Doot's target users don't care about binary size (same category of user who never asks "how big is this CLI").

Commands:
- `doot new <name>` — scaffold a new project
- `doot dev` — local dev server, hot-reload, verifies the project compiles/runs
- `doot test` — (syntax/design deferred to post-v1, depends on DSL specifics settling in real use)
- `doot help`
- `doot --prod [flags]` — switches the same binary into production daemon mode (see §10)

There is **no standalone `doot build` CLI command** for producing a deployable artifact manually. Build is entirely a `dootd` responsibility — git push → dootd builds → dootd runs. This keeps deployment to a single path (Rule #3). Manual/local builds are explicitly out of scope because Doot isn't meant for "general purpose, ship-a-CLI-executable" use cases — that's a different tool's job.

## 7. Project Structure

Feature-fused, not layer-based (explicitly **not** classic MVC — MVC's per-feature scatter across controllers/models/views is overhead for small apps).

```
app.do          # entry point: schema, app-level config (port, session secret via .env), mounts other files
posts.do        # routes + handlers + direct DB queries for the "posts" feature
comments.do
jobs.do         # background jobs / scheduled tasks
helpers.do      # shared utility functions (formatting, slugify, etc.)
views/
  posts/
    index.do
    show.do
  layouts/
    base.do
  partials/
    comment_form.do
```

- Schema lives inside `app.do` — not a separate `db/schema.do`. It's a declarative, app-level concern, same tier as config.
- No dedicated "model" layer — schema declaration auto-generates a query interface (`db.posts.*`); no ORM model classes to define.
- Views are separated (unlike routes/handlers) because layout/inheritance/partials are a genuinely cross-cutting concern that benefits from separation.
- **Shared/cross-feature queries** (e.g. a "published posts" query reused across features) — explicitly **not** solved in v1. If a pattern repeats, it gets wrapped into `helpers.do`. No generic "shared model layer" invented speculatively. Deferred until a real repeated case is observed.
- **Guards/middleware beyond auth** — not deeply designed yet; parked, not urgent, `auth:` on routes covers the main known need (see §9).

## 8. DSL — Routes, Handlers, Schema

Example (posts feature):

```
# app.do
schema do
  table "posts" do
    field "title", :string, required: true, max: 200
    field "body", :text, required: true
    timestamps   # created_at, updated_at auto
  end
end
```

```
# posts.do
group auth: required do
  route GET "/posts/new" do |ctx|
    render "posts/new"
  end

  route POST "/posts" do |ctx|
    result = db.posts.create(
      title: ctx.form["title"],
      body: ctx.form["body"]
    )
    if result.ok?
      redirect "/posts/#{result.post.id}"
    else
      render "posts/new", errors: result.errors
    end
  end
end

route GET "/posts", auth: public do |ctx|
  posts = db.posts.all(order: "created_at desc")
  render "posts/index", posts: posts
end

route GET "/posts/:id", auth: public do |ctx|
  post = db.posts.find(ctx.params["id"])
  render "posts/show", post: post
end
```

Key decisions:
- `db.<table>.*` — auto-generated query interface from schema, no model classes.
- `ctx` — single object carrying params, form data, session, current_user, etc.
- `render "view/path", key: value` — **explicit locals only**, no implicit instance-variable leakage into views (Rails-style implicit passing rejected as less agent-friendly — explicit means the view's data contract is visible right in the handler).
- Validation is **explicit and user-declared** on the schema (`required:`, `max:`, `validate: :email`, etc.) — never implicit/magic.
- `db.<table>.create(...)` returns a **result object** (`result.ok?`, `result.errors`), not an exception. Explicit branching over exceptions — more predictable for an agent to write correctly.
- Route registration is flat/top-level — no controller classes to wrap things in.

## 9. Auth (Built-in, Opinionated)

Auth is judged the highest-risk, most error-prone part of any system if left to user/agent discretion (plaintext passwords, weak session handling, missing expiry, timing attacks). Therefore: **fully built-in, not a DSL-composed feature.**

```
schema do
  auth :users do
    roles ["admin", "editor", "member"]   # opt-in; omit for plain auth w/o roles
    email_verification true               # opt-in; false by default (requires SMTP config)
  end
end
```

What this gives for free:
- `POST /signup`, `POST /login`, `POST /logout` — built-in, overridable
- Password hashing (argon2/bcrypt) — handled internally, invisible to the user
- Session creation + signed cookie handling — automatic
- `ctx.current_user` — available in every handler, guaranteed non-nil inside `auth: required` scopes
- Role checks at the route/group level:
  ```
  group auth: required, role: "admin" do
    route GET "/admin/dashboard" do |ctx| ... end
  end
  ```
- Optional email verification flow (uses the built-in jobs system to send the email — see §11)

**Explicitly out of scope / user's own job:** profile data (name, avatar, preferences, anything beyond identity+credentials). That's normal application data via a regular `schema do table end`, not part of the `auth` block.

**Default auth posture (applies to ALL routes, not just auth block):** `auth: required` is implicit by default. Any route must **explicitly** declare `auth: public` to be reachable without login. **Deny by default, not allow by default** — if a route's auth is forgotten, the fail mode is "nobody can access it," never "everybody can access it."

## 10. Secrets / Credentials

**Hard, universal rule:** any credential — SMTP creds, S3 keys, third-party API keys, anything — lives **only** in `.env`. Never hardcoded in schema/route/config files (also enforced as a rule an agent must follow, to avoid accidentally committing secrets to GitHub).

**Fail-fast, unconditionally.** If a feature requires an `.env` value (e.g. `email_verification: true` needs SMTP config) and it's missing, this must be caught and fail **at deploy time**, before the app ever runs — never silently fail at runtime. `dootd` is responsible for validating required env vars against what's actually configured before starting a deploy, and should tell the user exactly which vars are missing.

## 11. Jobs / Queue / Scheduler

Rejected framing: "only large-scale apps need this." Basic web apps — even a 10–20 person internal team tool — routinely need background jobs, queues, and scheduling. This is a basic need, not a scale-driven one. But it must stay consistent with the "SQLite-only, no distributed infra" rule — no Redis/Sidekiq-style setup.

Design:
- **Queue = a SQLite table** (`id, job_type, payload(json), status, run_at, attempts, locked_at`). Enqueue = one INSERT.
- **Worker = an in-process thread/async pool inside the same binary.** No separate worker process to deploy or manage. Pool size small and configurable (default small, e.g. 2–4) to avoid one slow job blocking others.
- SQLite's single-writer nature is treated as a *feature* here — it removes the race-condition problem that Postgres/Redis solve with advisory locks.
- **Scheduler/cron** = declarative DSL syntax that, internally, is just the same background loop inserting jobs into the queue at the right time. Not a separate service.
- **Retry/failure handling — kept intentionally minimal:** if a job fails, it shows up in the dashboard's failed-jobs view with a simple retry button. No complex backoff strategies, no dead-letter queue UI, no alerting system in v1.

## 12. Templates

Pug-style (whitespace-significant, no closing tags) + Jinja-style inheritance (`extends`, named `block`s, partials).

```
# views/layouts/base.do
doctype html
html
  head
    title= block title || "Doot App"
    block head
    style-embed "app.css"
  body
    nav
      a href="/" "Home"
      if ctx.current_user
        a href="/logout" "Logout"
      else
        a href="/login" "Login"
    main
      block content
    footer
      p "Built with doot"
```

```
# views/posts/index.do
extends "layouts/base"

block title
  "All Posts"

block content
  h1 "All Posts"
  if posts.empty?
    p "No posts yet."
  else
    each post in posts
      div.post-card
        h2
          a href="/posts/#{post.id}" = post.title
        p= post.body.truncate(100)
```

Key decisions:
- `=` for expression output, **auto-escaped by default** (secure-by-default, consistent with the rest of the system).
- **Multiple named blocks from day one** (not just a single `block content`) — a single-block model was initially proposed and explicitly rejected as insufficient for even a basic usable app (every page needs its own `<title>`, sometimes extra head/meta content). This directly reflects the core rule: the DSL must not feel constrained even for basic web app needs.
- `each` / `if` — keyword-based control flow, no braces.
- HTMX attributes (`hx-post`, `hx-target`, etc.) are written as plain literal attributes — no DSL wrapper, since HTMX is already declarative.
- Class shorthand: `div.post-card` (Pug-style).
- **Deferred to v2** (post-core-stability): flash/error message conventions across pages, pagination helpers. Not designed yet — intentionally, to keep core stable first.

### HTMX delivery
HTMX itself is embedded and served (gzipped) by the Doot binary/runtime directly — no CDN dependency, no npm install, no version the user has to think about. The user should ideally not even be aware a JS library is involved; it's just "how interactivity works" in Doot.

## 13. Escape Hatch

Principle: Doot should never be blamed for what happens inside the escape hatch. Doot's job is to make the escape hatch *unnecessary as often as possible* through strong, opinionated defaults — not to guarantee safety once someone deliberately steps outside the DSL.

```
route POST "/posts/:id/export-pdf", auth: required do |ctx|
  post = db.posts.find(ctx.params["id"])

  native do
    # Full, unrestricted Nim — entire stdlib available, no whitelist/sandbox.
    # ctx, db, and other DSL-scope values are accessible here.
    let pdfBytes = generatePdfFromHtml(post.body)
    ctx.sendFile(pdfBytes, "application/pdf")
  end
end
```

- Keyword deliberately verbose (`native do ... end`, not something short/tempting) — friction is intentional, not accidental.
- Scoped to a block inside a handler — never an entire file/project switching to raw Nim. Keeps the "just write the whole thing in Nim" failure mode from creeping back in.
- Full, unrestricted Nim standard library access inside the block — no artificial whitelist. Doot is not responsible for bugs/edge cases introduced here.
- DSL primitives (`db`, `ctx`, session, etc.) remain accessible inside `native` blocks, so dropping into raw code doesn't mean losing Doot's conveniences.
- **Documentation placement:** a dedicated, clearly-labeled final chapter ("When Doot Isn't Enough"), not linked prominently from onboarding/getting-started flow. States explicitly that reaching this point should be rare, and that using it means the user is expected to be capable of debugging Nim/DSL interop issues themselves — Doot's support surface ends at the DSL boundary.

## 14. dootd (Production Dashboard/Daemon)

High-level flow:
1. User writes/pushes their Doot project to GitHub.
2. SSHes into their VPS **once**, runs the binary in prod mode (see below). That's the last SSH session ever needed.
3. Logs into the web dashboard.
4. Creates an "app" — GitHub URL + PAT + any required env vars (validated fail-fast per §10).
5. Clicks deploy. `dootd` builds the app and runs it as a child process on an internal port, with host-header based routing to expose it.
6. Dashboard shows basic logs/server stats, supports redeploy on new pushes.
7. Basic cgroups-based isolation per app process.

Explicitly **out of scope**: multiple users/tenants on one dootd instance, Docker, Kubernetes, any container orchestration.

### `--prod` mode (single binary, mode flag)
```
$ doot --prod
✓ Dashboard ready at http://<ip>:8080
✓ Username: admin
✓ Password: k3x9-p2mN-q8vL   (save this — shown only once; change it from dashboard settings)
✓ Registered as a systemd service (dootd) — persists across reboots
```
- Password is **auto-generated and shown once**; user changes it later from the dashboard if desired. No manual password entry on the CLI (avoids shell-history/`ps` leakage).
- Automatically registers itself as a persistent service (systemd or equivalent) — survives SSH disconnect and VPS reboot without any extra steps from the user.
- **Idempotent by design.** Re-running `doot --prod` when a service is already configured/running does **not** re-initialize or touch existing state (this would risk wiping the local SQLite data). Instead it reports current status and offers a safe, explicit path to recover access:
  ```
  $ doot --prod
  Service already running/configured.
  Dashboard: http://<ip>:8080
  Forgot password? Run: doot --prod --reset-password
  ```
- Dashboard runs on **plain HTTP** in v1 (explicitly deferred: assigning a domain to the dashboard + real TLS/HTTPS is a post-v1 concern — considered out of scope for now to avoid scope creep).

## 15. Explicitly Deferred to Post-v1

These are flagged as real needs but intentionally *not* designed yet — either because the right shape isn't clear without real usage, or because designing them now risks over-engineering:

- `doot test` — format/syntax depends on how the DSL settles in practice.
- Shared/cross-feature query patterns beyond simple helper functions.
- Guard/middleware primitives beyond route-level `auth:`.
- Flash messages and pagination conventions in templates.
- Password reset flow specifics (auth core + email verification are in v1; broader account-recovery flows are not fully spec'd).
- Dashboard HTTPS / domain-based TLS for the dashboard itself.
- Any admin-panel scaffolding on top of built-in roles (noted as a promising future primitive, not designed).
- Detailed build-failure UX and zero-downtime redeploy mechanics within `dootd`.

## 16. Summary of the Core Bet

Doot is not trying to be a general-purpose language or a bigger framework. It is a deliberately constrained DSL + a single opinionated deployment tool, built on the belief that:
- 99% of the apps Doot will ever run don't need distributed infrastructure, multiple databases, or container orchestration.
- The right way to make "write code → ship it" simple for a non-technical user (and for an AI agent acting on their behalf) is to remove decisions, not add configuration options.
- Every "obvious" complexity — Postgres, Redis, Docker, multi-runtime JS tooling — is a deliberate, named non-goal, with an honest, documented point at which a user should graduate to a different, more scalable stack.

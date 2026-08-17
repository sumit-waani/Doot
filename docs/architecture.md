# Architecture

Doot is a DSL that compiles to a single, self-contained native binary. This document describes the system architecture: how `.do` files become a running application, how the single binary operates in different modes, and how the runtime components interact.

---

## System Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        DOOT SINGLE BINARY                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────┐    ┌────────────────┐    ┌──────────────────────┐ │
│  │  CLI Mode   │    │  Compiler      │    │  Production Mode     │ │
│  │  (doot dev) │    │  Pipeline      │    │  (doot --prod)       │ │
│  ├─────────────┤    ├────────────────┤    ├──────────────────────┤ │
│  │ File watcher│    │ Parser (RD)    │    │ Web dashboard        │ │
│  │ Dev server  │    │ AST            │    │ App manager          │ │
│  │ Recompile   │    │ Nim codegen    │    │ Build pipeline       │ │
│  │ Error report│    │ Nim compiler   │    │ Process supervisor   │ │
│  └─────────────┘    └────────────────┘    └──────────────────────┘ │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

The same binary operates in two primary modes:

1. **CLI mode** (`doot dev`, `doot new`) - Local development on the developer's machine
2. **Production mode** (`doot --prod`) - Production daemon (`dootd`) with web dashboard on a VPS

There is no separate binary for production. No separate installer, no separate workflow. One binary, two modes.

---

## Compiler Pipeline

The compiler transforms `.do` source files into a native binary. The pipeline is:

```
  .do files          AST              Nim source         Native binary
 ┌──────────┐    ┌──────────┐    ┌───────────────┐    ┌─────────────┐
 │ app.do   │    │          │    │               │    │             │
 │ posts.do │───▶│  Parser  │───▶│  Nim Codegen  │───▶│ Nim Compiler│───▶ ./app
 │ views/   │    │  (AST)   │    │  (.nim files) │    │ (native)    │
 │ ...      │    │          │    │               │    │             │
 └──────────┘    └──────────┘    └───────────────┘    └─────────────┘
```

### Stage 1: Parsing

A **handwritten recursive-descent parser** reads `.do` files and produces an Abstract Syntax Tree (AST).

Why handwritten, not Nim macros:

- The DSL uses custom whitespace-significant syntax (especially in templates) that does not fit cleanly into Nim's macro grammar
- Full control over the parsing pipeline enables precise, actionable error messages for both humans and AI agents writing `.do` files
- Sets up future LSP (Language Server Protocol) tooling for editor integration
- This is slower to bootstrap than using Nim macros, but the trade-off is accepted for long-term quality

The parser handles:

- Schema declarations (`schema do ... end`)
- Route definitions (`route GET "/path" do |ctx| ... end`)
- Template syntax (Pug-style indentation, `extends`, `block`, `each`, `if`)
- Native blocks (`native do ... end`)
- Configuration directives
- Validation and constraint declarations

### Stage 2: AST

The AST is a structured, in-memory representation of the entire Doot application. It captures:

- All schema tables, fields, constraints, and relationships
- All routes with their HTTP methods, paths, auth requirements, and handler bodies
- Template inheritance chains (extends, blocks, partials)
- Job and scheduler definitions
- Native block boundaries (marked for pass-through to Nim codegen)

### Stage 3: Nim Code Generation

The AST is transformed into valid Nim source code. This stage:

- Generates the HTTP server setup (routes, middleware, request handling)
- Generates the SQLite schema management code and query interface (`db.<table>.*`)
- Generates template rendering functions from the Pug-style view files
- Generates the job worker pool and scheduler
- Generates the auth system (signup, login, logout, session handling)
- Passes `native do ... end` block contents through as raw Nim code
- Wires all components together into a single Nim application

### Stage 4: Nim Compilation

The generated Nim source is compiled by the Nim compiler into a single, self-contained native binary. No runtime dependencies, no `node_modules`, no dynamic linking to external libraries (beyond system libc).

The Nim compiler's incremental compilation cache is used internally to speed up recompilation during development, but this is an implementation detail invisible to the user.

---

## Data Flow: Development Mode (`doot dev`)

```
┌─────────────┐     ┌───────────┐     ┌──────────────┐     ┌──────────────┐
│ User edits  │     │  File     │     │  Full        │     │  Restart     │
│ .do file    │────▶│  Watcher  │────▶│  Recompile   │────▶│  Dev Server  │
└─────────────┘     └───────────┘     └──────────────┘     └──────────────┘
                                             │
                                             ▼
                                      ┌──────────────┐
                                      │  Schema Diff │
                                      │  + Migration │
                                      │  Generation  │
                                      └──────────────┘
```

1. User edits a `.do` file (route, schema, template, etc.)
2. File watcher detects the change
3. Full recompile is triggered (parse, codegen, Nim compile)
4. If schema changed: diff is computed, migration file is generated and auto-applied
5. Dev server process is restarted with the new binary
6. Browser reflects the change

There is no granular/partial hot reload. The behavior is simple and predictable: change a file, the entire app recompiles and restarts. Nim's incremental compilation makes this fast enough for development iteration.

**Schema migrations in dev:**

- `doot dev` detects schema changes by diffing the current `app.do` schema against the last known state
- A migration file is auto-generated and committed to the `migrations/` directory
- Additive changes (new table, new column) auto-apply without prompting
- Destructive changes (rename, drop) require explicit confirmation in the terminal

---

## Data Flow: Production Mode (`doot --prod`)

```
┌──────────┐     ┌─────────────────────────────────────────────────────────┐
│  GitHub  │     │                    dootd                                │
│  (push)  │     │  ┌─────────────┐  ┌──────────┐  ┌───────────────────┐ │
│          │────▶│  │  Git Pull   │─▶│  Build   │─▶│  Start/Supervise  │ │
└──────────┘     │  └─────────────┘  └──────────┘  └───────────────────┘ │
                 │                                                         │
                 │  ┌─────────────────────────────────────────────────┐   │
                 │  │              Web Dashboard                       │   │
                 │  │  - App management     - Deploy triggers          │   │
                 │  │  - Log viewer         - Env var configuration    │   │
                 │  │  - Server stats       - Failed job retry         │   │
                 │  └─────────────────────────────────────────────────┘   │
                 │                                                         │
                 │  ┌─────────────────────────────────────────────────┐   │
                 │  │           Host-Header Routing                    │   │
                 │  │  incoming:80 ──▶ dashboard (port 8080)           │   │
                 │  │               ──▶ app-1 (port 3001)              │   │
                 │  │               ──▶ app-2 (port 3002)              │   │
                 │  └─────────────────────────────────────────────────┘   │
                 └─────────────────────────────────────────────────────────┘
```

1. User pushes code to GitHub
2. User clicks "Deploy" in the dashboard (or configures auto-deploy)
3. `dootd` pulls the latest code from the configured GitHub repo
4. Validates required env vars against what the app needs (fail-fast)
5. Runs the compiler pipeline (parse, codegen, Nim compile)
6. Applies any pending migration files
7. Starts the compiled binary as a supervised child process on an internal port
8. Routes incoming HTTP traffic to the correct app via host-header matching

---

## Runtime Architecture

A compiled Doot application runs as a single process with these internal components:

```
┌──────────────────────────────────────────────────────────────┐
│                   Compiled Doot Application                    │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │                   HTTP Server                          │  │
│  │  - Route matching         - Request/response handling  │  │
│  │  - Auth middleware        - Static file serving        │  │
│  │  - CORS enforcement       - Gzip compression          │  │
│  │  - Session cookie mgmt   - HTMX response support      │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌──────────────────┐  ┌──────────────────────────────────┐  │
│  │   SQLite          │  │   Template Engine                │  │
│  │  ┌──────────────┐ │  │  - Layout inheritance           │  │
│  │  │ App tables   │ │  │  - Named blocks                 │  │
│  │  │ Session store│ │  │  - Partials                     │  │
│  │  │ Job queue    │ │  │  - Auto-escaped output          │  │
│  │  │ Migrations   │ │  │  - Expression interpolation     │  │
│  │  └──────────────┘ │  └──────────────────────────────────┘  │
│  └──────────────────┘                                        │
│                                                              │
│  ┌──────────────────┐  ┌──────────────────────────────────┐  │
│  │  Job Worker Pool │  │   Auth System                    │  │
│  │  - Async workers │  │  - Signup/login/logout           │  │
│  │  - Job dispatch  │  │  - Password hashing (argon2)     │  │
│  │  - Retry logic   │  │  - Session management            │  │
│  │  - Scheduler     │  │  - Role-based access control     │  │
│  └──────────────────┘  └──────────────────────────────────┘  │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### HTTP Server

The HTTP server handles all incoming requests. It:

- Matches routes defined in `.do` files
- Enforces auth requirements (deny by default)
- Manages session cookies (signed session-ID cookie; session data stored server-side in SQLite)
- Serves static files from `static/` with gzip compression
- Serves HTMX from an embedded, gzipped copy (no CDN dependency)
- Renders templates with auto-escaped output
- Handles CORS (denied by default)

### SQLite Database

A single SQLite database file stores everything:

- **Application tables** - Defined in the `schema do ... end` block in `app.do`
- **Session store** - Auto-managed table for server-side session data (separate from user schema)
- **Job queue** - Table tracking background jobs (`id`, `job_type`, `payload`, `status`, `run_at`, `attempts`, `locked_at`)
- **Migration history** - Tracks which migrations have been applied

SQLite's single-writer nature is treated as a feature: it eliminates race conditions in the job queue without advisory locks or distributed coordination.

### Job Worker Pool

An in-process pool of async workers (default: 2-4) that:

- Polls the job queue table for pending work
- Executes jobs within the same process (no separate worker binary)
- Handles retry logic for failed jobs (minimal: retry count, surface failures in dashboard)
- Runs the scheduler loop (inserts scheduled jobs into the queue at configured intervals)

### Session Store

- Signed session-ID cookie sent to the browser
- Actual session data stored server-side in a dedicated SQLite table
- Consistent with Rule 2 (SQLite only, no external store like Redis)
- Avoids cookie-size limits
- Auto-managed: no user configuration required

### Auth System

Fully built-in, not a library:

- Password hashing via argon2/bcrypt (handled internally, invisible to user)
- Session creation and validation
- `ctx.current_user` available in every handler
- Role-based access control at route/group level
- Optional email verification (uses the job system to send emails)

---

## Component Interaction

```
                    HTTP Request
                         │
                         ▼
                 ┌───────────────┐
                 │  HTTP Server  │
                 │  (routing)    │
                 └───────┬───────┘
                         │
              ┌──────────┼──────────┐
              │          │          │
              ▼          ▼          ▼
     ┌─────────────┐ ┌──────┐ ┌────────────┐
     │Auth Middleware│ │Static│ │Route Handler│
     │(session check)│ │Files │ │            │
     └──────┬──────┘ └──────┘ └─────┬──────┘
            │                        │
            ▼                        ├──────────────────┐
     ┌─────────────┐                │                  │
     │Session Store│                ▼                  ▼
     │  (SQLite)   │        ┌─────────────┐    ┌───────────┐
     └─────────────┘        │  db.<table> │    │  Template  │
                            │  (queries)  │    │  Render    │
                            └──────┬──────┘    └───────────┘
                                   │
                                   ▼
                            ┌─────────────┐
                            │   SQLite    │
                            │  Database   │
                            └─────────────┘
```

A typical request flows through:

1. **HTTP Server** receives the request and matches the route
2. **Auth middleware** checks the session cookie, loads session data from SQLite, populates `ctx.current_user`
3. If auth requirement is not met, returns 401/403 (deny by default)
4. **Route handler** executes the user-defined logic
5. Handler may query the database via `db.<table>.*` (auto-generated query interface)
6. Handler may enqueue a background job (INSERT into the job queue table)
7. Handler calls `render` with a template name and explicit local variables
8. **Template engine** resolves inheritance (extends/blocks), renders the template with auto-escaped output
9. HTTP response is sent to the client

### Error Handling

- `db.<table>.find(id)` returning nil triggers an automatic 404 response
- If `views/errors/404.do` exists, it is rendered; otherwise a default styled error page is shown
- Same pattern applies for 500 errors
- This removes boilerplate and matches the "remove decisions" philosophy: the correct behavior happens without explicit error-handling code

---

## Single Binary Architecture

The decision to combine CLI and production daemon into one binary is deliberate:

- **No version mismatch** between dev tooling and production runtime
- **No separate installation** for the production server
- **One update path** when upgrading Doot
- **No confusion** about which binary to use where

The binary detects its mode from the command-line arguments:

| Command | Mode | Purpose |
|---------|------|---------|
| `doot new <name>` | CLI | Scaffold a new project |
| `doot dev` | CLI | Local development server with file watching |
| `doot help` | CLI | Show available commands |
| `doot --prod` | Daemon | Start production mode (dashboard + app manager) |
| `doot --prod --reset-password` | Daemon | Recovery: reset dashboard password |

There is **no `doot build` command**. Building a deployable artifact is entirely a `dootd` responsibility: git push, dootd builds, dootd runs. This keeps deployment to a single path (Rule 3). Manual/local builds are out of scope because Doot is not a general-purpose "produce a binary" tool.

---

## Technology Choices

| Component | Technology | Rationale |
|-----------|-----------|-----------|
| Implementation language | Nim | C-level speed, Python-like readability, GC included, strong metaprogramming, good C FFI |
| Database | SQLite | Local-first, zero-config, sufficient for target use cases |
| HTTP | Nim HTTP libraries (mummy/jester) | Native, no external dependency |
| Password hashing | argon2/bcrypt via C FFI | Industry standard, bindings straightforward |
| Templates | Custom (Pug-style + Jinja inheritance) | Whitespace-significant, no closing tags, familiar patterns |
| Frontend interactivity | HTMX (embedded) | Declarative, no build step, shipped with the binary |
| Static asset serving | Built-in (gzip at serve time) | No bundler, no build pipeline, serve-as-is |
| Production process management | systemd integration | Standard Linux service management, survives reboots |

### Why Nim (and not alternatives)

- **Rust** - Rejected. Borrow checker fights the "compile and ship fast" workflow; no benefit for this use case.
- **Zig** - Rejected for v1. Pre-1.0, frequent breaking changes; not enough bandwidth to chase upstream churn.
- **D** - Close second. Mature, `vibe.d` is batteries-included for web. Rejected on ecosystem/community momentum and multiple-compiler fragmentation.
- **C** - Rejected. Would require hand-rolling a GC for the DSL runtime; too much foundational pain.
- **Nim (chosen)** - Compile-time metaprogramming, C-level speed, GC included (not fought), good C FFI for filling ecosystem gaps, standard library covers ~80% of needs out of the box.

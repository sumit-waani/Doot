# Implementation Plan

This document is the phased build plan for Doot v1. It is organized around dependency order: each phase unblocks the next, and nothing is scheduled before its prerequisites are complete. Every phase has concrete deliverables, exit criteria, and identified risks.

---

## Guiding Principles

1. **Build in dependency order.** Parser before codegen, schema before migrations, routes before auth, auth before jobs.
2. **Exit criteria are binary.** Each phase ends with a testable, demonstrable capability. No "mostly done."
3. **Nim is the target.** Every DSL construct compiles to Nim source, which compiles to a single native binary.
4. **SQLite is the only data store.** No Postgres, no Redis, no external services.
5. **One path.** Never introduce alternative approaches to the same problem, even during development.

---

## Phase 1: Parser Foundation

### Overview

The parser is the foundation of everything. Without a working parser, no other phase can produce output. This phase delivers a handwritten recursive-descent parser that reads `.do` source files and produces a well-typed AST.

### Key Deliverables

1. **Lexer/tokenizer** with whitespace sensitivity
   - Token types: keywords, HTTP methods, types (`:string`, `:text`, etc.), literals, operators, delimiters, identifiers, indentation tokens, newlines
   - Parse mode switching: route/schema mode (newline-significant, keyword-delimited blocks) vs. template mode (indentation-significant, Pug-style) vs. native block mode (raw pass-through until `end`)
   - String interpolation (`#{}`) handled at the lexer level
   - Position tracking: every token carries file, line, and column

2. **AST node type definitions**
   - Application-level: `AppNode`, `ConfigNode`, `SchemaNode`, `TableNode`, `FieldNode`, `AuthNode`, `MountNode`
   - Route/handler: `RouteNode`, `GroupNode`, `HandlerBodyNode`, `RenderNode`, `RedirectNode`, `DbQueryNode`, `AssignmentNode`, `IfNode`, `EachNode`, `NativeBlockNode`
   - Template: `TemplateNode`, `ExtendsNode`, `BlockDefNode`, `ElementNode`, `ExpressionOutputNode`, `TextNode`, `PartialNode`, `TemplateIfNode`, `TemplateEachNode`
   - Expression: `StringLiteralNode`, `IntegerLiteralNode`, `BooleanLiteralNode`, `NilNode`, `IdentifierNode`, `MemberAccessNode`, `MethodCallNode`, `IndexAccessNode`, `BinaryOpNode`, `UnaryOpNode`, `ArrayLiteralNode`

3. **Recursive-descent parser**
   - One function per grammar rule
   - Handles: `schema do ... end`, `table`, `field`, `config`, `mount`, `route`, `group`, `do |ctx| ... end`, `native do ... end`
   - Handles template constructs: `extends`, `block`, `partial`, `each`, `if/else`, element shorthand (`div.class#id`)
   - Expression parsing with correct operator precedence

4. **Error reporting with line/column info**
   - Consistent format: `Error in <file>, line <n>, column <c>:`
   - Error recovery: skip to next recognizable construct, continue parsing to report multiple errors in one pass
   - Actionable suggestions where possible (e.g., "did you mean 'route'?")
   - Valid types list on type errors, valid keywords list on keyword errors

5. **Multi-file resolution**
   - Parse `app.do` as entry point
   - Follow `mount "posts"` to parse `posts.do`
   - Resolve `views/` directory for template files
   - Produce a unified AST representing the entire application

### Dependencies

- None. This is the first phase.

### Estimated Complexity

**High.** This is the most technically demanding phase. The parser must handle three distinct syntactic modes (route/schema, template, native), whitespace sensitivity in templates, string interpolation, and multi-file resolution. Error recovery adds significant complexity.

Estimated effort: 4-6 weeks for a single developer familiar with parser implementation.

### Exit Criteria

- Can tokenize a complete `app.do` file with schema, config, and mount directives
- Can tokenize and parse feature files (`posts.do`) with routes, groups, handler bodies, and db queries
- Can tokenize and parse template files with indentation-based nesting, extends, blocks, partials, and control flow
- Can handle `native do ... end` blocks (raw content pass-through)
- Produces a complete, well-typed AST from a multi-file project (app.do + feature files + views)
- Reports meaningful errors with file, line, column, and suggestions
- Reports multiple errors in a single parse attempt

### Risks and Notes

- **Template indentation parsing is subtle.** Mixed tabs/spaces, inconsistent indentation levels, and empty lines all need careful handling. Decide early: tabs vs. spaces (recommend: spaces only, 2-space indent, reject tabs with a clear error).
- **Grammar ambiguity.** The DSL has some potential ambiguities (e.g., `field "name", :string` vs. method calls). These must be resolved by context or lookahead. Document every disambiguation rule.
- **Native block termination.** The `end` keyword inside a native block must not terminate the block prematurely. Track indentation level or require `end` at the same indentation as `native do`.

---

## Phase 2: Schema and Database

### Overview

This phase transforms schema declarations in `app.do` into working SQLite tables and generates the query interface (`db.<table>.*`). It also implements the migration diffing engine that detects schema changes and produces SQL migration files.

### Key Deliverables

1. **Schema AST to SQLite DDL**
   - `CREATE TABLE` generation from `TableNode`
   - Field type mapping: `:string` -> `TEXT`, `:text` -> `TEXT`, `:integer` -> `INTEGER`, `:boolean` -> `INTEGER` (0/1), `:float` -> `REAL`, `:datetime` -> `TEXT` (ISO 8601)
   - Constraint mapping: `required: true` -> `NOT NULL`, `max: 200` -> check constraint or application-level validation
   - `timestamps` -> `created_at TEXT NOT NULL DEFAULT (datetime('now')), updated_at TEXT NOT NULL DEFAULT (datetime('now'))`
   - Auto-generated `id INTEGER PRIMARY KEY AUTOINCREMENT`

2. **Query interface code generation**
   - For each `table "X"` in the schema, generate Nim code implementing:
     - `db.X.create(field1: val, field2: val)` - INSERT with validation, returns Result object
     - `db.X.find(id)` - SELECT by primary key, returns record or nil
     - `db.X.find_by(field: val)` - SELECT by arbitrary field, returns first match or nil
     - `db.X.all(where: ..., order: ..., limit: ...)` - SELECT with optional filtering/ordering
     - `db.X.update(record, field1: val)` - UPDATE with validation, returns Result object
     - `db.X.delete(record)` - DELETE by primary key
   - All queries use parameterized SQL (no string concatenation of user input)

3. **Result object pattern**
   - Every mutating operation returns a result: `result.ok?`, `result.errors`, `result.record` (or `result.<table_singular>`)
   - Validation errors are collected (not thrown as exceptions)
   - Explicit branching over exceptions: more predictable for agents

4. **Row type generation**
   - For each table, generate a Nim object/type representing a row
   - Type-safe field access (e.g., `post.title` is a string, `post.id` is an int)
   - Nil-safe: `db.X.find(id)` returns `Option[X]` or equivalent

5. **Migration diffing engine**
   - Compare current schema declaration against last-known state (stored as a snapshot)
   - Detect: new tables, new columns, removed columns, type changes, renamed columns, removed tables
   - Categorize changes as additive (safe) or destructive (requires confirmation)

6. **Migration file generation**
   - Sequential numbering: `001_create_posts.sql`, `002_add_slug_to_posts.sql`
   - Stored in `migrations/` directory
   - Plain SQL content (human-readable, auditable)
   - `_migrations` tracking table (records which migrations have been applied)

7. **Migration runner**
   - On startup, check `_migrations` table
   - Apply any pending migrations in sequential order
   - Fail-fast if a migration errors (do not partially apply)

### Dependencies

- Phase 1 (Parser Foundation): Need the AST node types for schema declarations (`SchemaNode`, `TableNode`, `FieldNode`)

### Estimated Complexity

**Medium-high.** The query interface generation is repetitive but must be correct (parameterized queries, proper type mapping). The migration diffing engine is the most complex part: detecting renames vs. add+delete, handling type changes, and generating correct ALTER TABLE statements for SQLite (which has limited ALTER support).

Estimated effort: 3-4 weeks.

### Exit Criteria

- A `schema do table "posts" do ... end end` declaration in `app.do` produces a working SQLite table
- `db.posts.create(title: "Hello", body: "World")` inserts a row and returns a result with `ok? == true`
- `db.posts.find(1)` returns the record; `db.posts.find(999)` returns nil
- `db.posts.all(order: "created_at desc")` returns rows in the correct order
- `db.posts.update(post, title: "New Title")` updates the row
- `db.posts.delete(post)` removes the row
- Validation errors (e.g., missing required field) return `result.ok? == false` with `result.errors` populated
- Adding a new field to the schema generates a migration file (`ALTER TABLE ADD COLUMN`)
- Adding a new table generates a `CREATE TABLE` migration
- Destructive changes (drop column) are flagged for confirmation
- Migration files are numbered sequentially and stored in `migrations/`
- The migration runner applies pending migrations on startup

### Risks and Notes

- **SQLite ALTER TABLE limitations.** SQLite does not support `DROP COLUMN` (before 3.35.0), `ALTER COLUMN TYPE`, or adding constraints to existing columns. For destructive changes, the migration may need to: create a new table, copy data, drop the old table, rename. This is well-documented SQLite practice but adds complexity.
- **Schema snapshot storage.** The "last known state" for diffing needs to be stored somewhere. Options: a hidden `.doot/schema_snapshot.json` file in the project, or a dedicated SQLite table. The snapshot file is preferred (can be committed to git, visible, auditable).
- **Validation location.** Some validations (e.g., `max: 200`) are enforced at the application level in the generated Nim code, not as SQL constraints. This is intentional because SQLite's CHECK constraints are limited and error messages are poor.

---

## Phase 3: HTTP and Routing

### Overview

This phase implements the HTTP server: route registration from parsed route declarations, the `ctx` object construction, handler code generation, and static file serving. After this phase, `.do` files can define routes that serve HTTP responses backed by database queries.

### Key Deliverables

1. **Route registration**
   - Parse `route GET "/posts/:id" do |ctx| ... end` into route table entries
   - Path parameter extraction (`:id` -> `ctx.params["id"]`)
   - HTTP method matching (GET, POST, PUT, DELETE, PATCH)
   - Route ordering: static paths before parameterized paths, more specific before less specific
   - Mount file resolution: routes in `posts.do` are registered alongside routes in `app.do`

2. **`ctx` object construction**
   - `ctx.params` - URL path parameters (`:id`, `:slug`, etc.)
   - `ctx.form` - POST form data (key-value pairs)
   - `ctx.query` - Query string parameters
   - `ctx.headers` - Request headers
   - `ctx.file` - Uploaded file data
   - `ctx.session` - Session data (read/write to session store)
   - `ctx.current_user` - Populated by auth middleware (nil if not authenticated)
   - Generated as a Nim object with typed accessors

3. **Handler code generation**
   - Each handler body becomes a Nim function
   - Variable assignments, if/else branching, each loops
   - `db.<table>.*` calls within handlers generate the correct Nim code
   - `render "template/path", key: value` generates a template render call with explicit locals
   - `redirect "/path"` generates an HTTP redirect response
   - String interpolation in paths: `"/posts/#{result.post.id}"`

4. **Group blocks**
   - `group auth: required do ... end` applies auth requirement to all enclosed routes
   - `group auth: required, role: "admin" do ... end` adds role checking
   - Groups can nest (inner overrides outer for conflicting options)

5. **Response helpers**
   - `render "path", locals` - Render a template with explicit locals, return 200 HTML response
   - `redirect "/path"` - Return 302 redirect
   - `response(status, body, content_type)` - Explicit response construction (for APIs, JSON, etc.)

6. **Static file serving**
   - Serve files from `static/` directory
   - Gzip compression at serve time
   - Proper content-type headers based on file extension
   - Cache headers (configurable, sensible defaults)

7. **HTMX embedding**
   - HTMX library embedded in the binary (compiled in)
   - Served from a well-known path (e.g., `/__doot/htmx.min.js`)
   - Gzipped, proper cache headers
   - Templates can reference HTMX without any user configuration

8. **Error handling**
   - `db.<table>.find(id)` returning nil auto-triggers a 404 response
   - Custom error pages: if `views/errors/404.do` or `views/errors/500.do` exists, render it
   - Default styled error page if no custom error template exists
   - Unhandled exceptions in handlers produce a 500 response

9. **CORS enforcement**
   - Denied by default (secure by default, Rule 4)
   - Configurable in `app.do` config block if needed

### Dependencies

- Phase 1 (Parser): Route, group, and handler body AST nodes
- Phase 2 (Schema/Database): `db.<table>.*` query interface (handlers call database operations)

### Estimated Complexity

**Medium-high.** Route registration and path matching are well-understood problems. The complexity lies in handler code generation (translating DSL handler bodies into correct Nim), the ctx object (type-safe, covering all request data), and wiring everything together into a working HTTP server using Nim HTTP libraries (mummy or jester).

Estimated effort: 3-4 weeks.

### Exit Criteria

- Can define `route GET "/posts" do |ctx| ... end` in a `.do` file
- The compiled binary starts an HTTP server and responds to matching requests
- Path parameters (`/posts/:id`) are extracted and available as `ctx.params["id"]`
- `ctx.form`, `ctx.query`, `ctx.headers` are populated correctly
- `db.<table>.*` queries work inside handlers (full integration with Phase 2)
- `render "posts/index", posts: posts` renders the correct template (stub for now, full templates in Phase 4)
- `redirect "/posts"` returns a 302 response
- Static files from `static/` are served with correct content types and gzip
- HTMX is served from an embedded path
- `db.posts.find(id)` returning nil produces a 404 response
- Groups apply shared auth requirements to enclosed routes
- CORS is denied by default

### Risks and Notes

- **Nim HTTP library choice.** Mummy is newer and more performant; Jester is more mature. Pick one early and commit. Mummy is recommended for its async model and performance characteristics.
- **Handler codegen complexity.** Translating DSL handler bodies (with db calls, conditionals, render calls) into valid Nim requires careful scoping and variable lifetime management. Each handler should compile to a single Nim proc.
- **Template rendering stub.** Phase 3 needs `render` to work, but the full template engine is Phase 4. Implement a minimal stub (return the template path as HTML, or raw string rendering) so routes can be tested end-to-end before templates are complete.

---

## Phase 4: Templates

### Overview

This phase implements the template parser and renderer: Pug-style whitespace-significant syntax with Jinja-style inheritance (extends, named blocks, partials). After this phase, `render` calls in handlers produce fully rendered HTML with layout inheritance, auto-escaping, and control flow.

### Key Deliverables

1. **Template parser (separate parse mode)**
   - Indentation-based nesting (2 spaces = one level)
   - No closing tags: nesting determined entirely by indentation
   - Element parsing: tag name, class shorthand (`.class`), ID shorthand (`#id`), attributes
   - Text content: literal strings in quotes, or bare text after element declarations

2. **Expression output**
   - `=` prefix for expression output: `h1= post.title` (auto-escaped)
   - `!=` prefix for raw/unescaped output: `div!= post.html_body`
   - Auto-escaping by default (HTML entity encoding for `<`, `>`, `&`, `"`, `'`)
   - Interpolation in strings: `"Hello #{user.name}"`

3. **Inheritance system**
   - `extends "layouts/base"` at the top of a template
   - Multiple named blocks: `block title`, `block content`, `block head`, etc.
   - Default block values: `title= block title || "Doot App"`
   - Block override: child template defines `block content` to replace the parent's
   - Deep inheritance chains (child extends parent extends grandparent)

4. **Partials**
   - `partial "path/to/partial", key: value` renders another template file inline
   - Locals passed explicitly (no implicit scope leakage)
   - Recursive partial support (a partial can include other partials)

5. **Control flow**
   - `each post in posts` with indented body
   - `if condition` / `else` with indented bodies
   - `if collection.empty?` for empty-state handling
   - No complex expressions in control flow (keep it simple: truthiness check, method calls)

6. **Class/ID shorthand and attributes**
   - `div.post-card` -> `<div class="post-card">`
   - `input#email` -> `<input id="email">`
   - `div.card.highlighted` -> `<div class="card highlighted">`
   - Attributes: `a href="/posts" "All Posts"` -> `<a href="/posts">All Posts</a>`
   - HTMX attributes as plain attributes: `button hx-post="/vote" hx-target="#count" "Vote"`

7. **HTMX delivery**
   - HTMX script tag automatically injected in layouts (or available via a helper)
   - Served from embedded binary path (gzipped)
   - No CDN dependency, no version management for the user

8. **`style-embed` directive**
   - `style-embed "app.css"` inlines the CSS file content into a `<style>` tag
   - Reads from `static/` directory
   - Avoids a separate CSS request for simple apps

### Dependencies

- Phase 1 (Parser): Template AST node types, template parse mode in the tokenizer
- Phase 3 (HTTP/Routing): `render` call integration (templates are invoked from route handlers)

### Estimated Complexity

**Medium-high.** The Pug-style indentation parser is tricky (especially mixed content, multiline attributes, and edge cases around empty lines). Inheritance resolution with multiple named blocks and defaults adds complexity. Auto-escaping must be correct everywhere (security-critical).

Estimated effort: 3-4 weeks.

### Exit Criteria

- `div.post-card` renders as `<div class="post-card"></div>`
- `h1= post.title` renders the title with HTML entities escaped
- `!= raw_html` renders without escaping
- `extends "layouts/base"` correctly wraps content in the layout
- Multiple named blocks (`block title`, `block content`, `block head`) all resolve correctly
- Default block values work: `block title || "Doot App"` uses default when child does not override
- `partial "partials/comment_form", post: post` renders the partial with passed locals
- `each post in posts` iterates and renders body for each item
- `if posts.empty?` / `else` conditional rendering works
- `style-embed "app.css"` inlines CSS
- HTMX is available without any user configuration
- End-to-end: a route handler calling `render "posts/index", posts: posts` produces complete, correctly escaped HTML with layout inheritance

### Risks and Notes

- **Indentation edge cases.** Blank lines, trailing whitespace, and inconsistent indentation within a file are common user errors. The parser needs clear rules and clear error messages (e.g., "expected 2-space indent, got 3 spaces on line 14").
- **Expression complexity in templates.** Templates should support simple expressions (member access, method calls, comparisons) but not arbitrary computation. Define the boundary early: what expressions are valid in `=` output vs. what requires moving logic to the handler.
- **Security: auto-escaping.** The auto-escaping must be applied consistently. Every `=` output path must go through the escaper. The `!=` path should be rare and documented as "you are responsible for safety here."

---

## Phase 5: Auth and Sessions

### Overview

This phase implements the built-in authentication system: sessions backed by SQLite, password hashing, built-in signup/login/logout routes, and the default-deny enforcement model. After this phase, routes are secured by default and user authentication works without any user-written auth code.

### Key Deliverables

1. **Session store**
   - Auto-managed SQLite table for session data (`session_id`, `user_id`, `data`, `expires_at`, `created_at`)
   - Signed session-ID cookie (HMAC with session_secret from `.env`)
   - Server-side session data (avoids cookie-size limits)
   - Session creation on login, destruction on logout
   - Session expiry (configurable, sensible default like 2 weeks)
   - Session cleanup (periodic removal of expired sessions)

2. **`auth` schema block parsing and codegen**
   - Parse `auth :users do roles [...] email_verification true/false end`
   - Generate user table schema: `id`, `email`, `password_hash`, `role`, `email_verified`, `created_at`, `updated_at`
   - Generate session table schema (auto-managed, not user-visible)
   - Generate auth-related Nim code (handlers, middleware)

3. **Built-in routes**
   - `POST /signup` - Create user, hash password, create session, redirect
   - `POST /login` - Verify credentials, create session, redirect
   - `POST /logout` - Destroy session, redirect
   - These routes exist automatically when `auth` is declared; no user code needed
   - Overridable: user can define custom handlers for these paths if they need custom logic

4. **Password hashing**
   - argon2 or bcrypt via Nim's C FFI (bind to the C library)
   - Hash on signup, verify on login
   - Invisible to the user: they never see or interact with password hashes
   - Timing-safe comparison for password verification

5. **`ctx.current_user` population**
   - Auth middleware runs before every handler
   - Reads session cookie, loads session from SQLite, loads user record
   - Populates `ctx.current_user` (nil if not authenticated or session invalid)
   - Available in every handler and template

6. **Default-deny enforcement**
   - `auth: required` is the implicit default for all routes
   - Routes must explicitly declare `auth: public` to be accessible without login
   - If a route has no auth annotation and is not in a group, it requires authentication
   - Unauthenticated access to a required route returns 401 or redirects to login

7. **Role checking**
   - At route level: `route GET "/admin", auth: required, role: "admin" do |ctx| ... end`
   - At group level: `group auth: required, role: "admin" do ... end`
   - Insufficient role returns 403
   - Roles are simple strings compared against `ctx.current_user.role`

8. **Email verification (optional)**
   - When `email_verification: true` is set in the auth block
   - On signup: user is created but marked unverified, verification email is enqueued as a job
   - Verification link with signed token
   - `ctx.current_user.email_verified?` available for checking
   - Depends on the jobs system (Phase 6) for sending the email

### Dependencies

- Phase 2 (Schema/Database): User table, session table, query interface
- Phase 3 (HTTP/Routing): Route middleware, ctx object, request handling
- Phase 6 (Jobs): Email verification depends on the job queue (can be deferred within this phase)

### Estimated Complexity

**Medium.** Auth is well-understood territory. The complexity is in getting the security details right (timing-safe comparisons, proper hashing, secure cookie signing) and in the default-deny enforcement (must be applied consistently, no route can accidentally bypass it).

Estimated effort: 2-3 weeks.

### Exit Criteria

- Declaring `auth :users` in `app.do` creates a users table and session table
- `POST /signup` with email and password creates a user with a hashed password
- `POST /login` with valid credentials creates a session and sets a signed cookie
- `POST /logout` destroys the session
- `ctx.current_user` is populated in handlers when the user is logged in
- A route without explicit `auth: public` is inaccessible without authentication (returns 401 or redirects)
- A route with `auth: public` is accessible without login
- A route with `role: "admin"` returns 403 for users without the admin role
- Session cookies are signed (tampering is detected and session is rejected)
- Passwords are hashed with argon2 or bcrypt (never stored in plaintext)

### Risks and Notes

- **C FFI for password hashing.** Binding to argon2 or bcrypt requires compiling a C library and linking it. Verify this works on the target platforms (Linux primarily for dootd, macOS for dev). Nim's C FFI makes this straightforward but requires the C library to be available at compile time.
- **Session secret rotation.** If the session_secret in `.env` changes, all existing sessions are invalidated. This is acceptable behavior but should be documented.
- **Email verification deferral.** Email verification depends on jobs (Phase 6). Implement it as a stub in Phase 5 (mark user as unverified, skip email sending) and complete it after Phase 6.

---

## Phase 6: Jobs and Scheduler

### Overview

This phase implements the background job system: a SQLite-backed queue, an in-process worker pool, job declaration/dispatch, and a cron-style scheduler. After this phase, apps can enqueue background work and run scheduled tasks without any external services.

### Key Deliverables

1. **Job queue SQLite table**
   - Schema: `id`, `job_type` (string), `payload` (JSON text), `status` (pending/running/completed/failed), `run_at` (datetime), `attempts` (integer), `locked_at` (datetime), `created_at`
   - Auto-created (not user-visible in schema, managed internally like sessions)
   - Indexes on `status` and `run_at` for efficient polling

2. **Worker pool**
   - In-process async workers (no separate process to manage)
   - Configurable pool size (default: 2-4 workers)
   - Polling loop: check for pending jobs where `run_at <= now` and `status = 'pending'`
   - Lock-before-execute pattern: set `locked_at` and `status = 'running'` before executing
   - SQLite single-writer eliminates race conditions (no advisory locks needed)

3. **Job declaration and dispatch**
   - Parse: `job "send_email" do |payload| ... end`
   - `payload` is a key-value object (JSON-serialized in the queue table)
   - Job body becomes a Nim function that receives the deserialized payload
   - Dispatch: `enqueue "send_email", to: email, subject: "Welcome"`
   - Dispatch is an INSERT into the job queue table

4. **Scheduler**
   - Parse: `schedule "cleanup", every: "1 hour" do ... end`
   - Internally: a loop that inserts the scheduled job into the queue at the configured interval
   - Interval parsing: `"30 seconds"`, `"5 minutes"`, `"1 hour"`, `"1 day"`
   - Runs within the same process (no separate cron service)

5. **Retry logic**
   - On failure: increment `attempts`, set `status = 'failed'` (or `'pending'` for retry)
   - Configurable max attempts (default: 3)
   - Failed jobs visible in the dootd dashboard with a retry button
   - No complex backoff in v1 (fixed retry, immediate or short delay)

6. **Status tracking**
   - Job lifecycle: pending -> running -> completed/failed
   - `locked_at` for detecting stuck jobs (timeout-based recovery)
   - Dashboard can display job history (completed count, failed count, pending count)

### Dependencies

- Phase 2 (Schema/Database): SQLite table creation, query patterns
- Phase 3 (HTTP/Routing): Jobs are enqueued from route handlers

### Estimated Complexity

**Medium.** The job queue pattern over SQLite is well-understood. The main complexity is in the async worker pool (correct shutdown, stuck-job detection) and in integrating the scheduler loop with the HTTP server event loop without blocking.

Estimated effort: 2-3 weeks.

### Exit Criteria

- Can declare `job "send_email" do |payload| ... end` in a `.do` file
- `enqueue "send_email", to: "user@example.com"` inserts a row into the job queue
- Worker picks up the job and executes the handler function
- `schedule "cleanup", every: "1 hour" do ... end` inserts jobs on schedule
- Failed jobs have `status = 'failed'` and `attempts` incremented
- Retry (re-enqueue) works from the dashboard or programmatically
- Worker pool starts automatically with the application (no separate process)
- Pool size is configurable
- Stuck job detection: if `locked_at` exceeds a timeout, the job is unlocked for retry

### Risks and Notes

- **Async integration.** The worker pool must coexist with the HTTP server's async event loop. In Nim with mummy/jester, this means using async primitives (not OS threads) for the worker poll loop. Verify that SQLite writes from workers do not block HTTP request handling.
- **Scheduler precision.** The scheduler does not need millisecond precision. A poll-based approach (check every 10-30 seconds) is sufficient and much simpler than timer-based scheduling.
- **Job serialization.** Payloads are JSON. Ensure that all DSL types (strings, integers, booleans, arrays) serialize cleanly to JSON and deserialize back to the correct types in the job handler.

---

## Phase 7: CLI

### Overview

This phase implements the developer-facing CLI commands: `doot new` for project scaffolding, `doot dev` for the development server with file watching and automatic recompilation, and `doot help`. After this phase, a developer can create a new project and iterate on it locally.

### Key Deliverables

1. **`doot new <name>` scaffolding**
   - Creates project directory with:
     - `app.do` (minimal schema + config scaffold)
     - `views/layouts/base.do` (base layout template)
     - `static/` directory (empty, for CSS/images)
     - `.env` file (with generated session_secret placeholder)
     - `.gitignore` (ignoring `.env`, `.doot-build/`, SQLite database file)
   - Validates project name (alphanumeric + hyphens, no spaces)
   - Prints next-steps instructions after scaffolding

2. **`doot dev` development server**
   - File watcher monitoring all `.do` files and `static/` directory
   - On any change: full recompile (parse, codegen, Nim compile) and restart
   - Schema diff detection: if `app.do` schema changed, generate migration and apply
   - Destructive migration confirmation in terminal
   - Clear error output on parse/compile failure (do not crash the watcher, show errors and wait for next change)
   - Print server URL and port on successful start
   - Graceful shutdown on Ctrl+C

3. **`doot help`**
   - List available commands with brief descriptions
   - Usage examples

4. **Incremental compilation (Nim's cache)**
   - Nim's built-in incremental compilation cache speeds up rebuilds
   - Transparent to the user (they just see "fast restarts")
   - Build artifacts stored in `.doot-build/` (gitignored)

5. **Error output in dev mode**
   - Parse errors: show file, line, column, suggestion (from Phase 1 error reporting)
   - Nim compile errors (from native blocks): show the Nim error with context
   - Runtime errors: show stack trace with mapping back to `.do` file locations where possible
   - Clear terminal formatting: colors, alignment, readable at a glance

### Dependencies

- Phase 1 (Parser): Parsing pipeline
- Phase 2 (Schema/Database): Migration generation on schema change
- Phase 3 (HTTP/Routing): Running the compiled application
- Phase 4 (Templates): Template rendering in the running app
- Phase 5 (Auth): Auth system active in the running app
- Phase 6 (Jobs): Job system active in the running app

Note: The CLI can be partially built earlier (file watcher + recompile loop) and gains features as other phases complete. However, it is listed here because its "complete" form depends on all prior phases.

### Estimated Complexity

**Medium.** File watching and process management are well-understood. The schema diff integration adds some complexity. The main challenge is making the error output genuinely helpful (clear, actionable, not overwhelming).

Estimated effort: 2-3 weeks.

### Exit Criteria

- `doot new myapp` creates a valid project directory with all scaffolded files
- `doot dev` starts a file watcher, compiles the project, and starts the HTTP server
- Editing a `.do` file triggers recompilation and server restart
- Schema changes in `app.do` auto-generate a migration file in `migrations/`
- Parse errors display clearly with file, line, column, and suggestion
- Compile errors from native blocks display the Nim error
- `doot help` shows available commands
- Ctrl+C gracefully stops the dev server
- Rebuild times are fast due to Nim's incremental compilation cache

### Risks and Notes

- **File watcher cross-platform.** On Linux, `inotify` is standard. On macOS, `kqueue`/`FSEvents`. Nim has libraries for both (e.g., `watchdog` or OS-specific bindings). Ensure the chosen approach works on both development platforms.
- **Process restart race conditions.** The file watcher may fire multiple events for a single save (editor writes temp file, then renames). Debounce changes (e.g., 100-200ms delay after last change before triggering recompile).
- **Dev vs. prod compilation flags.** Dev mode uses debug symbols and fast compilation. Ensure these flags are wired correctly and do not leak into production builds.

---

## Phase 8: dootd (Production Daemon)

### Overview

This phase implements production mode: `doot --prod` transforms the binary into a production daemon with a web dashboard for managing deployed applications. This is the final phase because it depends on the entire compilation pipeline (it builds apps) and all runtime features (it runs them).

### Key Deliverables

1. **`doot --prod` mode switch**
   - Same binary, different mode based on `--prod` flag
   - First run: generates admin password (shown once), registers as systemd service, starts dashboard
   - Subsequent runs: reports status, does not re-initialize
   - `--reset-password` flag for password recovery

2. **Dashboard web UI**
   - Simple, functional web interface (not a SPA: server-rendered, minimal JS)
   - **App list** - Shows all managed applications with status (running/stopped/error)
   - **App create** - GitHub URL, PAT (personal access token), branch, env vars
   - **Deploy** - Trigger pull + build + restart for an app
   - **Logs** - View stdout/stderr from each managed app (tail, with basic search)
   - **Stats** - Basic server metrics (CPU, memory, disk, per-app)
   - **Settings** - Change dashboard password, configure global settings

3. **GitHub integration**
   - Clone/pull from configured GitHub repo using PAT
   - Branch selection (default: main)
   - Deploy = `git pull` + compile + restart
   - No webhook support in v1 (manual deploy trigger from dashboard)

4. **Env var validation**
   - Before building/deploying, check that all env vars referenced in the app's `.do` files are configured in the dashboard
   - Fail-fast with a clear error listing missing vars
   - Never start an app with missing configuration

5. **Child process management**
   - Each deployed app runs as a supervised child process
   - Assigned an internal port (3001, 3002, etc.)
   - Supervised restart on crash (with backoff to avoid restart loops)
   - Graceful shutdown on redeploy (send signal, wait, force-kill if needed)

6. **Host-header routing**
   - dootd listens on port 80
   - Routes incoming requests to the correct child app based on the `Host` header
   - Dashboard accessible on a separate port (8080) or a configured hostname
   - Returns 404/503 for unknown hosts

7. **cgroups-based isolation**
   - Each app process runs in its own cgroup
   - Memory and CPU limits configurable per app from the dashboard
   - Prevents one app from consuming all server resources
   - Linux-specific (acceptable: production target is always Linux VPS)

8. **systemd service registration**
   - On first `doot --prod` run, registers itself as a systemd service (`dootd.service`)
   - Survives SSH disconnect and VPS reboot
   - Managed via standard systemd commands (though users should not need to use them directly)
   - `WantedBy=multi-user.target` for auto-start on boot

9. **Password generation**
   - Auto-generated on first run, shown once in terminal output
   - Cryptographically random, sufficient entropy
   - Stored hashed (same argon2/bcrypt from Phase 5)
   - Changeable from dashboard settings
   - `--reset-password` generates a new one if locked out

10. **Idempotent re-runs**
    - Running `doot --prod` when already configured does not wipe state
    - Reports current status: dashboard URL, service status
    - Offers explicit recovery path (`--reset-password`)
    - Never touches existing SQLite databases or app data

### Dependencies

- All prior phases (1-7): dootd builds and runs complete Doot applications
- Phase 5 (Auth): Password hashing for the dashboard admin account
- Phase 6 (Jobs): Dashboard may use internal job queue for build tasks

### Estimated Complexity

**High.** This phase combines web dashboard development, process supervision, Linux-specific systems programming (cgroups, systemd), and the deployment pipeline. The dashboard itself is a significant piece of work (multiple pages, state management, real-time log streaming).

Estimated effort: 4-6 weeks.

### Exit Criteria

- `doot --prod` on a fresh server: generates password, registers systemd service, starts dashboard on port 8080
- Can create an app in the dashboard with a GitHub URL and PAT
- Clicking "Deploy" pulls the repo, compiles it, and starts it as a child process
- The app is accessible via its configured hostname (host-header routing on port 80)
- Logs are viewable in the dashboard (stdout/stderr from the app process)
- Basic stats (memory, CPU) are visible per app
- Missing env vars are caught before deploy with a clear error
- App crash triggers supervised restart (with backoff)
- cgroups limit memory/CPU per app
- Re-running `doot --prod` does not re-initialize or wipe existing state
- `doot --prod --reset-password` generates a new password
- Service survives VPS reboot (systemd auto-start)

### Risks and Notes

- **Dashboard scope creep.** The dashboard must be functional but minimal. Resist adding features beyond the core: app CRUD, deploy, logs, stats, settings. Advanced features (webhooks, auto-deploy on push, zero-downtime deploys) are deferred.
- **cgroups version.** cgroups v2 is now standard on modern Linux. Target cgroups v2 only. If the VPS uses cgroups v1, document it as unsupported.
- **Port conflicts.** Port 80 requires root or `CAP_NET_BIND_SERVICE`. The systemd service can handle this, but document the requirement clearly.
- **Build isolation.** When dootd builds an app (runs Nim compile), it should do so in a confined directory. A malicious or buggy `native do` block in a deployed app could execute arbitrary code at build time. This is an accepted trade-off for v1 (the VPS owner controls what is deployed), but document it.
- **HTTPS deferral.** The dashboard runs on plain HTTP in v1. This is explicitly deferred. Document that putting the VPS behind a CDN/proxy (like Cloudflare's free tier with proxied DNS) is the interim solution for HTTPS, but do not expose reverse proxy configuration to the user.

---

## Phase Summary

| Phase | Name | Depends On | Effort | Key Risk |
|-------|------|-----------|--------|----------|
| 1 | Parser Foundation | None | 4-6 weeks | Template indentation edge cases |
| 2 | Schema and Database | Phase 1 | 3-4 weeks | SQLite ALTER TABLE limitations |
| 3 | HTTP and Routing | Phases 1, 2 | 3-4 weeks | Handler codegen complexity |
| 4 | Templates | Phases 1, 3 | 3-4 weeks | Indentation parser edge cases |
| 5 | Auth and Sessions | Phases 2, 3 | 2-3 weeks | C FFI for password hashing |
| 6 | Jobs and Scheduler | Phases 2, 3 | 2-3 weeks | Async integration with HTTP server |
| 7 | CLI | Phases 1-6 | 2-3 weeks | Cross-platform file watching |
| 8 | dootd (Production) | Phases 1-7 | 4-6 weeks | Dashboard scope, Linux-specific systems |

**Total estimated effort: 23-33 weeks** for a single developer. Phases 4, 5, and 6 can be partially parallelized (they share dependencies on Phases 1-3 but are independent of each other), which could compress the timeline with multiple developers.

---

## Dependency Graph

```
Phase 1: Parser Foundation
    │
    ├───────────────────────────────────┐
    │                                   │
    ▼                                   ▼
Phase 2: Schema & Database         Phase 4: Templates (needs Phase 3 for render integration)
    │                                   │
    ├───────────────┐                   │
    │               │                   │
    ▼               ▼                   │
Phase 3: HTTP & Routing                 │
    │               │                   │
    │               ├───────────────────┘
    │               │
    ├───────┐       ├───────┐
    │       │       │       │
    ▼       ▼       ▼       │
Phase 5  Phase 6    │       │
(Auth)   (Jobs)     │       │
    │       │       │       │
    └───────┼───────┘       │
            │               │
            ▼               │
      Phase 7: CLI ◀────────┘
            │
            ▼
      Phase 8: dootd
```

---

## Cross-Cutting Concerns

These concerns span multiple phases and should be addressed continuously rather than in a single phase:

### Testing Strategy

- **Parser tests:** Unit tests for each grammar rule (input string -> expected AST node). High coverage here prevents cascading failures.
- **Codegen tests:** For each AST node type, verify the generated Nim code is valid and produces the expected behavior.
- **Integration tests:** End-to-end tests that parse a `.do` file, generate Nim, compile, start the server, and verify HTTP responses.
- **Migration tests:** Verify that schema changes produce correct SQL and that migrations apply cleanly.

### Error Message Quality

Every phase must maintain error message quality. Errors should always include:
- File, line, column
- What was expected vs. what was found
- A suggestion when possible
- No Nim internals leaking through (the user does not know or care about Nim)

### Security Hardening

Security is not a separate phase; it is woven into each phase:
- Phase 2: Parameterized queries (no SQL injection)
- Phase 3: CORS denied by default, proper header handling
- Phase 4: Auto-escaping (no XSS)
- Phase 5: Proper password hashing, signed cookies, default-deny
- Phase 8: Env var validation, process isolation

### Documentation

Each phase should produce:
- Internal architecture docs (for contributors)
- User-facing docs (for the eventual Doot documentation site)
- Error message catalog (all possible errors, their causes, and fixes)

---

## Decision Log

Decisions made during planning that should be respected during implementation:

| Decision | Rationale | Phase |
|----------|-----------|-------|
| Handwritten parser, not Nim macros | Error quality, LSP future, full control | 1 |
| Spaces only, no tabs in templates | Eliminates ambiguity, simpler parser | 1 |
| Validation at application level, not SQL constraints | Better error messages, SQLite constraint limitations | 2 |
| Schema snapshot as file, not DB table | Auditable, committable to git | 2 |
| Mummy over Jester for HTTP | Better async model, more performant | 3 |
| Template stub in Phase 3, full in Phase 4 | Unblocks route testing before templates are complete | 3, 4 |
| argon2 preferred over bcrypt | More modern, better resistance to GPU attacks | 5 |
| Email verification deferred to after Phase 6 | Depends on job queue for sending emails | 5, 6 |
| Poll-based scheduler, not timer-based | Simpler, sufficient precision for target use cases | 6 |
| Debounced file watcher (100-200ms) | Prevents multiple rapid recompiles on single save | 7 |
| cgroups v2 only | Modern standard, simpler API, v1 is legacy | 8 |
| Dashboard is server-rendered, not SPA | Simpler, no JS build pipeline, dogfoods the template system | 8 |
| HTTPS deferred to post-v1 | Avoids reverse proxy complexity, users can use Cloudflare | 8 |

---

## Getting Started

To begin implementation:

1. **Set up the Nim development environment.** Install Nim (stable release), verify `nim c` works, set up nimble for dependency management.
2. **Create the project structure.** `src/` for the Doot compiler/runtime source, `tests/` for test files, `examples/` for sample `.do` projects used in testing.
3. **Start with Phase 1.** Write the tokenizer first (it has no dependencies), then the AST type definitions, then the recursive-descent parser. Test extensively with example `.do` files.
4. **Build example projects.** Maintain a set of example `.do` projects (simple blog, todo app) that grow in complexity as phases complete. These serve as both integration tests and documentation.
5. **One phase at a time.** Do not start Phase N+1 until Phase N meets its exit criteria. The dependency order exists for a reason.

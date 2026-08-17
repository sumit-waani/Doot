# Compiler Pipeline

This document describes how Doot transforms `.do` source files into a running native binary. The pipeline is a handwritten recursive-descent parser that produces an AST, which is then used to generate Nim source code, which is compiled into a single native binary.

---

## Pipeline Overview

```
  .do source files        Tokens          AST            Nim source       Native binary
 ┌───────────────┐    ┌──────────┐    ┌──────────┐    ┌───────────┐    ┌────────────┐
 │ app.do        │    │          │    │          │    │           │    │            │
 │ posts.do      │───▶│ Tokenizer│───▶│  Parser  │───▶│  Codegen  │───▶│ Nim Compile│───▶ ./app
 │ views/*.do    │    │          │    │  (RD)    │    │  (.nim)   │    │ (native)   │
 │ jobs.do       │    │          │    │          │    │           │    │            │
 └───────────────┘    └──────────┘    └──────────┘    └───────────┘    └────────────┘
```

Each stage has a clear responsibility:

1. **Tokenization** - Raw text becomes a stream of typed tokens
2. **Parsing** - Tokens become a structured AST (Abstract Syntax Tree)
3. **Nim code generation** - AST becomes valid Nim source code
4. **Nim compilation** - Nim source becomes a native binary

---

## Why a Handwritten Parser

Doot uses a handwritten recursive-descent parser rather than Nim's built-in macro system. This is a deliberate decision with significant trade-offs.

### Why not Nim macros?

Nim's compile-time macro system is powerful and would allow embedding a DSL directly into Nim source. However, this approach was rejected for several reasons:

**Custom whitespace-significant syntax.** Doot's template language (Pug-style indentation-based nesting) and its route/schema syntax use whitespace in ways that do not map cleanly to Nim's grammar. Trying to fit `extends`, `block`, indentation-based nesting, and Pug-style shorthand into Nim's parser would require fighting the host language at every turn.

**Error messages for humans and agents.** Nim macro errors produce messages in terms of Nim's AST and type system. When a non-technical user (or an AI agent) writes a malformed `.do` file, the error needs to say "line 14 in posts.do: expected a route handler, got 'rout GET'" with a suggestion like "did you mean 'route'?" Nim's macro errors would say something about `untyped` or `NimNode` mismatch, which is meaningless to the target audience.

**Future LSP tooling.** A handwritten parser produces an AST that can power a Language Server Protocol implementation: autocomplete, hover info, go-to-definition, and real-time diagnostics. Nim macros operate at compile time and do not expose the incremental, position-aware analysis that an LSP needs.

**Full control over the parsing pipeline.** With a handwritten parser, every aspect of the error recovery, token classification, and syntax extension is under Doot's control. There is no upstream Nim parser update that can break the DSL's behavior.

### The accepted trade-off

A handwritten parser is significantly more work to bootstrap than a macro-based approach. It requires implementing tokenization, recursive-descent parsing, error recovery, and AST construction from scratch. This is accepted because the long-term benefits (error quality, LSP support, full control) outweigh the initial development cost.

---

## Stage 1: Tokenization

The tokenizer reads raw `.do` file text and produces a stream of typed tokens. Tokenization is context-aware because Doot has multiple syntactic modes.

### Token Types

The tokenizer produces tokens including (not exhaustive):

| Category | Examples |
|----------|----------|
| Keywords | `route`, `schema`, `table`, `field`, `group`, `do`, `end`, `if`, `else`, `each`, `in`, `config`, `mount`, `native`, `render`, `redirect`, `job`, `schedule`, `auth`, `extends`, `block`, `partial` |
| HTTP methods | `GET`, `POST`, `PUT`, `DELETE`, `PATCH` |
| Types | `:string`, `:text`, `:integer`, `:boolean`, `:float`, `:datetime` |
| Literals | String (`"..."`), Integer (`42`), Boolean (`true`/`false`), Nil (`nil`) |
| Operators | `=`, `==`, `!=`, `>`, `<`, `>=`, `<=`, `&&`, `||`, `!` |
| Delimiters | `(`, `)`, `[`, `]`, `,`, `:`, `|`, `#{}` (interpolation start/end) |
| Identifiers | Variable names, function names, table names |
| Indentation | Indent increase, indent decrease (significant in templates) |
| Newline | Line boundaries (significant in route/schema files) |

### Parse Modes

The tokenizer operates in different modes depending on the file type:

**Route/Schema mode** (for `app.do`, `posts.do`, etc.):
- Newlines are significant (they separate statements)
- Indentation within `do ... end` blocks is tracked but not structurally significant (blocks are delimited by keywords)
- String interpolation `#{}` is handled inline

**Template mode** (for `views/*.do` files):
- Indentation is structurally significant (determines nesting, like Pug)
- No closing tags needed
- `=` at the start of content marks expression output
- Text content is treated as literal output unless prefixed with control keywords

**Native block mode** (for `native do ... end` content):
- Content is treated as raw text and passed through to codegen unchanged
- Only the `end` keyword (at the correct indentation level) terminates the block

### Whitespace Handling

Doot is whitespace-significant in templates but keyword-delimited in routes and schema. The tokenizer tracks:

- Current indentation level (number of spaces)
- Indentation changes (indent/dedent) for template mode
- Significant newlines for statement boundaries

---

## Stage 2: Parsing

The parser is a recursive-descent parser that consumes the token stream and builds an AST. Each syntactic construct has a corresponding parsing function.

### Recursive-Descent Design

A recursive-descent parser works by having one function per grammar rule. Each function:

1. Examines the current token(s) to decide which production to follow
2. Consumes tokens as it matches the expected pattern
3. Recursively calls other parsing functions for nested constructs
4. Returns an AST node representing what it parsed

For example, parsing a route declaration:

```
parseRoute():
  expect(keyword "route")
  method = expect(HTTP_METHOD)     # GET, POST, etc.
  path = expect(STRING)            # "/posts/:id"
  options = parseRouteOptions()    # auth:, role: (optional)
  expect(keyword "do")
  expect(PIPE)
  ctx = expect(IDENTIFIER)         # "ctx"
  expect(PIPE)
  body = parseHandlerBody()        # statements until "end"
  expect(keyword "end")
  return RouteNode(method, path, options, ctx, body)
```

### AST Node Types

The AST captures the full structure of a Doot application. Key node types include:

#### Application-Level Nodes

| Node | Contains |
|------|----------|
| `AppNode` | Config, schema, mounts, routes (the entire app) |
| `ConfigNode` | Port, session_secret, CORS settings |
| `SchemaNode` | Tables, auth block |
| `TableNode` | Table name, fields, timestamps flag |
| `FieldNode` | Name, type, constraints |
| `AuthNode` | Model name, roles, email_verification |
| `MountNode` | Feature file path |

#### Route and Handler Nodes

| Node | Contains |
|------|----------|
| `RouteNode` | HTTP method, path, auth options, handler body |
| `GroupNode` | Options (auth, role), list of RouteNodes |
| `HandlerBodyNode` | List of statements |
| `RenderNode` | Template path, locals (key-value pairs) |
| `RedirectNode` | Target path |
| `DbQueryNode` | Table, method (create/find/all/update/delete), arguments |
| `AssignmentNode` | Variable name, expression |
| `IfNode` | Condition, then-branch, else-branch |
| `EachNode` | Item variable, collection expression, body |
| `NativeBlockNode` | Raw Nim code (string, passed through) |

#### Template Nodes

| Node | Contains |
|------|----------|
| `TemplateNode` | Extends reference, blocks, body |
| `ExtendsNode` | Layout path |
| `BlockDefNode` | Block name, default value (optional), content |
| `ElementNode` | Tag name, classes, ID, attributes, children |
| `ExpressionOutputNode` | Expression, escaped flag |
| `TextNode` | Literal text content |
| `PartialNode` | Partial path, locals |
| `TemplateIfNode` | Condition, then-content, else-content |
| `TemplateEachNode` | Item variable, collection, body content |

#### Expression Nodes

| Node | Contains |
|------|----------|
| `StringLiteralNode` | Value, interpolation segments |
| `IntegerLiteralNode` | Value |
| `BooleanLiteralNode` | Value |
| `NilNode` | (no data) |
| `IdentifierNode` | Name |
| `MemberAccessNode` | Object, property |
| `MethodCallNode` | Object, method name, arguments |
| `IndexAccessNode` | Object, key expression |
| `BinaryOpNode` | Left, operator, right |
| `UnaryOpNode` | Operator, operand |
| `ArrayLiteralNode` | Elements |

### Error Recovery

When the parser encounters unexpected tokens, it does not immediately abort. Instead:

1. It records a precise error with file, line, column, and a human-readable message
2. It attempts to skip ahead to the next recognizable construct (e.g., the next `route`, `end`, or top-level keyword)
3. It continues parsing to find additional errors in one pass

This means a single `doot dev` run can report multiple errors simultaneously rather than failing on the first one.

---

## Stage 3: Nim Code Generation

The code generator walks the AST and emits valid Nim source code. This is where the DSL's abstractions are translated into concrete implementations.

### What Gets Generated

#### HTTP Server

The routes defined in `.do` files become a Nim HTTP server setup:

- Route registration with path matching and parameter extraction
- Request/response handling
- Auth middleware (session validation, role checking)
- Static file serving with gzip compression
- HTMX delivery (embedded, gzipped, served from a built-in path)
- CORS enforcement

#### Query Interface

Each `table` declaration in the schema generates:

- A Nim type/object representing a row
- `db.<table>.create(...)` function with validation logic
- `db.<table>.find(id)` function with auto-404 on nil
- `db.<table>.find_by(...)` function with auto-404 on nil
- `db.<table>.all(...)` function with where/order/limit support
- `db.<table>.update(record, ...)` function
- `db.<table>.delete(record)` function
- Result type with `ok?`, `errors`, and record accessor

The generated SQL is parameterized (no string concatenation of user input into queries).

#### Template Renderers

Each `.do` view file becomes a Nim function that:

- Accepts the named locals declared in `render` calls
- Resolves the inheritance chain (`extends`, named `block`s)
- Evaluates expressions and auto-escapes output
- Handles control flow (`if`, `each`)
- Includes partials (recursively rendered)
- Returns the final HTML string

#### Auth System

The `auth :users` declaration generates:

- User table schema with password hash field
- Signup handler (password hashing via argon2/bcrypt C FFI)
- Login handler (password verification, session creation)
- Logout handler (session destruction)
- Session middleware (cookie validation, user loading)
- Role checking middleware

#### Jobs

Job and schedule declarations generate:

- Job queue table schema
- Worker pool initialization
- Job dispatch function (matching job_type to handler)
- Scheduler loop (inserting jobs at configured intervals)
- Enqueue function (INSERT into the queue table)

#### Native Block Pass-Through

Content inside `native do ... end` blocks is emitted as-is into the generated Nim code at the corresponding location. The code generator:

1. Identifies the `NativeBlockNode` in the AST
2. Emits the raw Nim code at the correct scope in the generated source
3. Ensures DSL variables (`ctx`, `post`, `db`, etc.) are in scope as Nim variables
4. Does not validate or transform the native code

This means type errors or bugs in native blocks produce standard Nim compiler errors at Stage 4.

### Generated File Structure

The code generator produces a set of `.nim` files:

```
.doot-build/
├── main.nim            # Entry point, server setup, route registration
├── schema.nim          # Table types, query interface functions
├── auth.nim            # Auth handlers, session management
├── templates.nim       # Template rendering functions
├── jobs.nim            # Job handlers, worker pool, scheduler
└── migrations.nim      # Migration runner
```

These files are an intermediate artifact, not something the user edits or sees.

---

## Stage 4: Nim Compilation

The generated Nim source is compiled by the Nim compiler (`nim c`) into a single native binary. This stage is entirely the Nim compiler's responsibility.

### Incremental Compilation Cache

Nim maintains its own compilation cache. When only one `.do` file changes, the Nim compiler can often reuse cached compilation results for unchanged modules. This speeds up recompilation during `doot dev` significantly.

This caching is an implementation detail. From the user's perspective, every file change triggers a full recompile and restart. The caching just makes it faster. There is no "partial reload" or "hot module replacement" concept.

### Compilation Flags

In development mode (`doot dev`):
- Debug symbols enabled for better Nim error messages
- Faster compilation (less optimization)

In production mode (`dootd` build):
- Full optimization (`-d:release`)
- Smaller binary size
- No debug symbols

---

## Migration File Generation

When `doot dev` detects a schema change in `app.do`, it generates a migration file.

### How the Diff Works

1. The compiler reads the current `app.do` schema and builds a "desired state" representation
2. It compares this against the "last known state" (stored from the previous compilation)
3. Differences are categorized as additive or destructive

### What It Produces

**Additive changes** (auto-applied without prompting):
- New table (generates `CREATE TABLE`)
- New column on existing table (generates `ALTER TABLE ADD COLUMN`)
- New index

**Destructive changes** (require explicit confirmation):
- Column rename (generates `ALTER TABLE RENAME COLUMN` after confirmation)
- Column removal (generates migration to drop column after confirmation)
- Table removal (generates `DROP TABLE` after confirmation)
- Type change (may require data migration)

### Migration File Format

Generated migration files are numbered sequentially and stored in `migrations/`:

```
migrations/
├── 001_create_posts.sql
├── 002_create_comments.sql
└── 003_add_slug_to_posts.sql
```

These files are committed to git and applied by `dootd` on production deploy. The same migration system handles both dev and prod (one path, Rule 3).

### State Tracking

The Doot runtime maintains a `_migrations` table in SQLite that records which migrations have been applied. On startup (dev or prod), any unapplied migrations are run in order.

---

## Error Message Design

Error messages are a critical part of the compiler. They are designed for two audiences: human developers (including non-technical users) and AI agents writing `.do` files.

### Design Principles

**Precise locations.** Every error points to an exact file, line, and column:

```
Error in posts.do, line 14, column 3:
  Expected 'route' keyword, got 'rout'

  14 |   rout GET "/posts" do |ctx|
         ^^^^
  Did you mean: route
```

**Actionable suggestions.** Where possible, the error tells you what to do:

```
Error in app.do, line 8:
  Unknown field type ':str'

  8 |     field "title", :str, required: true
                         ^^^^
  Valid types are: :string, :text, :integer, :boolean, :float, :datetime
```

**Agent-friendly output.** Errors are structured so that an AI agent can parse them and make corrections:

- Consistent format: `Error in <file>, line <n>, column <c>:`
- Clear identification of what was expected vs. what was found
- Suggestion of the correct syntax when possible
- No ambiguous or overly technical language

### Error Categories

| Category | Example |
|----------|---------|
| Syntax error | Misspelled keyword, missing `end`, wrong delimiter |
| Type error | Invalid field type, wrong argument type |
| Reference error | Rendering a template that does not exist, querying a table not in schema |
| Constraint error | Duplicate route path, duplicate field name |
| Missing dependency | `env()` referencing a key not in `.env` (caught at deploy time) |

### Multiple Errors in One Pass

The parser uses error recovery to report multiple errors in a single compilation attempt. This is important for both humans (who can fix several issues at once) and agents (who can batch corrections).

---

## Future: LSP Tooling

The handwritten parser and AST are designed to support a Language Server Protocol implementation in the future. This would provide:

- **Autocomplete** - Suggesting field names, table names, template paths, ctx properties
- **Hover information** - Showing the type and constraints of a field when hovering over its usage
- **Go-to-definition** - Jumping from a `render "posts/show"` call to the actual view file
- **Diagnostics** - Real-time error highlighting as you type (without waiting for a full recompile)
- **Rename refactoring** - Renaming a table and updating all `db.<table>.*` references

The recursive-descent parser is designed with this in mind:

- It can parse partial/incomplete files (important for real-time editing)
- It preserves position information (file, line, column) for every AST node
- It supports incremental re-parsing (only re-parse the changed region)

This is not implemented in v1 but is a first-class consideration in the parser's architecture. The "slower to bootstrap" trade-off of a handwritten parser pays off here.

---

## Summary

| Stage | Input | Output | Tool |
|-------|-------|--------|------|
| Tokenization | `.do` file text | Token stream | Handwritten tokenizer |
| Parsing | Token stream | AST | Recursive-descent parser |
| Code generation | AST | `.nim` files | Handwritten codegen |
| Compilation | `.nim` files | Native binary | Nim compiler |
| Migration diff | Current schema vs. last known | SQL migration file | Custom differ |

The entire pipeline is invoked on every file change during `doot dev`. Nim's incremental compilation cache makes this fast enough for interactive development. The user sees: save file, app restarts. The complexity of the pipeline is invisible.

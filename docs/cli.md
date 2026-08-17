# CLI

Doot ships as a single binary that serves as both the local development CLI and the production daemon. This document covers the CLI commands used during development.

---

## Commands Overview

| Command | Purpose |
|---------|---------|
| `doot new <name>` | Scaffold a new project |
| `doot dev` | Start the development server with file watching |
| `doot help` | Show available commands and usage |
| `doot --prod` | Switch to production daemon mode (see [dootd.md](dootd.md)) |

There is **no `doot build` command**. Building a deployable artifact is entirely `dootd`'s responsibility. This keeps deployment to a single path (Rule 3). Doot is not a general-purpose "produce a binary" tool.

---

## `doot new <name>`

Scaffolds a new Doot project with all necessary files and directories.

### Usage

```
$ doot new my-app
```

### Generated Structure

```
my-app/
  app.do              # Entry point: schema, config, mounts
  views/
    layouts/
      base.do         # Default layout template
    errors/
      404.do          # Custom 404 page (optional, auto-used if present)
      500.do          # Custom 500 page (optional, auto-used if present)
  static/
    app.css           # Starter stylesheet
  migrations/         # Auto-generated migration files (committed to git)
  uploads/            # Local file upload storage (v1)
  .env                # Environment variables (secrets, config)
  .env.example        # Template showing required env vars
  .gitignore          # Pre-configured (ignores .env, uploads/, etc.)
```

### What Happens

1. Creates the project directory with the given name
2. Generates `app.do` with a minimal config block and empty schema
3. Creates the `views/` directory with a starter layout
4. Creates the `static/` directory with a minimal CSS file
5. Creates the `migrations/` directory (empty, will be populated by schema diffs)
6. Creates the `uploads/` directory for local file storage
7. Generates `.env` with placeholder values for `SESSION_SECRET`
8. Generates `.env.example` documenting required variables
9. Generates `.gitignore` configured to exclude `.env`, `uploads/`, and build artifacts
10. Displays a welcome message with next steps

### Welcome Message

```
$ doot new my-app

  Created my-app/

  Next steps:
    cd my-app
    doot dev

  Your app will be running at http://localhost:3000
```

The welcome message is minimal and actionable. It tells the user exactly what to do next, nothing more.

---

## `doot dev`

Starts the local development server. Watches for file changes, recompiles the entire application, and restarts the server automatically.

### Usage

```
$ doot dev
```

### Behavior

When `doot dev` starts:

1. Parses all `.do` files (schema, routes, templates, jobs)
2. Generates Nim source code from the AST
3. Compiles the generated Nim into a native binary
4. Starts the compiled binary as the dev server
5. Begins watching all project files for changes

When a file changes:

1. File watcher detects the modification
2. Full recompile is triggered (parse all `.do` files, regenerate Nim, recompile)
3. Running dev server process is stopped
4. New binary is started
5. Browser reflects the updated application

### Full Recompile, Not Partial Reload

Doot uses **full recompile and restart** on every file change. There is no granular hot module replacement, no partial reload, no selective recompilation exposed to the user.

This is deliberate:

- **Predictable**: The running app always matches the saved source files, exactly
- **Simple**: No state management issues from partial updates
- **Honest**: One path, no magic (Rule 3)

Internally, Nim's incremental compilation cache is used to speed up recompilation. This is an implementation detail that keeps iteration fast without exposing complexity to the user. The user sees: save file, app restarts, changes are live.

### File Watching Scope

The file watcher monitors:

- `app.do` and all mounted `.do` files (routes, handlers, jobs)
- All files under `views/` (templates, layouts, partials)
- `.env` file (environment variable changes)

The file watcher does **not** trigger recompilation for:

- `static/` directory (static files are served directly, no compilation needed)
- `migrations/` directory (migration files are outputs, not inputs)
- `uploads/` directory
- `.git/` and other dotfiles/directories

### Schema Change Detection

When `doot dev` detects a change to the `schema do ... end` block in `app.do`:

1. Diffs the current schema declaration against the last known state
2. Generates a numbered migration file (e.g., `001_create_posts.sql`)
3. Saves the migration file to `migrations/`
4. Applies the migration based on change type:
   - **Additive changes** (new table, new column): auto-applied immediately, no confirmation needed
   - **Destructive changes** (rename column, drop column, drop table): requires explicit confirmation in the terminal before applying

See [migrations.md](migrations.md) for full details on the migration system.

### Error Output

When compilation or runtime errors occur, `doot dev` displays them clearly in the terminal:

- **Parse errors**: Shows the exact file, line number, and column with a clear description of what went wrong
- **Type errors**: Shows which field or expression has a type mismatch
- **Missing references**: Shows when a view, table, or field is referenced but does not exist
- **Runtime errors**: Shows the stack trace with the relevant `.do` file locations mapped back from the generated Nim code

Errors are designed to be:

- **Clear**: Plain language description, not compiler jargon
- **Actionable**: Tells the user what to fix, not just what is wrong
- **Located**: Points to the exact position in the `.do` source file, even though compilation happens via generated Nim code

```
Error in posts.do, line 12:

  db.posts.create(titl: ctx.form["title"])
                  ^^^^
  Unknown field "titl" on table "posts".
  Did you mean: "title"?
```

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Normal shutdown (Ctrl+C or signal) |
| `1` | Compilation failed on initial startup (project has errors) |

If compilation fails during file watching (after initial successful start), `doot dev` does **not** exit. It reports the error in the terminal and waits for the next file change to retry compilation. The last successfully compiled version continues running.

---

## `doot help`

Displays available commands, their usage, and brief descriptions.

### Usage

```
$ doot help
```

### Output

```
Doot - DSL for web applications

Usage:
  doot <command> [options]

Commands:
  new <name>    Create a new Doot project
  dev           Start development server with file watching
  help          Show this help message

Production:
  --prod        Start in production daemon mode
  --prod --reset-password   Reset the dashboard password

Run 'doot help <command>' for details on a specific command.
```

---

## `doot --prod`

Switches the binary into production daemon mode. This is covered in detail in [dootd.md](dootd.md), but the CLI interface is documented here.

### First Run

```
$ doot --prod
  Dashboard ready at http://<ip>:8080
  Username: admin
  Password: k3x9-p2mN-q8vL   (save this - shown only once; change it from dashboard settings)
  Registered as a systemd service (dootd) - persists across reboots
```

- **Password is auto-generated** and shown exactly once in the terminal output. It is never stored in shell history or process lists.
- **systemd service is auto-registered.** The daemon persists across reboots and SSH disconnects without any additional configuration.
- The user never needs to SSH again after this initial setup.

### Subsequent Runs (Idempotent)

If the service is already running, re-running `doot --prod` does **not** re-initialize or touch existing state. This prevents accidental data loss (the SQLite databases of deployed apps would be at risk otherwise).

```
$ doot --prod
  Service already running/configured.
  Dashboard: http://<ip>:8080
  Forgot password? Run: doot --prod --reset-password
```

### Password Reset

```
$ doot --prod --reset-password
  New password: m7xK-n3pQ-w9vR   (save this - shown only once)
```

This is the recovery path for lost dashboard credentials. It requires SSH access to the server, which acts as proof of ownership.

---

## Exit Codes

All CLI commands follow consistent exit code conventions:

| Code | Meaning |
|------|---------|
| `0` | Success / normal shutdown |
| `1` | Compilation or validation error |
| `2` | Invalid command or arguments |

---

## What Does Not Exist

The following commands are explicitly **not part of Doot**:

- **`doot build`** - There is no standalone build command. Building is `dootd`'s responsibility on the production server. One path for deployment (Rule 3).
- **`doot test`** - Deferred to post-v1. The format depends on how the DSL settles in real-world usage.
- **`doot deploy`** - Deployment happens through the `dootd` dashboard, not a CLI push command.
- **`doot install`** - There are no packages, no dependencies, no registry. Doot is self-contained.

This is not a limitation. It is a deliberate reduction of surface area. Every command that does not exist is a decision the user does not have to make.

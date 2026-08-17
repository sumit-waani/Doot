# dootd - Production Dashboard and Daemon

`dootd` is Doot's production mode: a web dashboard, app manager, build pipeline, and process supervisor combined into the same single binary used for local development. When you run `doot --prod`, the binary switches into daemon mode.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                         dootd (doot --prod)                           │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌───────────────────┐  ┌──────────────────────────────────────────┐ │
│  │  Web Dashboard    │  │  App Manager                             │ │
│  │  - App CRUD       │  │  - Git pull from GitHub                  │ │
│  │  - Deploy button  │  │  - Env var validation (fail-fast)        │ │
│  │  - Log viewer     │  │  - Compile (parse / codegen / Nim)       │ │
│  │  - Server stats   │  │  - Apply pending migrations              │ │
│  │  - Job monitoring │  │  - Start supervised child process        │ │
│  │  - Settings       │  │  - Restart on crash                      │ │
│  └───────────────────┘  └──────────────────────────────────────────┘ │
│                                                                      │
│  ┌───────────────────┐  ┌──────────────────────────────────────────┐ │
│  │  Process          │  │  Host-Header Router                      │ │
│  │  Supervisor       │  │  - Port 80 incoming                      │ │
│  │  - Per-app cgroups│  │  - Route by hostname to internal ports   │ │
│  │  - Crash restart  │  │  - Dashboard on its own host/port        │ │
│  │  - Health checks  │  └──────────────────────────────────────────┘ │
│  └───────────────────┘                                               │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

All of this runs as a single process on a single machine. No containers, no orchestration, no reverse proxy.

---

## First-Time Setup

The setup flow requires exactly one SSH session:

```
$ ssh user@your-vps
$ doot --prod
  Dashboard ready at http://<ip>:8080
  Username: admin
  Password: k3x9-p2mN-q8vL   (save this - shown only once; change it from dashboard settings)
  Registered as a systemd service (dootd) - persists across reboots
```

After this:

1. The dashboard is accessible from your browser
2. The `dootd` service is registered with systemd
3. You never need to SSH into the server again

The password is auto-generated and displayed exactly once. It is never passed as a CLI argument (avoiding shell history and `ps` leakage). If lost, it can be reset via `doot --prod --reset-password`, which requires SSH access as proof of ownership.

### Idempotent Re-runs

Running `doot --prod` again when the service is already configured does **not** re-initialize anything. Existing app data, SQLite databases, and configuration remain untouched.

```
$ doot --prod
  Service already running/configured.
  Dashboard: http://<ip>:8080
  Forgot password? Run: doot --prod --reset-password
```

This prevents accidental data loss from careless re-runs.

---

## Dashboard UI

The web dashboard is the primary interface for managing deployed applications. It is accessible via a browser at the configured host/port.

### App Creation

To deploy an application, you create it in the dashboard by providing:

- **GitHub URL** - The repository containing the Doot project
- **Personal Access Token (PAT)** - For cloning private repositories
- **Environment variables** - All required `.env` values for the app
- **Hostname** - The domain that will route to this app

### Dashboard Sections

| Section | Purpose |
|---------|---------|
| **Apps** | List all configured applications, their status, and deploy controls |
| **Deploy** | Trigger a deploy for any app (pull, build, migrate, start) |
| **Logs** | View stdout/stderr output from each running app |
| **Server Stats** | CPU, memory, disk usage for the host machine |
| **Jobs** | View pending, running, and failed background jobs across all apps |
| **Settings** | Dashboard password change, global configuration |

### Failed Job Retry

The Jobs section shows all background jobs across deployed apps. Failed jobs are listed with their error information. A retry button allows re-enqueueing a failed job directly from the dashboard without needing to write code or access the database.

---

## Deploy Flow

When you click "Deploy" for an app (or when auto-deploy triggers on push), `dootd` executes these steps in order:

### 1. Git Pull

```
git pull origin main
```

Pulls the latest code from the configured GitHub repository using the stored PAT for authentication.

### 2. Validate Environment Variables

Before any compilation begins, `dootd` checks that all required environment variables are configured. It inspects what the app needs (based on `env()` calls in `app.do` and features like `email_verification: true` that require SMTP config) and compares against what is configured in the dashboard.

If any required variables are missing:

```
Deploy failed: missing required environment variables.

  SMTP_HOST     - required by: email_verification
  SMTP_PASSWORD - required by: email_verification

Configure these in the app's environment settings before deploying.
```

This is a **fail-fast** check. The deploy stops immediately with a clear error. The app never starts in a broken state.

### 3. Compile

The full compiler pipeline runs:

1. **Parse** - All `.do` files are parsed into an AST
2. **Codegen** - AST is transformed into Nim source code
3. **Nim Compile** - Nim compiler produces a native binary

If compilation fails, the deploy stops with the error message displayed in the dashboard. The currently running version of the app (if any) continues serving traffic undisturbed.

### 4. Apply Migrations

Any migration files in `migrations/` that have not been applied yet are executed against the app's SQLite database. Migration files are the same ones generated by `doot dev` during development and committed to the git repository.

See [migrations.md](migrations.md) for details on the migration system.

### 5. Start Supervised Child Process

The compiled binary is started as a child process of `dootd`:

- Assigned an internal port (e.g., 3001, 3002, etc.)
- Registered with the process supervisor for crash recovery
- Isolated via cgroups-based resource limits
- Stdout/stderr captured for the log viewer

---

## Host-Header Based Routing

`dootd` listens on port 80 and routes incoming HTTP requests to the correct application based on the `Host` header.

```
                    Port 80
                      │
                      ▼
              ┌───────────────┐
              │  Host-Header  │
              │    Router     │
              └───────┬───────┘
                      │
        ┌─────────────┼─────────────┐
        │             │             │
        ▼             ▼             ▼
  dashboard.ip   app1.example.com  app2.example.com
  (port 8080)    (port 3001)       (port 3002)
```

### How It Works

- Each app is assigned a hostname during creation in the dashboard
- Each app runs on its own internal port (not exposed externally)
- `dootd` receives all traffic on port 80 and inspects the `Host` header
- Traffic is forwarded to the correct internal port based on hostname match
- The dashboard itself is accessible via its own host/port (configurable)

### No Reverse Proxy

This routing is built into `dootd` itself. There is no nginx, no Traefik, no HAProxy. The user never sees or configures a reverse proxy (Rule 6). The routing logic is internal to the daemon.

---

## Child Process Management

Each deployed app runs as a supervised child process of `dootd`.

### Internal Port Assignment

Apps are assigned internal ports automatically (e.g., 3001, 3002, 3003). These ports are not exposed externally. All external traffic arrives on port 80 and is routed by `dootd`.

### Crash Recovery

If an app process crashes:

1. `dootd` detects the exit immediately
2. The process is restarted automatically
3. If the process crashes repeatedly (e.g., 5 times in 60 seconds), it is marked as unhealthy
4. The dashboard shows the crash status and recent logs

### cgroups-Based Isolation

Each app process runs in its own cgroup with configurable resource limits:

- **Memory limit** - Prevents one app from consuming all server RAM
- **CPU shares** - Fair scheduling between apps

This provides basic isolation without containers. Apps cannot starve each other of resources, but they share the same filesystem and network namespace (isolated by port assignment, not by network namespace).

---

## Environment Variable Validation

Environment variable validation is one of `dootd`'s most important safety features. It implements Rule 4 (secure/deny by default) for production deployments.

### What Gets Validated

- All `env("KEY")` calls in `app.do` and feature files
- Implicit requirements from features:
  - `email_verification: true` requires `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`
  - `session_secret env("SESSION_SECRET")` requires `SESSION_SECRET`

### When Validation Runs

Validation runs **before compilation**, at the very start of the deploy flow. If validation fails, no code is compiled, no migrations run, and the existing app continues undisturbed.

### Error Messages

```
Deploy failed: missing required environment variables.

  SESSION_SECRET  - required by: config block
  SMTP_HOST       - required by: email_verification

Configure these in the app's environment settings before deploying.
```

The error message tells the user exactly which variables are missing and which features require them.

---

## Redeploy

### Manual Redeploy

Click the "Deploy" button in the dashboard. This pulls the latest code and runs the full deploy flow.

### Future: Auto-Deploy on Push

Auto-deploy on git push is noted as a future addition. In v1, deploys are triggered manually from the dashboard. The architecture supports webhook-based triggers, but the implementation is deferred.

---

## systemd Service

`dootd` auto-registers itself as a systemd service during first-time setup.

### What This Means

- **Survives SSH disconnect** - The daemon keeps running after you close your terminal
- **Survives reboots** - systemd starts `dootd` automatically on boot
- **Standard management** - Can be checked with `systemctl status dootd` if needed (but users should never need to)
- **Logging** - journald captures `dootd` logs

### No Manual Configuration

The user never writes a systemd unit file. `doot --prod` handles registration automatically. This is the only path to production deployment.

---

## TLS and HTTPS

### v1: Plain HTTP Only

In v1, `dootd` serves everything over plain HTTP on port 80. This includes both the dashboard and all deployed apps.

### Recommended Setup: Cloudflare

For TLS in v1, users should front their server with Cloudflare (or a similar service):

1. Point your domain's DNS to Cloudflare
2. Cloudflare handles TLS termination
3. Cloudflare forwards traffic to your server on port 80
4. Your apps get HTTPS without any server-side TLS configuration

### Future: Native TLS

If TLS is added post-v1, it will be native to `dootd` (e.g., built-in ACME/Let's Encrypt certificate management). It will **never** be an external proxy dependency. No nginx, no Traefik, no Caddy configuration will ever be part of the Doot workflow.

This is a hard constraint from Rule 6: no reverse proxy configuration exposed to the user, ever.

---

## Explicit Non-Goals

The following are permanently out of scope for `dootd`:

| Non-Goal | Reason |
|----------|--------|
| **Multi-tenant hosting** | One `dootd` instance serves one user/team. Not a shared hosting platform. |
| **Docker support** | Apps compile to native binaries and run directly. No container images, no Dockerfiles. |
| **Kubernetes** | No pod specs, no services, no ingress. Single machine, single process. |
| **Container orchestration** | No Swarm, no Nomad, no ECS. cgroups provide sufficient isolation. |
| **Zero-downtime deploys** | Deferred to post-v1. In v1, there is a brief restart during redeploy. |
| **Multiple VPS/clustering** | One machine. If you need more, you have outgrown Doot. |
| **External reverse proxy** | No nginx, no Traefik, no HAProxy configs. Routing is internal to `dootd`. |

These are not missing features. They are deliberate non-goals that keep `dootd` simple enough that a non-technical user can operate it with confidence.

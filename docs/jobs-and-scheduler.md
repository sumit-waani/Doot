# Jobs and Scheduler

Doot includes a built-in background job system and scheduler. Even small applications routinely need background processing: sending emails, generating reports, cleaning up stale data, processing uploads. This is a basic need, not a scale-driven one.

---

## Philosophy

### Background Jobs Are Not a "Scale" Feature

The traditional framing of job queues (Sidekiq, Bull, Celery) associates them with scale: you add a job queue when your app gets big enough to need one. Doot rejects this framing.

A 10-user internal tool needs to send password reset emails without blocking the HTTP response. A personal blog needs to process image uploads in the background. A small SaaS needs to generate weekly reports on a schedule. These are basic web application needs, present from day one.

### SQLite as the Queue

Consistent with Rule 2 (SQLite only), the job queue is a SQLite table. No Redis, no RabbitMQ, no external message broker. Enqueuing a job is a single INSERT statement. Processing a job is a SELECT + UPDATE. SQLite's single-writer nature eliminates race conditions without advisory locks or distributed coordination.

### In-Process Workers

Consistent with Rule 3 (one path), workers run inside the same process as the application. There is no separate worker binary to deploy, no separate process to manage, no "did I remember to start the workers?" question. The application is one binary that handles HTTP requests AND processes background jobs.

---

## Queue Design

The job queue is a SQLite table managed automatically by Doot:

```sql
-- Auto-managed by Doot (never modify manually)
CREATE TABLE _doot_jobs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  job_type TEXT NOT NULL,
  payload TEXT NOT NULL DEFAULT '{}',   -- JSON
  status TEXT NOT NULL DEFAULT 'pending',
  run_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  attempts INTEGER DEFAULT 0,
  locked_at DATETIME,
  error TEXT,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
```

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | Integer | Auto-incrementing unique identifier |
| `job_type` | Text | Name of the job (matches the declared job name) |
| `payload` | JSON | Arguments passed when the job was enqueued |
| `status` | Text | One of: `pending`, `running`, `completed`, `failed` |
| `run_at` | DateTime | When the job should be executed (supports delayed jobs) |
| `attempts` | Integer | Number of times this job has been attempted |
| `locked_at` | DateTime | Set when a worker picks up the job (prevents double-processing) |
| `error` | Text | Error message if the job failed |
| `created_at` | DateTime | When the job was enqueued |
| `updated_at` | DateTime | Last status change |

### Why SQLite Works Here

SQLite's single-writer constraint, which is often seen as a limitation, is a **feature** for job queues:

- **No race conditions**: Only one writer can modify the table at a time, so two workers cannot claim the same job
- **No advisory locks needed**: The single-writer nature provides mutual exclusion automatically
- **No external dependency**: The queue lives in the same database file as the application data
- **Transactional**: Job status changes are atomic (a job cannot be marked "running" and then crash before processing, leaving it permanently locked)

For the scale of applications Doot targets (10s to hundreds of concurrent users, not thousands), SQLite's throughput is more than sufficient for background job processing.

---

## Declaring Jobs

Jobs are declared using the `job` keyword in any `.do` file:

```
# jobs.do
job "send_welcome_email" do |payload|
  email = payload["email"]
  name = payload["name"]

  send_email(
    to: email,
    subject: "Welcome to our app!",
    body: "Hi #{name}, thanks for signing up!"
  )
end

job "process_upload" do |payload|
  file_path = payload["path"]
  # Process the uploaded file (resize image, generate thumbnail, etc.)
  native do
    # Use Nim libraries for image processing if needed
    let img = loadImage(file_path)
    let thumb = img.resize(200, 200)
    thumb.save(file_path & "_thumb.jpg")
  end
end

job "generate_report" do |payload|
  report_type = payload["type"]
  user_id = payload["user_id"]

  data = db.orders.where(user_id: user_id)
  # Generate and store the report...
end
```

### Payload

The `payload` parameter is a JSON object containing whatever data the job needs to execute. It is passed when the job is enqueued and available when the job runs.

Keep payloads small and serializable. Store IDs and references, not large objects:

```
# Good: store the ID, look up fresh data when the job runs
enqueue "send_notification", user_id: 42, post_id: 7

# Bad: store the entire object (stale data, large payload)
# enqueue "send_notification", user: entire_user_object
```

---

## Enqueuing Jobs

To add a job to the queue, use the `enqueue` function:

```
route POST "/signup" do |ctx|
  result = auth.create_user(
    email: ctx.form["email"],
    password: ctx.form["password"]
  )

  if result.ok?
    # Send welcome email in the background
    enqueue "send_welcome_email", email: result.user.email, name: ctx.form["name"]
    redirect "/dashboard"
  else
    render "auth/signup", errors: result.errors
  end
end
```

### Syntax

```
enqueue "job_name", key1: value1, key2: value2
```

This is equivalent to inserting a row into the `_doot_jobs` table with:
- `job_type` = `"job_name"`
- `payload` = `{"key1": "value1", "key2": "value2"}`
- `status` = `"pending"`
- `run_at` = now (immediate execution)

### Delayed Jobs

To schedule a job for later execution:

```
enqueue "send_reminder", user_id: 42, delay: 24.hours
```

The `delay` parameter sets `run_at` to the current time plus the specified duration. The job will not be picked up by a worker until that time arrives.

---

## Worker Design

### In-Process Pool

Workers run as an async pool inside the same application process. There is no separate worker binary, no separate deployment, no separate configuration.

```
┌──────────────────────────────────────────────────────┐
│              Compiled Doot Application                 │
│                                                      │
│  ┌────────────────────────────────────────────────┐  │
│  │              HTTP Server                       │  │
│  │  (handles web requests)                       │  │
│  └────────────────────────────────────────────────┘  │
│                                                      │
│  ┌────────────────────────────────────────────────┐  │
│  │            Job Worker Pool                     │  │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐      │  │
│  │  │ Worker 1 │ │ Worker 2 │ │ Worker 3 │ ...  │  │
│  │  └──────────┘ └──────────┘ └──────────┘      │  │
│  └────────────────────────────────────────────────┘  │
│                                                      │
│  ┌────────────────────────────────────────────────┐  │
│  │            Scheduler Loop                      │  │
│  │  (inserts scheduled jobs into the queue)       │  │
│  └────────────────────────────────────────────────┘  │
│                                                      │
└──────────────────────────────────────────────────────┘
```

### Pool Size

The default worker pool size is 2-4 workers. This is configurable in `app.do`:

```
config do
  port 3000
  session_secret env("SESSION_SECRET")
  workers 4   # Number of background job workers
end
```

The pool size should be kept small for most applications. Background jobs in Doot are not designed for massive parallelism; they handle typical web app background tasks (sending emails, processing uploads, generating reports).

### Job Processing Loop

Each worker in the pool:

1. Polls the `_doot_jobs` table for pending jobs where `run_at <= now`
2. Claims a job by setting `locked_at` and `status = 'running'`
3. Executes the job handler
4. On success: sets `status = 'completed'`
5. On failure: sets `status = 'failed'`, stores error message, increments `attempts`

The polling interval is short enough for responsive processing but not so aggressive that it wastes CPU on an empty queue.

---

## Scheduler (Cron)

The scheduler allows you to run jobs on a recurring schedule. It uses the same job queue internally.

### Declaring Scheduled Tasks

```
# jobs.do
schedule "daily_cleanup", every: "1 day", at: "03:00" do
  # Delete old sessions
  db.sessions.where("created_at < ?", 30.days.ago).delete_all

  # Clean up expired uploads
  db.uploads.where(status: "expired").delete_all
end

schedule "weekly_report", every: "1 week", at: "monday 09:00" do
  users = db.users.where(role: "admin")
  each user in users
    enqueue "generate_report", type: "weekly", user_id: user.id
  end
end

schedule "hourly_check", every: "1 hour" do
  # Check for stale jobs, send notifications, etc.
  stale = db.posts.where(status: "draft", updated_at: 7.days.ago)
  each post in stale
    enqueue "send_stale_reminder", post_id: post.id, user_id: post.user_id
  end
end
```

### Syntax

```
schedule "name", every: "interval" do
  # task body
end

schedule "name", every: "interval", at: "time" do
  # task body
end
```

### Interval Format

| Interval | Meaning |
|----------|---------|
| `"1 minute"` | Every minute |
| `"5 minutes"` | Every 5 minutes |
| `"1 hour"` | Every hour |
| `"1 day"` | Every day |
| `"1 week"` | Every week |

### The `at:` Option

Specifies when during the interval the job should run:

| Value | Meaning |
|-------|---------|
| `"03:00"` | At 3:00 AM (for daily schedules) |
| `"monday 09:00"` | Monday at 9 AM (for weekly schedules) |
| (omitted) | At the start of each interval |

### How Scheduling Works Internally

The scheduler is not a separate service. It is a loop running inside the same application process that:

1. Checks the schedule definitions
2. At the appropriate time, inserts a job into the `_doot_jobs` table
3. The regular worker pool picks up and executes the job

This means scheduled tasks go through the exact same execution path as manually enqueued jobs. There is one system, not two (Rule 3).

---

## Retry and Failure Handling

### v1: Intentionally Minimal

Retry and failure handling is kept simple in v1:

- **Failed jobs** are marked with `status = 'failed'` and the error message is stored
- **No automatic retry** with exponential backoff (this adds complexity without clear benefit at Doot's scale)
- **No dead-letter queue** (failed jobs stay in the main table with `status = 'failed'`)
- **No alerting system** (the dashboard is the monitoring interface)

### Dashboard Integration

Failed jobs are visible in the `dootd` dashboard:

- View all failed jobs with their error messages
- See which job type failed and when
- **Retry button**: re-enqueue a failed job with one click (resets status to `pending`, increments attempts)
- View job history (completed, failed, pending counts)

### Manual Retry

From the dashboard, clicking "Retry" on a failed job:

1. Resets `status` to `pending`
2. Clears `locked_at` and `error`
3. Increments `attempts`
4. Sets `run_at` to now

The job re-enters the queue and will be picked up by the next available worker.

---

## Integration with Other Systems

### Email Verification

The [auth system](auth.md)'s email verification uses background jobs:

```
# This happens automatically when email_verification is enabled:
# After signup, Doot enqueues:
enqueue "send_verification_email", user_id: new_user.id, email: new_user.email
```

The job sends the verification email without blocking the signup HTTP response.

### Any Heavy Work

As a general rule, anything that takes more than a few hundred milliseconds should be a background job:

- Sending emails (SMTP can be slow)
- Processing uploaded files (resizing images, generating thumbnails)
- Generating reports or exports
- Making external HTTP calls (API integrations via the escape hatch)
- Cleaning up old data

```
route POST "/posts/:id/export" do |ctx|
  post = db.posts.find(ctx.params["id"])
  enqueue "export_post_pdf", post_id: post.id, user_id: ctx.current_user.id
  redirect "/posts/#{post.id}", notice: "Export started. Check back shortly."
end
```

The HTTP response returns immediately. The user sees a confirmation. The actual work happens in the background.

---

## Monitoring

### Dashboard View

The `dootd` dashboard provides a jobs monitoring section:

| View | Shows |
|------|-------|
| **Pending** | Jobs waiting to be processed (queued but not yet picked up) |
| **Running** | Jobs currently being executed by a worker |
| **Completed** | Recently completed jobs (auto-cleaned after a retention period) |
| **Failed** | Jobs that errored, with error messages and retry buttons |

### Job Counts

The dashboard shows aggregate counts for quick health checks:

- Total pending jobs (should not grow unboundedly)
- Jobs completed in the last hour/day
- Failed jobs requiring attention

---

## Complete Example

```
# app.do
config do
  port 3000
  session_secret env("SESSION_SECRET")
  workers 3
end

schema do
  auth :users do
    email_verification true
  end

  table "posts" do
    field "title", :string, required: true, max: 200
    field "body", :text, required: true
    field "user_id", :integer, required: true
    field "export_status", :string, default: "none"
    timestamps
  end
end
```

```
# jobs.do
job "send_welcome_email" do |payload|
  send_email(
    to: payload["email"],
    subject: "Welcome!",
    body: "Thanks for joining. Get started by creating your first post."
  )
end

job "export_post_pdf" do |payload|
  post = db.posts.find(payload["post_id"])
  db.posts.update(post.id, export_status: "processing")

  native do
    let html = renderPostToHtml(post)
    let pdf = htmlToPdf(html)
    writeFile("uploads/exports/post_#{post.id}.pdf", pdf)
  end

  db.posts.update(post.id, export_status: "ready")
end

job "cleanup_old_exports" do |payload|
  old_exports = db.posts.where("export_status = 'ready' AND updated_at < ?", 7.days.ago)
  each post in old_exports
    db.posts.update(post.id, export_status: "none")
    # Delete the file too
    native do
      removeFile("uploads/exports/post_#{post.id}.pdf")
    end
  end
end

schedule "nightly_cleanup", every: "1 day", at: "02:00" do
  enqueue "cleanup_old_exports"
end

schedule "daily_digest", every: "1 day", at: "08:00" do
  users = db.users.all()
  each user in users
    recent_posts = db.posts.where("created_at > ?", 1.day.ago)
    if recent_posts.any?
      enqueue "send_digest_email", user_id: user.id, post_count: recent_posts.count
    end
  end
end
```

```
# posts.do
route POST "/posts/:id/export", auth: required do |ctx|
  post = db.posts.find(ctx.params["id"])
  enqueue "export_post_pdf", post_id: post.id, user_id: ctx.current_user.id
  redirect "/posts/#{post.id}", notice: "PDF export started."
end
```

In this example:

- Email verification uses the jobs system automatically
- PDF export runs in the background without blocking the request
- Old exports are cleaned up nightly by a scheduled task
- A daily digest email is sent if there are new posts
- All of this runs inside the same binary, using the same SQLite database, with no external dependencies

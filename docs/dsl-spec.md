# DSL Specification

This is the complete syntax reference for the Doot DSL. Doot is a domain-specific language for web applications, not a general-purpose programming language. It compiles to a native binary via Nim and is designed to be readable by humans and unambiguous for AI agents.

---

## File Extension and Entry Point

- All Doot source files use the `.do` extension
- `app.do` is the entry point for every project
- Feature files (e.g., `posts.do`, `comments.do`) are mounted from `app.do`
- View files live under `views/` and also use the `.do` extension

---

## Config Block

The `config` block in `app.do` sets application-level configuration:

```
config do
  port 3000
  session_secret env("SESSION_SECRET")
end
```

### Available Directives

| Directive | Type | Description |
|-----------|------|-------------|
| `port` | Integer | HTTP port the app listens on |
| `session_secret` | String | Secret used for signing session cookies |

### The `env()` Function

`env("KEY")` reads a value from the `.env` file. If the key is missing, the app fails fast at deploy time (never at runtime). This is the only way to reference secrets in Doot.

```
config do
  session_secret env("SESSION_SECRET")
end
```

---

## Schema Declarations

The `schema do ... end` block in `app.do` declares all database tables. The schema is declarative and app-level. There is no separate schema file or model layer.

```
schema do
  table "posts" do
    field "title", :string, required: true, max: 200
    field "body", :text, required: true
    field "published", :boolean, default: false
    field "user_id", :integer, required: true
    timestamps
  end
end
```

### Tables

```
table "table_name" do
  # field declarations
end
```

Table names are plural, snake_case strings (e.g., `"posts"`, `"user_profiles"`).

### Fields

```
field "name", :type, constraint1: value, constraint2: value
```

Field names are singular, snake_case strings.

### Field Types

| Type | Description | SQLite mapping |
|------|-------------|----------------|
| `:string` | Short text (up to ~255 chars) | TEXT |
| `:text` | Long text (unlimited) | TEXT |
| `:integer` | Whole number | INTEGER |
| `:boolean` | True or false | INTEGER (0/1) |
| `:float` | Decimal number | REAL |
| `:datetime` | Date and time | TEXT (ISO 8601) |

### Constraints

| Constraint | Accepts | Description |
|------------|---------|-------------|
| `required` | `true` | Field cannot be null/empty |
| `max` | Integer | Maximum length (strings) or value (numbers) |
| `min` | Integer | Minimum length (strings) or value (numbers) |
| `default` | Any | Default value if not provided |
| `validate` | Symbol | Built-in validator (e.g., `:email`) |

```
field "title", :string, required: true, max: 200
field "age", :integer, min: 0, max: 150
field "email", :string, required: true, validate: :email
field "role", :string, default: "member"
```

### Timestamps

The `timestamps` keyword inside a table block adds `created_at` and `updated_at` fields automatically:

```
table "posts" do
  field "title", :string, required: true
  timestamps   # adds created_at, updated_at (both :datetime)
end
```

These fields are managed by the runtime. `created_at` is set on INSERT, `updated_at` is set on every UPDATE.

---

## Auth Schema

The `auth` block declares the authentication model. It is placed inside the `schema do ... end` block:

```
schema do
  auth :users do
    roles ["admin", "editor", "member"]
    email_verification true
  end
end
```

### What `auth :users` Provides

When you declare an `auth` block, the following are generated automatically:

- A `users` table with `email`, `password_hash`, `role`, and related fields
- Routes: `POST /signup`, `POST /login`, `POST /logout` (built-in, overridable)
- Password hashing (argon2/bcrypt) handled internally
- Session creation and signed cookie handling
- `ctx.current_user` available in every handler

### Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `roles` | Array of strings | None (plain auth) | Available roles for role-based access |
| `email_verification` | Boolean | `false` | Enable email verification flow (requires SMTP config in `.env`) |

### Default Auth Posture

All routes require authentication by default. A route must explicitly declare `auth: public` to be accessible without login:

```
# This route requires login (default behavior)
route GET "/dashboard" do |ctx|
  render "dashboard"
end

# This route is public (explicitly declared)
route GET "/", auth: public do |ctx|
  render "home"
end
```

This is Rule 4 in action: deny by default. If a route's auth is forgotten, the failure mode is "nobody can access it," never "everybody can access it."

---

## Route Declarations

Routes bind an HTTP method and path to a handler function.

### Basic Syntax

```
route METHOD "/path" do |ctx|
  # handler body
end
```

### Supported HTTP Methods

- `GET`
- `POST`
- `PUT`
- `DELETE`
- `PATCH`

### Path Parameters

Use `:param_name` in the path to capture dynamic segments:

```
route GET "/posts/:id" do |ctx|
  post = db.posts.find(ctx.params["id"])
  render "posts/show", post: post
end

route GET "/users/:user_id/posts/:id" do |ctx|
  post = db.posts.find_by(
    id: ctx.params["id"],
    user_id: ctx.params["user_id"]
  )
  render "posts/show", post: post
end
```

### Query Parameters

Access query string values via `ctx.query`:

```
route GET "/posts", auth: public do |ctx|
  page = ctx.query["page"]
  posts = db.posts.all(order: "created_at desc", limit: 20)
  render "posts/index", posts: posts, page: page
end
```

### Route-Level Auth

Auth can be specified per-route:

```
route GET "/posts", auth: public do |ctx|
  # Anyone can see this
end

route GET "/posts/new", auth: required do |ctx|
  # Must be logged in
end

route GET "/admin/stats", auth: required, role: "admin" do |ctx|
  # Must be logged in AND have the "admin" role
end
```

---

## Group Blocks

Groups apply shared settings to multiple routes:

```
group auth: required do
  route GET "/posts/new" do |ctx|
    render "posts/new"
  end

  route POST "/posts" do |ctx|
    # ...
  end

  route GET "/posts/:id/edit" do |ctx|
    # ...
  end
end
```

### Group Options

| Option | Values | Description |
|--------|--------|-------------|
| `auth` | `required`, `public` | Authentication requirement for all routes in the group |
| `role` | String | Required role for all routes in the group |

```
group auth: required, role: "admin" do
  route GET "/admin/dashboard" do |ctx|
    render "admin/dashboard"
  end

  route GET "/admin/users" do |ctx|
    users = db.users.all()
    render "admin/users", users: users
  end
end
```

---

## Handler Context (`ctx`)

Every route handler receives a `ctx` parameter that carries the full request context.

### `ctx.params`

Path parameters from the URL:

```
# For route GET "/posts/:id"
# Request: GET /posts/42
ctx.params["id"]   # => "42"
```

### `ctx.form`

Form data from POST/PUT/PATCH request bodies:

```
route POST "/posts" do |ctx|
  title = ctx.form["title"]
  body = ctx.form["body"]
end
```

### `ctx.query`

Query string parameters:

```
# Request: GET /posts?page=2&sort=title
ctx.query["page"]   # => "2"
ctx.query["sort"]   # => "title"
```

### `ctx.file`

Uploaded files:

```
route POST "/posts/:id/upload" do |ctx|
  file = ctx.file["attachment"]
  # file is saved to uploads/ directory
  # file.filename, file.path available
end
```

File uploads are stored on local disk in the `uploads/` directory (v1). There is no S3 integration in v1.

### `ctx.headers`

HTTP request headers:

```
route POST "/webhooks/stripe" do |ctx|
  signature = ctx.headers["Stripe-Signature"]
  # verify webhook signature
end
```

### `ctx.session`

Server-side session data (stored in SQLite, accessed via signed cookie):

```
route POST "/preferences" do |ctx|
  ctx.session.set("theme", ctx.form["theme"])
  redirect "/settings"
end

route GET "/settings" do |ctx|
  theme = ctx.session.get("theme")
  render "settings", theme: theme
end

route POST "/logout-everywhere" do |ctx|
  ctx.session.delete("theme")
  redirect "/"
end
```

| Method | Description |
|--------|-------------|
| `ctx.session.get(key)` | Retrieve a session value (returns nil if not set) |
| `ctx.session.set(key, value)` | Store a value in the session |
| `ctx.session.delete(key)` | Remove a value from the session |

### `ctx.current_user`

The currently authenticated user. Guaranteed non-nil inside `auth: required` routes:

```
group auth: required do
  route GET "/profile" do |ctx|
    user = ctx.current_user
    render "profile", user: user
    # user.id, user.email, user.role available
  end
end
```

---

## Database Query Interface (`db.<table>.*`)

Schema declarations auto-generate a query interface. No model classes, no ORM configuration. Define a table in the schema, and `db.<table_name>.*` methods become available.

### `db.<table>.create(...)`

Creates a new record. Returns a result object.

```
result = db.posts.create(
  title: "Hello World",
  body: "This is my first post",
  user_id: ctx.current_user.id
)
```

### `db.<table>.find(id)`

Finds a record by primary key. Returns the record or nil.

```
post = db.posts.find(ctx.params["id"])
```

**Important:** If `find` returns nil, a 404 response is triggered automatically. This removes boilerplate error handling from every handler. See [Error Handling](#error-handling) below.

### `db.<table>.find_by(...)`

Finds a single record matching the given conditions. Returns the record or nil (auto-404 on nil, same as `find`).

```
post = db.posts.find_by(slug: ctx.params["slug"])
user = db.users.find_by(email: ctx.form["email"])
```

### `db.<table>.all(...)`

Returns all records matching the given options.

```
# All posts, newest first
posts = db.posts.all(order: "created_at desc")

# With conditions
posts = db.posts.all(where: "published = true", order: "created_at desc")

# With limit
posts = db.posts.all(order: "created_at desc", limit: 10)

# Combined
comments = db.comments.all(
  where: "post_id = #{post.id}",
  order: "created_at asc",
  limit: 50
)
```

#### Options for `all`

| Option | Type | Description |
|--------|------|-------------|
| `where` | String | SQL WHERE clause |
| `order` | String | SQL ORDER BY clause |
| `limit` | Integer | Maximum number of records |

### `db.<table>.update(record, ...)`

Updates an existing record. Returns a result object.

```
result = db.posts.update(post,
  title: ctx.form["title"],
  body: ctx.form["body"]
)
if result.ok?
  redirect "/posts/#{post.id}"
else
  render "posts/edit", post: post, errors: result.errors
end
```

### `db.<table>.delete(record)`

Deletes a record. Returns a result object.

```
result = db.posts.delete(post)
if result.ok?
  redirect "/posts"
end
```

---

## Result Objects

`create`, `update`, and `delete` operations return a result object instead of throwing exceptions. This makes success/failure explicit and predictable.

### `result.ok?`

Returns `true` if the operation succeeded, `false` if validation failed.

```
result = db.posts.create(title: ctx.form["title"], body: ctx.form["body"])
if result.ok?
  redirect "/posts/#{result.post.id}"
else
  render "posts/new", errors: result.errors
end
```

### `result.errors`

A collection of validation error messages when `result.ok?` is `false`:

```
if !result.ok?
  # result.errors contains messages like:
  # ["title is required", "body must be at least 10 characters"]
  render "posts/new", errors: result.errors
end
```

### `result.<record>`

On success, the result contains the created/updated record, accessible by table name (singular):

```
result = db.posts.create(title: "Hello", body: "World")
# result.post.id, result.post.title, result.post.created_at

result = db.comments.create(body: "Great post!", post_id: post.id)
# result.comment.id, result.comment.body
```

The accessor name is the singular form of the table name (e.g., `db.posts` produces `result.post`, `db.comments` produces `result.comment`).

---

## Render

`render` responds with a rendered template. Local variables must be passed explicitly.

```
render "posts/index", posts: posts
render "posts/show", post: post, comments: comments
render "posts/new"
render "posts/new", errors: result.errors
```

### Key Rules

- Template path is relative to `views/` (so `"posts/index"` resolves to `views/posts/index.do`)
- All data passed to the template must be listed explicitly as key-value pairs
- No implicit variable leakage (unlike Rails, where instance variables automatically pass to views)
- The view can only access the named locals you pass to it

This explicitness means the data contract between handler and view is always visible in the handler code. An agent (or human) can look at the `render` call and know exactly what data the view expects.

---

## Redirect

`redirect` sends an HTTP redirect response:

```
redirect "/posts"
redirect "/posts/#{result.post.id}"
redirect "/"
```

The redirect is a standard 302 response by default.

---

## String Interpolation

Use `#{}` inside strings to interpolate expressions:

```
redirect "/posts/#{result.post.id}"
title = "Hello, #{ctx.current_user.email}"
where_clause = "post_id = #{post.id}"
```

String interpolation works in:
- Handler code (string arguments, redirect paths, where clauses)
- Template text and attributes (see [docs/templates.md](templates.md))

---

## Control Flow

### `if` / `else` / `end`

```
if result.ok?
  redirect "/posts/#{result.post.id}"
else
  render "posts/new", errors: result.errors
end
```

```
if posts.empty?
  render "posts/empty"
else
  render "posts/index", posts: posts
end
```

### `each` / `end`

Iterate over a collection:

```
each post in posts
  # do something with post
end
```

`each` is primarily used in templates (see [docs/templates.md](templates.md)), but is available in handler code as well.

---

## Expression Syntax

Doot expressions support:

- **Method calls:** `post.title`, `result.ok?`, `posts.empty?`
- **String literals:** `"hello"`, `"posts/index"`
- **Integer literals:** `42`, `200`, `0`
- **Boolean literals:** `true`, `false`
- **Array literals:** `["admin", "editor", "member"]`
- **Comparisons:** `==`, `!=`, `>`, `<`, `>=`, `<=`
- **Boolean operators:** `&&`, `||`, `!`
- **String interpolation:** `"Hello #{name}"`
- **Nil:** `nil`
- **Predicate methods:** Convention of `?` suffix for boolean methods (e.g., `ok?`, `empty?`, `is_nil?`)

---

## Mount Directive

The `mount` directive in `app.do` includes routes from other `.do` files:

```
# app.do
mount "posts"
mount "comments"
mount "jobs"
```

`mount "posts"` includes all routes defined in `posts.do`. This keeps `app.do` focused on schema and configuration, while feature files contain their routes and handlers.

---

## CORS Configuration

CORS is denied by default (Rule 4: secure by default). To enable it, add a `cors` block to `app.do`:

```
config do
  port 3000
  session_secret env("SESSION_SECRET")

  cors do
    origin "https://myapp.com"
    methods ["GET", "POST", "PUT", "DELETE"]
    headers ["Content-Type", "Authorization"]
  end
end
```

If no `cors` block is present, all cross-origin requests are rejected.

---

## Sessions

Sessions use a signed session-ID cookie with server-side storage in SQLite.

- The cookie contains only a signed session ID (not the session data itself)
- Actual session data is stored in an auto-managed SQLite table
- No external store (no Redis, consistent with Rule 2)
- No cookie-size limits to worry about

### API

```
ctx.session.get("key")           # Read a value
ctx.session.set("key", "value")  # Write a value
ctx.session.delete("key")        # Remove a value
```

### Example

```
route POST "/settings/theme" do |ctx|
  ctx.session.set("theme", ctx.form["theme"])
  redirect "/settings"
end

route GET "/settings" do |ctx|
  theme = ctx.session.get("theme")
  render "settings", theme: theme
end
```

---

## Error Handling

### Auto-404 on Nil

When `db.<table>.find(id)` or `db.<table>.find_by(...)` returns nil, a 404 response is automatically triggered. This eliminates repetitive nil-checking boilerplate:

```
# No need for explicit nil check - auto-404 if not found
route GET "/posts/:id", auth: public do |ctx|
  post = db.posts.find(ctx.params["id"])
  render "posts/show", post: post
end
```

Without this behavior, every handler would need:

```
# You do NOT need to write this - Doot handles it automatically
post = db.posts.find(ctx.params["id"])
if post == nil
  # return 404 somehow...
end
```

### Custom Error Pages

If `views/errors/404.do` exists, it is rendered automatically on 404. If `views/errors/500.do` exists, it is rendered on server errors. If neither exists, a default styled error page is shown.

No configuration required. Just create the file and it is used.

```
# views/errors/404.do
extends "layouts/base"

block title
  "Page Not Found"

block content
  h1 "404"
  p "The page you are looking for does not exist."
  a href="/" "Go home"
```

### Server Errors (500)

Unhandled errors in handlers produce a 500 response. If `views/errors/500.do` exists, it is rendered. Otherwise, a default error page is shown (with no internal details leaked to the user).

---

## File Uploads

File uploads are accessed via `ctx.file["field_name"]`:

```
route POST "/posts/:id/cover", auth: required do |ctx|
  post = db.posts.find(ctx.params["id"])
  file = ctx.file["cover_image"]

  result = db.posts.update(post,
    cover_path: file.path
  )
  if result.ok?
    redirect "/posts/#{post.id}"
  end
end
```

### Upload Behavior

- Files are saved to the `uploads/` directory on local disk
- `file.filename` contains the original filename
- `file.path` contains the path on the server
- v1 supports local disk only (no S3, no cloud storage)
- The `uploads/` directory should be in `.gitignore`

### Form Example

In a template, a file upload form looks like:

```
form method="post" action="/posts/#{post.id}/cover" enctype="multipart/form-data"
  input type="file" name="cover_image"
  button type="submit" "Upload"
```

---

## Jobs and Scheduling

### Defining Jobs

```
# jobs.do
job "send_welcome_email" do |payload|
  user = db.users.find(payload["user_id"])
  email.send(
    to: user.email,
    subject: "Welcome!",
    template: "emails/welcome",
    user: user
  )
end
```

### Enqueuing Jobs

From any handler:

```
enqueue "send_welcome_email", user_id: user.id
```

### Scheduled Jobs

```
schedule "daily_cleanup", every: "1 day", at: "03:00" do
  old_sessions = db.sessions.all(where: "updated_at < date('now', '-30 days')")
  each session in old_sessions
    db.sessions.delete(session)
  end
end
```

Jobs are stored in a SQLite table and processed by an in-process worker pool. No external queue, no Redis, no separate worker process.

---

## Complete Example

A feature file showing the full range of DSL features:

```
# posts.do

group auth: required do
  route GET "/posts/new" do |ctx|
    render "posts/new"
  end

  route POST "/posts" do |ctx|
    result = db.posts.create(
      title: ctx.form["title"],
      body: ctx.form["body"],
      slug: slugify(ctx.form["title"]),
      published: false,
      user_id: ctx.current_user.id
    )
    if result.ok?
      redirect "/posts/#{result.post.slug}"
    else
      render "posts/new", errors: result.errors
    end
  end

  route PUT "/posts/:id" do |ctx|
    post = db.posts.find(ctx.params["id"])
    result = db.posts.update(post,
      title: ctx.form["title"],
      body: ctx.form["body"]
    )
    if result.ok?
      redirect "/posts/#{post.id}"
    else
      render "posts/edit", post: post, errors: result.errors
    end
  end

  route DELETE "/posts/:id" do |ctx|
    post = db.posts.find(ctx.params["id"])
    db.posts.delete(post)
    redirect "/posts"
  end

  route POST "/posts/:id/publish", role: "admin" do |ctx|
    post = db.posts.find(ctx.params["id"])
    db.posts.update(post, published: true)
    redirect "/posts/#{post.id}"
  end
end

route GET "/posts", auth: public do |ctx|
  posts = db.posts.all(
    where: "published = true",
    order: "created_at desc",
    limit: 20
  )
  render "posts/index", posts: posts
end

route GET "/posts/:slug", auth: public do |ctx|
  post = db.posts.find_by(slug: ctx.params["slug"])
  comments = db.comments.all(
    where: "post_id = #{post.id}",
    order: "created_at asc"
  )
  render "posts/show", post: post, comments: comments
end
```

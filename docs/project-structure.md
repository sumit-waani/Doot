# Project Structure

Doot uses a **feature-fused** directory layout. Routes, handlers, and database queries for a feature live together in a single file, not scattered across separate `controllers/`, `models/`, and `views/` directories. This document describes the canonical directory layout, what each file and directory is for, and the conventions that keep a Doot project organized.

---

## Canonical Directory Layout

```
my-app/
├── app.do                  # Entry point: schema, config, mounts
├── posts.do                # Routes + handlers for the "posts" feature
├── comments.do             # Routes + handlers for the "comments" feature
├── jobs.do                 # Background job definitions
├── helpers.do              # Shared utility functions
├── views/
│   ├── layouts/
│   │   └── base.do         # Base layout (extends target)
│   ├── posts/
│   │   ├── index.do        # List view for posts
│   │   ├── show.do         # Single post view
│   │   └── new.do          # New post form
│   ├── comments/
│   │   └── _form.do        # Partial: comment form
│   ├── errors/
│   │   ├── 404.do          # Custom 404 page (optional)
│   │   └── 500.do          # Custom 500 page (optional)
│   └── partials/
│       ├── nav.do          # Shared navigation partial
│       └── footer.do       # Shared footer partial
├── static/
│   ├── app.css             # Stylesheet
│   ├── app.js              # Client-side JavaScript (if needed)
│   ├── favicon.ico         # Favicon
│   └── images/
│       └── logo.png        # Static images
├── uploads/                # User-uploaded files (local disk, v1)
├── migrations/
│   ├── 001_create_posts.sql
│   └── 002_add_comments.sql
├── .env                    # Secrets and environment variables
└── .gitignore
```

---

## File-by-File Explanation

### `app.do` - Entry Point

The root file of every Doot project. It contains:

- **Schema declarations** - All database tables and their fields
- **App-level configuration** - Port, session secret (via `.env` reference), CORS rules
- **Auth configuration** - User model, roles, email verification settings
- **Mounts** - References to other `.do` files that contain routes

```
# app.do

config do
  port 3000
  session_secret env("SESSION_SECRET")
end

schema do
  auth :users do
    roles ["admin", "member"]
  end

  table "posts" do
    field "title", :string, required: true, max: 200
    field "body", :text, required: true
    field "published", :boolean, default: false
    field "user_id", :integer, required: true
    timestamps
  end

  table "comments" do
    field "body", :text, required: true
    field "post_id", :integer, required: true
    field "user_id", :integer, required: true
    timestamps
  end
end

mount "posts"
mount "comments"
mount "jobs"
```

The schema lives in `app.do` because it is a declarative, app-level concern on the same tier as configuration. There is no separate `db/schema.do` or `models/` directory.

### Feature Files (`posts.do`, `comments.do`, etc.)

Each feature file contains all the routes and handlers for one logical feature. A feature file is self-contained: you can read `posts.do` and understand everything about how posts work in the application.

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
      user_id: ctx.current_user.id
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

Key characteristics:

- Route registration is flat/top-level. No controller classes.
- `group` blocks apply shared settings (auth, roles) to multiple routes.
- Database queries use the auto-generated `db.<table>.*` interface.
- `render` passes explicit local variables to templates. No implicit instance-variable leakage.
- `db.posts.find(id)` returning nil automatically triggers a 404 response.

### `jobs.do` - Background Jobs

Defines background job handlers and scheduled tasks:

```
# jobs.do

job "send_welcome_email" do |payload|
  user = db.users.find(payload["user_id"])
  email.send(
    to: user.email,
    subject: "Welcome to the app!",
    template: "emails/welcome",
    user: user
  )
end

schedule "daily_digest", every: "1 day", at: "09:00" do
  users = db.users.all(where: "digest_enabled = true")
  each user in users
    enqueue "send_digest", user_id: user.id
  end
end
```

### `helpers.do` - Shared Utilities

Contains functions that are reused across multiple feature files:

```
# helpers.do

def slugify(text)
  text.downcase.gsub(/[^a-z0-9]+/, "-").trim("-")
end

def truncate(text, length: 100)
  if text.length > length
    text[0..length] + "..."
  else
    text
  end
end
```

This is the designated place for shared logic. There is no generic "shared model layer" or "service objects" pattern. If a pattern repeats across features, it goes in `helpers.do`.

### `views/` - Templates

Views are separated from routes because layout inheritance and partials are a genuinely cross-cutting concern that benefits from file separation.

#### `views/layouts/base.do`

The base layout that other views extend:

```
doctype html
html
  head
    title= block title || "My App"
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
      p "Built with Doot"
```

#### `views/posts/index.do`

A feature-specific view:

```
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
        p= truncate(post.body, length: 150)
```

#### `views/errors/404.do` and `views/errors/500.do`

Optional custom error pages. If these files exist, they are used automatically when a 404 or 500 occurs. If they do not exist, a default styled error page is rendered. No configuration needed either way.

#### Partials

Files prefixed with `_` (underscore) are partials. They are included in other templates but never rendered directly as a page:

```
# views/comments/_form.do
form method="post" action="/posts/#{post.id}/comments"
  textarea name="body" placeholder="Write a comment..." required=""
  button type="submit" "Post Comment"
```

Used from another template:

```
partial "comments/form", post: post
```

### `static/` - Static Assets

CSS, JavaScript, images, fonts, and any other static files. Served directly by the Doot runtime with gzip compression at serve time.

- No bundler. No minification pipeline in v1.
- No Webpack, no Vite, no esbuild.
- Files are served as-is. The "serve-as-is" philosophy keeps the toolchain simple.
- HTMX is embedded in the binary and served automatically; it does not need to be in `static/`.

### `uploads/` - User Uploads

Files uploaded by users via forms (`ctx.file["field"]`). Stored on local disk only in v1.

- No S3 integration in v1. Not even as an option.
- S3-compatible storage is a post-v1 concern, documented as an exception (similar to the escape hatch: available eventually, not encouraged).
- The `uploads/` directory should be in `.gitignore`.

### `migrations/` - Schema Migrations

Auto-generated migration files that track schema changes over time.

- Generated automatically when `doot dev` detects a schema change in `app.do`
- Committed to git (they are part of the project's source history)
- Applied by `dootd` on production deploy
- Same migration system for dev and prod (one path, Rule 3)
- Additive changes (new table, new column) auto-apply
- Destructive changes (rename, drop) require explicit confirmation

### `.env` - Environment Variables

All secrets and credentials live here. Never hardcoded in `.do` files.

```
SESSION_SECRET=a-long-random-string
SMTP_HOST=smtp.example.com
SMTP_USER=noreply@example.com
SMTP_PASS=password123
```

- Referenced in `app.do` via `env("KEY")`
- If a required env var is missing, the app fails fast at deploy time (never at runtime)
- Must be in `.gitignore` (never committed to version control)
- `dootd` validates required env vars before starting a deploy

### `.gitignore`

A Doot project's `.gitignore` should include:

```
.env
uploads/
*.db
```

---

## Feature-Fused vs. MVC

### Why NOT classic MVC

In a traditional MVC framework, a single feature (e.g., "posts") is scattered across:

```
# Classic MVC layout (NOT what Doot uses)
app/
├── controllers/
│   └── posts_controller.rb      # Route handlers
├── models/
│   └── post.rb                  # Data model + validations
├── views/
│   └── posts/
│       ├── index.html.erb
│       └── show.html.erb
├── config/
│   └── routes.rb                # Route definitions (separate from handlers!)
└── db/
    └── migrations/
        └── 001_create_posts.rb  # Schema (separate from model!)
```

To understand "how do posts work?", you must read 4-5 files across 4-5 directories. For a small app (the kind Doot targets), this separation creates overhead without benefit.

### Doot's feature-fused approach

```
# Doot layout
app.do              # Schema (all tables together, declarative)
posts.do            # Routes + handlers + queries (one file, one feature)
views/posts/        # Templates (separated because layout inheritance is cross-cutting)
```

To understand "how do posts work?", you read `posts.do`. Routes, handlers, and database queries are all in one place. The schema is in `app.do` because it is a global concern (tables reference each other, and the auto-generated query interface is app-wide).

Views remain separate because:

- Layout inheritance (`extends`) is inherently cross-cutting
- Partials are shared across features
- Template files have different syntax (Pug-style) than route files
- Separating presentation from logic is a genuine benefit even in small apps

### When feature-fused works

Feature-fused is ideal when:

- Features are relatively independent (posts, comments, users)
- Each feature has a small number of routes (2-10)
- The app is small enough that one person can hold it in their head
- An AI agent needs to generate or modify a feature without touching unrelated code

### Shared logic across features

If a query or function is reused across multiple feature files, it goes in `helpers.do`. There is no generic "shared model layer" invented speculatively. This is a deliberate choice: premature abstraction is avoided until a real, repeated pattern is observed.

---

## Naming Conventions

| Item | Convention | Example |
|------|-----------|---------|
| Feature files | Plural noun, snake_case | `posts.do`, `user_profiles.do` |
| View directories | Match feature file name | `views/posts/`, `views/user_profiles/` |
| View files | Action name, snake_case | `index.do`, `show.do`, `new.do`, `edit.do` |
| Partials | Prefixed with underscore | `_form.do`, `_card.do` |
| Layouts | Descriptive name | `base.do`, `admin.do` |
| Database tables | Plural, snake_case | `"posts"`, `"user_profiles"` |
| Database fields | Singular, snake_case | `"title"`, `"created_at"`, `"user_id"` |
| Migration files | Sequential number + description | `001_create_posts.sql`, `002_add_comments.sql` |
| Helpers | Verb or descriptive name | `slugify`, `truncate`, `format_date` |
| Job names | Verb phrase, snake_case | `"send_welcome_email"`, `"generate_report"` |
| Environment variables | UPPER_SNAKE_CASE | `SESSION_SECRET`, `SMTP_HOST` |

---

## Concrete Example: A Blog Application

Here is a complete, minimal blog application to illustrate how the pieces fit together:

```
my-blog/
├── app.do
├── posts.do
├── comments.do
├── jobs.do
├── helpers.do
├── views/
│   ├── layouts/
│   │   └── base.do
│   ├── posts/
│   │   ├── index.do
│   │   ├── show.do
│   │   └── new.do
│   ├── comments/
│   │   └── _form.do
│   └── partials/
│       └── nav.do
├── static/
│   ├── app.css
│   └── favicon.ico
├── migrations/
├── .env
└── .gitignore
```

**`app.do`** defines the schema for all tables, configures the app, and mounts feature files:

```
config do
  port 3000
  session_secret env("SESSION_SECRET")
end

schema do
  auth :users do
    roles ["admin", "member"]
  end

  table "posts" do
    field "title", :string, required: true, max: 200
    field "body", :text, required: true
    field "slug", :string, required: true
    field "published", :boolean, default: false
    field "user_id", :integer, required: true
    timestamps
  end

  table "comments" do
    field "body", :text, required: true, max: 1000
    field "post_id", :integer, required: true
    field "user_id", :integer, required: true
    timestamps
  end
end

mount "posts"
mount "comments"
mount "jobs"
```

**`posts.do`** handles all post-related routes:

```
group auth: required do
  route GET "/posts/new" do |ctx|
    render "posts/new"
  end

  route POST "/posts" do |ctx|
    result = db.posts.create(
      title: ctx.form["title"],
      body: ctx.form["body"],
      slug: slugify(ctx.form["title"]),
      user_id: ctx.current_user.id
    )
    if result.ok?
      redirect "/posts/#{result.post.slug}"
    else
      render "posts/new", errors: result.errors
    end
  end
end

route GET "/", auth: public do |ctx|
  posts = db.posts.all(where: "published = true", order: "created_at desc")
  render "posts/index", posts: posts
end

route GET "/posts/:slug", auth: public do |ctx|
  post = db.posts.find_by(slug: ctx.params["slug"])
  comments = db.comments.all(where: "post_id = #{post.id}", order: "created_at asc")
  render "posts/show", post: post, comments: comments
end
```

This example shows the full pattern: schema in `app.do`, features in their own files, views in matching directories, static assets served as-is, secrets in `.env`, migrations auto-generated.

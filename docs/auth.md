# Authentication

Auth is fully built-in to Doot. It is not a library, not a plugin, and not something the user or an AI agent assembles from primitives. This is the one area where Doot is maximally opinionated, because auth is the highest-risk part of any web application.

---

## Philosophy

Authentication is judged too dangerous to leave to user or agent discretion. The failure modes are severe: plaintext passwords, weak session handling, missing expiry, timing attacks, cookie misconfiguration. Even experienced developers routinely get auth wrong.

Doot eliminates this risk by providing a complete, correct auth system that ships with every application. The user declares *what* they need (users, roles, email verification), and Doot handles *how* it works (hashing, sessions, cookies, route protection).

### What Auth Handles

- User registration and login
- Password hashing and verification
- Session creation and management
- Route-level access control
- Role-based authorization
- Email verification (optional)

### What Auth Does Not Handle

Profile data (name, avatar, preferences, bio, settings) is **not** part of the auth system. That is normal application data, stored in regular schema tables. Auth handles identity and credentials only.

---

## Schema Declaration

Auth is declared in the `schema do ... end` block in `app.do`:

```
schema do
  auth :users do
    roles ["admin", "editor", "member"]   # optional: omit for plain auth without roles
    email_verification true               # optional: false by default
  end
end
```

### Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `roles` | Array of strings | None (no roles) | Defines available roles for role-based access control |
| `email_verification` | Boolean | `false` | Enables email verification flow on signup |

### Minimal Declaration

For simple apps that just need login/signup without roles:

```
schema do
  auth :users do
  end
end
```

This gives you the full auth system (signup, login, logout, session management, route protection) without roles or email verification.

---

## Built-in Routes

Declaring `auth :users` automatically generates these routes:

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/signup` | Create a new user account |
| `POST` | `/login` | Authenticate and create a session |
| `POST` | `/logout` | Destroy the current session |

These routes are functional out of the box. The user does not need to write handlers for them.

### Overriding Built-in Routes

If you need custom behavior (e.g., extra fields on signup, custom redirect after login), you can override any of these routes by declaring them explicitly in your `.do` files. The explicit declaration takes precedence over the built-in.

```
route POST "/signup" do |ctx|
  # Custom signup logic
  # You still have access to the built-in auth helpers
  result = auth.create_user(
    email: ctx.form["email"],
    password: ctx.form["password"]
  )
  if result.ok?
    auth.login(ctx, result.user)
    redirect "/welcome"
  else
    render "auth/signup", errors: result.errors
  end
end
```

---

## Password Hashing

All password hashing is handled internally by Doot. The user never interacts with hashing directly.

- **Algorithm**: argon2 (preferred) or bcrypt (fallback)
- **Configuration**: None required. Doot uses secure defaults.
- **Storage**: Hashed passwords are stored in the auto-managed users table
- **Verification**: Handled automatically during login

The user never sees a hash, never configures rounds/iterations, never calls a hashing function. This is invisible infrastructure.

---

## Session Management

Doot uses server-side sessions with signed cookies.

### How It Works

1. On successful login, Doot generates a unique session ID
2. The session ID is stored in a **signed cookie** sent to the browser
3. Actual session data is stored **server-side in SQLite** (auto-managed table, separate from user schema)
4. On each request, the cookie is verified and session data is loaded

### Why Server-Side Sessions

- **Consistent with Rule 2**: SQLite only, no external session store (no Redis, no Memcached)
- **No cookie-size limits**: Session data can grow without browser constraints
- **Secure by default**: Only a signed, opaque session ID is sent to the client
- **Auto-managed**: The session table is created and maintained automatically, invisible to the user

### Session Data

Session data is available via `ctx.session`:

```
route POST "/preferences" do |ctx|
  ctx.session.set("theme", ctx.form["theme"])
  redirect "/settings"
end

route GET "/settings" do |ctx|
  theme = ctx.session.get("theme")
  render "settings/index", theme: theme
end
```

| Method | Description |
|--------|-------------|
| `ctx.session.get(key)` | Retrieve a session value (returns nil if not set) |
| `ctx.session.set(key, value)` | Store a value in the session |
| `ctx.session.delete(key)` | Remove a value from the session |

---

## `ctx.current_user`

Every request handler has access to `ctx.current_user`. This is the authenticated user object for the current session.

### Behavior

- Inside `auth: required` scopes: **guaranteed non-nil**. You can access `ctx.current_user` without nil checks.
- Inside `auth: public` scopes: **may be nil**. The user might or might not be logged in.

```
route GET "/dashboard", auth: required do |ctx|
  # ctx.current_user is guaranteed to exist here
  posts = db.posts.all(where: "user_id = #{ctx.current_user.id}")
  render "dashboard/index", posts: posts, user: ctx.current_user
end

route GET "/", auth: public do |ctx|
  # ctx.current_user might be nil here
  if ctx.current_user
    render "home/logged_in", user: ctx.current_user
  else
    render "home/guest"
  end
end
```

### Available Fields

`ctx.current_user` provides:

| Field | Type | Description |
|-------|------|-------------|
| `.id` | Integer | Unique user identifier |
| `.email` | String | User's email address |
| `.role` | String or nil | User's role (if roles are configured) |
| `.created_at` | DateTime | Account creation timestamp |

---

## Route-Level Auth

Auth requirements are declared directly on routes.

### `auth: required` (Default)

All routes require authentication **by default**. If you forget to specify auth, the route is inaccessible without login. This is Rule 4 (secure/deny by default) applied to routing.

```
# These two declarations are equivalent:
route GET "/dashboard" do |ctx| ... end
route GET "/dashboard", auth: required do |ctx| ... end
```

Both require the user to be logged in. If not authenticated, the request returns a 401 response.

### `auth: public`

To make a route accessible without login, you must **explicitly** declare it public:

```
route GET "/", auth: public do |ctx|
  render "home/index"
end

route GET "/about", auth: public do |ctx|
  render "pages/about"
end
```

This is a conscious opt-in. The default deny posture means forgetting `auth: public` results in "nobody can access this route" rather than "everybody can access this route."

### `role: "name"`

If roles are configured in the auth block, you can restrict routes to specific roles:

```
route GET "/admin/users", auth: required, role: "admin" do |ctx|
  users = db.users.all()
  render "admin/users", users: users
end
```

If the current user does not have the required role, the request returns a 403 response.

---

## Group-Level Auth

Auth requirements can be applied to a group of routes:

```
group auth: required do
  route GET "/posts/new" do |ctx|
    render "posts/new"
  end

  route POST "/posts" do |ctx|
    # ...
  end
end
```

### Group with Roles

```
group auth: required, role: "admin" do
  route GET "/admin/dashboard" do |ctx|
    render "admin/dashboard"
  end

  route GET "/admin/users" do |ctx|
    users = db.users.all()
    render "admin/users", users: users
  end

  route DELETE "/admin/users/:id" do |ctx|
    user = db.users.find(ctx.params["id"])
    db.users.delete(user)
    redirect "/admin/users"
  end
end
```

All routes within the group inherit the auth and role requirements. Individual routes can still override:

```
group auth: required do
  route GET "/posts", auth: public do |ctx|
    # This route is public despite being in an auth: required group
    posts = db.posts.all()
    render "posts/index", posts: posts
  end

  route POST "/posts" do |ctx|
    # This route inherits auth: required from the group
    # ...
  end
end
```

---

## Default Deny Posture

This is one of the most important design decisions in Doot's auth system:

> **If a route's auth is forgotten, the failure mode is "nobody can access it," never "everybody can access it."**

### How It Works

- `auth: required` is the **implicit default** for every route
- A route without any auth declaration behaves as `auth: required`
- The only way to make a route public is to explicitly write `auth: public`

### Why This Matters

In most frameworks, forgetting auth on a route means the route is open to the world. This is a common source of security vulnerabilities: a developer adds a new endpoint, forgets to add the auth middleware, and the endpoint is exposed.

Doot inverts this. The safe behavior is the default. You must consciously decide to make something public. This is especially important when an AI agent is writing code: the agent cannot accidentally create an unprotected endpoint by omitting a decorator or middleware call.

---

## Email Verification

Optional. Enabled by setting `email_verification true` in the auth block.

### Requirements

Email verification requires SMTP configuration in `.env`:

```
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USER=your-email@example.com
SMTP_PASSWORD=your-smtp-password
```

If `email_verification: true` is set but SMTP variables are missing, the app fails fast at deploy time (Rule 4: fail-fast, never silently broken at runtime).

### Flow

1. User signs up via `POST /signup`
2. Account is created but marked as unverified
3. A background job is enqueued to send the verification email (uses the built-in [jobs system](jobs-and-scheduler.md))
4. Email contains a signed verification link
5. User clicks the link, account is marked as verified

### Unverified Users

Unverified users can log in but may have restricted access depending on your route configuration. The verification status is available via `ctx.current_user.verified?`.

---

## Scope Boundaries

Auth has clear boundaries. It handles identity and credentials. Everything else is the user's responsibility.

### Auth handles:

- Email + password storage and verification
- Session lifecycle (create, validate, destroy)
- Role assignment and checking
- Email verification flow
- `ctx.current_user` population

### Auth does NOT handle:

- Profile data (name, avatar, bio) - use a regular schema table
- Preferences (theme, language, notifications) - use a regular schema table
- User relationships (following, friends) - use a regular schema table
- Profile pictures/uploads - use the file upload system
- Display names - use a regular schema table

The auth block manages the `users` table with only the fields needed for authentication. Any additional user data belongs in a separate table that references the user by ID:

```
schema do
  auth :users do
    roles ["admin", "member"]
  end

  table "profiles" do
    field "user_id", :integer, required: true
    field "display_name", :string, max: 100
    field "bio", :text
    field "avatar_url", :string
    timestamps
  end
end
```

---

## Password Reset

Core auth and email verification ship in v1. Broader account recovery flows (password reset via email link, account lockout after failed attempts, security questions) are partially deferred to post-v1.

The architecture supports password reset (it is a background job that sends an email with a signed token), but the full UX and edge cases are not fully specified for v1. This is noted honestly rather than shipped half-baked.

---

## Complete Example

```
# app.do
config do
  port 3000
  session_secret env("SESSION_SECRET")
end

schema do
  auth :users do
    roles ["admin", "member"]
    email_verification true
  end

  table "posts" do
    field "title", :string, required: true, max: 200
    field "body", :text, required: true
    field "user_id", :integer, required: true
    timestamps
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

group auth: required, role: "admin" do
  route DELETE "/posts/:id" do |ctx|
    post = db.posts.find(ctx.params["id"])
    db.posts.delete(post)
    redirect "/posts"
  end
end
```

In this example:

- All routes are protected by default
- Viewing posts is explicitly public (`auth: public`)
- Creating posts requires login (`auth: required` via group)
- Deleting posts requires the `admin` role
- `ctx.current_user` is guaranteed non-nil in all non-public routes
- Posts are associated with users via `user_id`

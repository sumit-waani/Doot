# Standard Library

Doot ships with a set of built-in functions and objects that cover common web application needs. These are available in all handlers and templates without any import or configuration. They are part of the DSL, not external packages.

---

## Design Principles

- **Web-focused.** Every function exists because web applications commonly need it. No general-purpose utilities that do not serve the web use case.
- **Predictable naming.** Functions use `snake_case`. Predicate methods end with `?`. No abbreviations that sacrifice clarity.
- **No external dependencies.** Everything compiles into the same binary. No npm packages, no nimble packages pulled at build time.
- **Nil-safe where possible.** Functions that receive nil return sensible defaults rather than crashing.

---

## String Helpers

### `truncate(text, length)`

Truncates a string to the specified length, appending "..." if truncated.

```
truncate("Hello World", 5)
# => "Hello..."

truncate("Hi", 10)
# => "Hi"
```

**Signature:** `truncate(text: String, length: Integer) -> String`

---

### `slugify(text)`

Converts a string to a URL-friendly slug (lowercase, hyphens, no special characters).

```
slugify("Hello World!")
# => "hello-world"

slugify("My Post: A Deep Dive")
# => "my-post-a-deep-dive"
```

**Signature:** `slugify(text: String) -> String`

---

### `capitalize(text)`

Capitalizes the first character of the string.

```
capitalize("hello")
# => "Hello"

capitalize("hello world")
# => "Hello world"
```

**Signature:** `capitalize(text: String) -> String`

---

### `downcase(text)`

Converts the entire string to lowercase.

```
downcase("Hello World")
# => "hello world"
```

**Signature:** `downcase(text: String) -> String`

---

### `upcase(text)`

Converts the entire string to uppercase.

```
upcase("hello")
# => "HELLO"
```

**Signature:** `upcase(text: String) -> String`

---

### `strip(text)`

Removes leading and trailing whitespace.

```
strip("  hello  ")
# => "hello"
```

**Signature:** `strip(text: String) -> String`

---

### `split(text, delimiter)`

Splits a string into an array by the given delimiter.

```
split("a,b,c", ",")
# => ["a", "b", "c"]

split("hello world", " ")
# => ["hello", "world"]
```

**Signature:** `split(text: String, delimiter: String) -> Array<String>`

---

### `join(array, separator)`

Joins an array of strings with the given separator.

```
join(["a", "b", "c"], ", ")
# => "a, b, c"

join(["hello", "world"], " ")
# => "hello world"
```

**Signature:** `join(array: Array<String>, separator: String) -> String`

---

### `starts_with?(text, prefix)`

Returns true if the string starts with the given prefix.

```
starts_with?("hello world", "hello")
# => true

starts_with?("hello world", "world")
# => false
```

**Signature:** `starts_with?(text: String, prefix: String) -> Boolean`

---

### `ends_with?(text, suffix)`

Returns true if the string ends with the given suffix.

```
ends_with?("hello.pdf", ".pdf")
# => true

ends_with?("hello.pdf", ".txt")
# => false
```

**Signature:** `ends_with?(text: String, suffix: String) -> Boolean`

---

### `includes?(text, substring)`

Returns true if the string contains the given substring.

```
includes?("hello world", "world")
# => true

includes?("hello world", "xyz")
# => false
```

**Signature:** `includes?(text: String, substring: String) -> Boolean`

---

### `replace(text, target, replacement)`

Replaces the first occurrence of target with replacement.

```
replace("hello world", "world", "Doot")
# => "hello Doot"
```

**Signature:** `replace(text: String, target: String, replacement: String) -> String`

---

### `gsub(text, pattern, replacement)`

Replaces all occurrences of pattern with replacement.

```
gsub("hello world world", "world", "Doot")
# => "hello Doot Doot"

gsub("a-b-c", "-", "_")
# => "a_b_c"
```

**Signature:** `gsub(text: String, pattern: String, replacement: String) -> String`

---

### `length(text)`

Returns the number of characters in the string.

```
length("hello")
# => 5

length("")
# => 0
```

**Signature:** `length(text: String) -> Integer`

---

## Date and Time

### `now()`

Returns the current date and time.

```
current_time = now()
# => 2024-01-15 14:30:22
```

**Signature:** `now() -> DateTime`

---

### `format_date(datetime, format)`

Formats a datetime value into a string. Uses strftime-style format codes.

```
format_date(post.created_at, "%B %d, %Y")
# => "January 15, 2024"

format_date(post.created_at, "%Y-%m-%d")
# => "2024-01-15"

format_date(post.created_at, "%H:%M")
# => "14:30"
```

**Common format codes:**

| Code | Meaning | Example |
|------|---------|---------|
| `%Y` | 4-digit year | 2024 |
| `%m` | Month (01-12) | 01 |
| `%d` | Day (01-31) | 15 |
| `%H` | Hour, 24h (00-23) | 14 |
| `%M` | Minute (00-59) | 30 |
| `%S` | Second (00-59) | 22 |
| `%B` | Full month name | January |
| `%b` | Abbreviated month | Jan |
| `%A` | Full weekday name | Monday |

**Signature:** `format_date(datetime: DateTime, format: String) -> String`

---

### `parse_date(text, format)`

Parses a string into a datetime value using the specified format.

```
parse_date("2024-01-15", "%Y-%m-%d")
# => DateTime(2024, 1, 15)

parse_date("January 15, 2024", "%B %d, %Y")
# => DateTime(2024, 1, 15)
```

**Signature:** `parse_date(text: String, format: String) -> DateTime`

---

### `time_ago(datetime)`

Returns a human-friendly relative time string.

```
time_ago(post.created_at)
# => "5 minutes ago"
# => "2 hours ago"
# => "3 days ago"
# => "1 month ago"
```

**Signature:** `time_ago(datetime: DateTime) -> String`

---

### `add_days(datetime, days)`

Adds the specified number of days to a datetime.

```
tomorrow = add_days(now(), 1)
next_week = add_days(now(), 7)
last_week = add_days(now(), -7)
```

**Signature:** `add_days(datetime: DateTime, days: Integer) -> DateTime`

---

### `add_hours(datetime, hours)`

Adds the specified number of hours to a datetime.

```
in_two_hours = add_hours(now(), 2)
```

**Signature:** `add_hours(datetime: DateTime, hours: Integer) -> DateTime`

---

### `add_minutes(datetime, minutes)`

Adds the specified number of minutes to a datetime.

```
in_thirty_minutes = add_minutes(now(), 30)
```

**Signature:** `add_minutes(datetime: DateTime, minutes: Integer) -> DateTime`

---

### `date_diff(datetime1, datetime2)`

Returns the difference between two datetimes in seconds.

```
seconds = date_diff(now(), post.created_at)
# => 86400 (if post was created 1 day ago)
```

**Signature:** `date_diff(datetime1: DateTime, datetime2: DateTime) -> Integer`

---

## JSON

### `to_json(value)`

Converts a value (string, integer, boolean, array, or record) to a JSON string.

```
to_json(post)
# => '{"id":1,"title":"Hello","body":"World"}'

to_json(["a", "b", "c"])
# => '["a","b","c"]'

to_json({name: "Doot", version: 1})
# => '{"name":"Doot","version":1}'
```

**Signature:** `to_json(value: Any) -> String`

---

### `from_json(text)`

Parses a JSON string into a structured value.

```
data = from_json('{"name":"Doot","version":1}')
data["name"]
# => "Doot"
```

**Signature:** `from_json(text: String) -> Any`

---

## Logging

The `log` object provides structured logging at four levels. Log output goes to stdout/stderr and is visible in the `dootd` dashboard.

### `log.info(message)`

General informational messages.

```
log.info("User #{user.id} signed up")
log.info("Processing #{posts.count} posts")
```

**Signature:** `log.info(message: String) -> Nil`

---

### `log.warn(message)`

Warning conditions that are not errors but may indicate issues.

```
log.warn("Slow query detected: #{query_time}ms")
log.warn("Rate limit approaching for IP #{ctx.headers["X-Forwarded-For"]}")
```

**Signature:** `log.warn(message: String) -> Nil`

---

### `log.error(message)`

Error conditions that need attention.

```
log.error("Failed to send email to #{user.email}")
log.error("Payment webhook verification failed")
```

**Signature:** `log.error(message: String) -> Nil`

---

### `log.debug(message)`

Debug information, only visible in development mode.

```
log.debug("Handler params: #{to_json(ctx.params)}")
log.debug("Query returned #{results.count} rows")
```

**Signature:** `log.debug(message: String) -> Nil`

---

## HTTP Client

The `http` object provides functions for making outbound HTTP requests from handlers and jobs. Useful for webhooks, API integrations, and external service calls.

### `http.get(url, options)`

Makes an HTTP GET request.

```
response = http.get("https://api.example.com/data")
# response.status  => 200
# response.body    => '{"key": "value"}'
# response.headers => {"Content-Type": "application/json"}

response = http.get("https://api.example.com/data", 
  headers: {"Authorization": "Bearer #{env("API_KEY")}"},
  timeout: 5000
)
```

**Signature:** `http.get(url: String, options: Object?) -> HttpResponse`

---

### `http.post(url, options)`

Makes an HTTP POST request.

```
response = http.post("https://api.example.com/webhook",
  body: to_json({event: "user_signup", user_id: user.id}),
  headers: {"Content-Type": "application/json"},
  timeout: 10000
)
if response.status == 200
  log.info("Webhook delivered successfully")
end
```

**Signature:** `http.post(url: String, options: Object?) -> HttpResponse`

---

### `http.put(url, options)`

Makes an HTTP PUT request.

```
response = http.put("https://api.example.com/users/#{user.external_id}",
  body: to_json({name: user.name, email: user.email}),
  headers: {"Content-Type": "application/json"}
)
```

**Signature:** `http.put(url: String, options: Object?) -> HttpResponse`

---

### `http.delete(url, options)`

Makes an HTTP DELETE request.

```
response = http.delete("https://api.example.com/subscriptions/#{sub_id}",
  headers: {"Authorization": "Bearer #{env("API_KEY")}"}
)
```

**Signature:** `http.delete(url: String, options: Object?) -> HttpResponse`

---

### HTTP Options

| Option | Type | Description |
|--------|------|-------------|
| `headers` | Object | Key-value pairs of HTTP headers |
| `body` | String | Request body (typically JSON) |
| `timeout` | Integer | Timeout in milliseconds (default: 30000) |

### HTTP Response Object

| Property | Type | Description |
|----------|------|-------------|
| `response.status` | Integer | HTTP status code (200, 404, 500, etc.) |
| `response.body` | String | Response body text |
| `response.headers` | Object | Response headers |

---

## Email

### `email.send(options)`

Sends an email. Requires SMTP configuration in `.env` (`SMTP_HOST`, `SMTP_USER`, `SMTP_PASSWORD`).

```
email.send(
  to: user.email,
  subject: "Welcome to the app!",
  body: "Hello #{user.email}, thanks for signing up."
)

email.send(
  to: user.email,
  subject: "Your weekly digest",
  template: "emails/digest",
  user: user,
  posts: recent_posts
)

email.send(
  to: "admin@example.com",
  from: "noreply@myapp.com",
  subject: "New signup: #{user.email}",
  body: "A new user signed up: #{user.email}"
)
```

**Signature:** `email.send(options: Object) -> Nil`

### Email Options

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `to` | String | Yes | Recipient email address |
| `subject` | String | Yes | Email subject line |
| `body` | String | No* | Plain text email body |
| `template` | String | No* | Path to an email template (relative to `views/`) |
| `from` | String | No | Sender address (defaults to SMTP_USER from `.env`) |

*Either `body` or `template` must be provided. If `template` is used, additional key-value pairs are passed as locals to the template.

### Email in Jobs

Email sending should typically be done in background jobs to avoid blocking the HTTP response:

```
# In a handler:
enqueue "send_welcome_email", user_id: user.id

# In jobs.do:
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

---

## Crypto and Security

### `hash(value, algorithm)`

Produces a one-way hash of the given value. Not for passwords (use the built-in auth system for that).

```
hash("some data", "sha256")
# => "a1b2c3d4..."

hash(payload, "sha256")
```

**Signature:** `hash(value: String, algorithm: String) -> String`

Supported algorithms: `"sha256"`, `"sha512"`, `"md5"` (md5 not recommended for security use).

---

### `hmac(value, key, algorithm)`

Produces an HMAC (Hash-based Message Authentication Code). Useful for webhook signature verification.

```
expected_sig = ctx.headers["X-Webhook-Signature"]
computed_sig = hmac(ctx.body, env("WEBHOOK_SECRET"), "sha256")

if secure_compare(expected_sig, computed_sig)
  # signature valid
end
```

**Signature:** `hmac(value: String, key: String, algorithm: String) -> String`

---

### `random_token(length)`

Generates a cryptographically secure random token string.

```
token = random_token(32)
# => "k3x9p2mNq8vL7bY1wR4tHjF6sD0cA5nZ"

reset_token = random_token(64)
```

**Signature:** `random_token(length: Integer) -> String`

---

### `secure_compare(a, b)`

Constant-time string comparison to prevent timing attacks. Use this instead of `==` when comparing secrets, signatures, or tokens.

```
if secure_compare(provided_token, stored_token)
  # tokens match
end

if secure_compare(computed_hmac, received_hmac)
  # signature verified
end
```

**Signature:** `secure_compare(a: String, b: String) -> Boolean`

---

## Type Checking and Conversion

### `is_nil?(value)`

Returns true if the value is nil.

```
if is_nil?(ctx.query["page"])
  page = 1
else
  page = to_i(ctx.query["page"])
end
```

**Signature:** `is_nil?(value: Any) -> Boolean`

---

### `is_empty?(value)`

Returns true if the value is nil, an empty string, or an empty collection.

```
if is_empty?(ctx.form["title"])
  # handle missing title
end

if is_empty?(posts)
  render "posts/empty"
end
```

**Signature:** `is_empty?(value: Any) -> Boolean`

---

### `to_i(value)`

Converts a value to an integer. Returns 0 if conversion fails.

```
page = to_i(ctx.query["page"])
# "5" => 5
# nil => 0
# "abc" => 0
```

**Signature:** `to_i(value: Any) -> Integer`

---

### `to_f(value)`

Converts a value to a float. Returns 0.0 if conversion fails.

```
price = to_f(ctx.form["price"])
# "19.99" => 19.99
# nil => 0.0
```

**Signature:** `to_f(value: Any) -> Float`

---

### `to_s(value)`

Converts a value to its string representation.

```
to_s(42)
# => "42"

to_s(true)
# => "true"

to_s(nil)
# => ""
```

**Signature:** `to_s(value: Any) -> String`

---

## Collections

### `map(collection, property)`

Extracts a property from each item in a collection, returning a new array.

```
titles = map(posts, "title")
# => ["First Post", "Second Post", "Third Post"]

ids = map(users, "id")
# => [1, 2, 3]
```

**Signature:** `map(collection: Array, property: String) -> Array`

---

### `filter(collection, property, value)`

Returns items where the property matches the given value.

```
published = filter(posts, "published", true)
admins = filter(users, "role", "admin")
```

**Signature:** `filter(collection: Array, property: String, value: Any) -> Array`

---

### `first(collection)`

Returns the first item of a collection, or nil if empty.

```
latest = first(posts)
```

**Signature:** `first(collection: Array) -> Any`

---

### `last(collection)`

Returns the last item of a collection, or nil if empty.

```
oldest = last(posts)
```

**Signature:** `last(collection: Array) -> Any`

---

### `count(collection)`

Returns the number of items in a collection.

```
total = count(posts)
# => 42
```

**Signature:** `count(collection: Array) -> Integer`

---

### `sort_by(collection, property)`

Returns a new array sorted by the given property (ascending).

```
sorted = sort_by(posts, "title")
by_date = sort_by(posts, "created_at")
```

**Signature:** `sort_by(collection: Array, property: String) -> Array`

---

### `group_by(collection, property)`

Groups items by the given property, returning an object with property values as keys and arrays as values.

```
by_role = group_by(users, "role")
# => {"admin": [...], "member": [...], "editor": [...]}

by_status = group_by(posts, "published")
# => {true: [...], false: [...]}
```

**Signature:** `group_by(collection: Array, property: String) -> Object`

---

### `flatten(collection)`

Flattens a nested array one level deep.

```
flatten([[1, 2], [3, 4], [5]])
# => [1, 2, 3, 4, 5]
```

**Signature:** `flatten(collection: Array) -> Array`

---

### `compact(collection)`

Removes nil values from a collection.

```
compact([1, nil, 2, nil, 3])
# => [1, 2, 3]
```

**Signature:** `compact(collection: Array) -> Array`

---

## URL Helpers

### `url_encode(text)`

Percent-encodes a string for use in URLs.

```
url_encode("hello world")
# => "hello%20world"

url_encode("a=b&c=d")
# => "a%3Db%26c%3Dd"
```

**Signature:** `url_encode(text: String) -> String`

---

### `url_decode(text)`

Decodes a percent-encoded URL string.

```
url_decode("hello%20world")
# => "hello world"
```

**Signature:** `url_decode(text: String) -> String`

---

### `path_for(route_path, params)`

Generates a URL path with parameters substituted.

```
path_for("/posts/:id", id: post.id)
# => "/posts/42"

path_for("/users/:user_id/posts/:id", user_id: user.id, id: post.id)
# => "/users/7/posts/42"
```

**Signature:** `path_for(route_path: String, params: Object) -> String`

---

## Summary

| Category | Functions | Count |
|----------|-----------|-------|
| String helpers | `truncate`, `slugify`, `capitalize`, `downcase`, `upcase`, `strip`, `split`, `join`, `starts_with?`, `ends_with?`, `includes?`, `replace`, `gsub`, `length` | 14 |
| Date/time | `now`, `format_date`, `parse_date`, `time_ago`, `add_days`, `add_hours`, `add_minutes`, `date_diff` | 8 |
| JSON | `to_json`, `from_json` | 2 |
| Logging | `log.info`, `log.warn`, `log.error`, `log.debug` | 4 |
| HTTP client | `http.get`, `http.post`, `http.put`, `http.delete` | 4 |
| Email | `email.send` | 1 |
| Crypto/security | `hash`, `hmac`, `random_token`, `secure_compare` | 4 |
| Type checking/conversion | `is_nil?`, `is_empty?`, `to_i`, `to_f`, `to_s` | 5 |
| Collections | `map`, `filter`, `first`, `last`, `count`, `sort_by`, `group_by`, `flatten`, `compact` | 9 |
| URL helpers | `url_encode`, `url_decode`, `path_for` | 3 |
| **Total** | | **54** |

All functions are available everywhere (handlers, jobs, templates) without import. They compile into the binary as part of the Doot runtime.

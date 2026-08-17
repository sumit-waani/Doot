# Escape Hatch

> **This page documents an advanced feature intended for rare use cases.** If you are new to Doot, you likely do not need this. The DSL is designed to cover the vast majority of web application needs without ever touching the escape hatch.

---

## Overview

Doot's `native do ... end` block provides full, unrestricted access to the Nim standard library from within a Doot handler. It exists because no DSL can anticipate every possible requirement, but it is deliberately designed to be the path of last resort, not the path of least resistance.

**Core principle:** Doot should never be blamed for what happens inside the escape hatch. Doot's job is to make the escape hatch unnecessary as often as possible through strong, opinionated defaults. Once you step outside the DSL, you are responsible for what happens.

---

## Syntax

```
native do
  # Full Nim code here
end
```

The `native do ... end` block is placed inside a route handler (or job handler) at the point where you need to drop into raw Nim:

```
route POST "/posts/:id/export-pdf", auth: required do |ctx|
  post = db.posts.find(ctx.params["id"])

  native do
    # Full, unrestricted Nim - entire stdlib available, no whitelist/sandbox.
    # ctx, db, and other DSL-scope values are accessible here.
    import std/strformat
    let pdfBytes = generatePdfFromHtml(post.body)
    ctx.sendFile(pdfBytes, "application/pdf", filename=fmt"{post.title}.pdf")
  end
end
```

---

## Keyword Choice

The keyword is `native do ... end`. This is verbose by design.

- It is not `nim { }` or `raw()` or any short/tempting syntax
- The verbosity creates friction: typing `native do ... end` is a small but deliberate reminder that you are stepping outside the DSL
- This friction is intentional, not accidental. It signals "you are now responsible for this code in a way you are not responsible for DSL code"

The goal is that when you see `native do` in a codebase, it stands out visually. It is immediately obvious that something unusual is happening. This aids code review, debugging, and understanding the boundaries of Doot's guarantees.

---

## Scoping Rules

### Block-level only

The `native` keyword is scoped to a block inside a handler. It is never:

- An entire file written in raw Nim
- A file-level directive that switches a `.do` file to "Nim mode"
- A project-level setting

This constraint is absolute. You cannot write:

```
# THIS IS NOT VALID - file-level native is not allowed
native file

# ... raw Nim for the whole file ...
```

You must always wrap native code in a block within a handler:

```
# VALID - block-level inside a handler
route GET "/some-path", auth: required do |ctx|
  # DSL code above the native block
  name = ctx.params["name"]

  native do
    # Nim code here, scoped to this block
    let result = someComplexComputation(name)
    ctx.json({"result": result})
  end
end
```

### Why block-level only?

If file-level native blocks were allowed, the "just write the whole thing in Nim" failure mode would creep back in. The constraint keeps Doot applications primarily written in the DSL, with native code as isolated islands where genuinely needed.

---

## What Is Available Inside Native Blocks

### Full Nim Standard Library

Inside a `native do ... end` block, you have access to the entire Nim standard library without restriction. There is no whitelist, no sandbox, no artificial limitation on what Nim features you can use.

This includes:

- `std/os` - File system operations
- `std/net` - Low-level networking
- `std/httpclient` - HTTP client
- `std/json` - JSON parsing/generation
- `std/strformat` - String formatting
- `std/times` - Date/time operations
- `std/re` - Regular expressions
- `std/sequtils`, `std/tables`, `std/sets` - Collections
- Any other Nim standard library module
- C FFI via Nim's `importc` / `emit` pragmas

### DSL Primitives

All DSL primitives remain accessible inside native blocks. Dropping into raw Nim does not mean losing Doot's conveniences:

| Primitive | Available inside `native do`? | Notes |
|-----------|------|-------|
| `ctx` | Yes | Full request context (params, form, session, current_user, headers) |
| `db` | Yes | Auto-generated query interface for all schema tables |
| `session` | Yes | Read/write session data |
| `ctx.current_user` | Yes | Currently authenticated user (if in an auth-required scope) |
| `redirect` | Yes | Issue an HTTP redirect |
| `render` | No | Use `ctx.sendHtml()` or `ctx.json()` instead for custom responses |
| `enqueue` | Yes | Enqueue a background job |
| `email` | Yes | Send email via the built-in email primitive |

Example combining DSL primitives with native Nim code:

```
route GET "/reports/monthly", auth: required, role: "admin" do |ctx|
  posts = db.posts.all(where: "created_at > date('now', '-30 days')")

  native do
    import std/json
    import std/times
    import std/sequtils

    # Use Nim's stdlib for complex data transformation
    var report = %*{
      "generated_at": now().format("yyyy-MM-dd HH:mm:ss"),
      "total_posts": posts.len,
      "by_author": %*{}
    }

    for post in posts:
      let authorId = $post.user_id
      if not report["by_author"].hasKey(authorId):
        report["by_author"][authorId] = %*0
      report["by_author"][authorId] = %*(report["by_author"][authorId].getInt + 1)

    ctx.json(report)
  end
end
```

---

## When to Use the Escape Hatch

The escape hatch is appropriate when you need something the DSL genuinely cannot express:

### Legitimate use cases

- **Complex data transformations** that go beyond simple queries and template rendering (e.g., generating PDFs, CSV exports, image processing)
- **Custom cryptographic operations** beyond what the built-in auth system handles
- **Integration with C libraries** via Nim's FFI for specialized functionality
- **Complex algorithmic logic** that is awkward to express in the DSL's limited control flow
- **Binary file generation** (ZIP archives, custom file formats)
- **Low-level network operations** (WebSocket handling, custom protocols)

### NOT appropriate use cases

These are signs you should either use DSL features or graduate from Doot entirely:

- **Basic CRUD operations** - The DSL handles this natively. If you find yourself writing raw SQL in a native block, you probably missed a `db.<table>.*` method.
- **Custom auth flows** - The built-in auth system is comprehensive. If you need something radically different, consider whether Doot is the right tool.
- **Most of your handlers are native blocks** - If more than 10-20% of your routes need native blocks, the DSL is not serving your needs. Consider graduating to a full Nim/Rails/Laravel/Phoenix application.
- **Replacing DSL routing/middleware** - Do not reimplement routing or middleware in native blocks. The DSL's routing is the single path; working around it defeats the purpose.

---

## Limitations and Responsibilities

### What Doot guarantees inside native blocks

- DSL primitives (`ctx`, `db`, `session`) work as documented
- The native code is compiled as part of the same binary
- Errors in native code produce Nim compiler errors during the build step (not runtime surprises)

### What Doot does NOT guarantee inside native blocks

- **Memory safety beyond Nim's GC** - If you use `ptr` or `cast` or unsafe C FFI, that is on you.
- **Security** - Native code can bypass the DSL's secure-by-default behavior. You can accidentally serve unescaped HTML, expose data without auth checks, or introduce injection vulnerabilities. The DSL's protections end at the `native do` boundary.
- **Compatibility across Doot versions** - The internal Nim code generation may change between Doot versions. Native blocks that rely on internal implementation details (rather than the documented primitives) may break on upgrade.
- **Debugging support** - Doot's error messages are crafted for DSL code. Errors inside native blocks produce standard Nim compiler/runtime errors, which may be less clear.

### Your responsibilities

When you use a native block, you are expected to:

1. **Understand Nim** - At least enough to read error messages and debug your code.
2. **Handle your own security** - The DSL's auto-escaping and auth enforcement do not extend into native code unless you use the primitives correctly.
3. **Test native code paths** - Doot's future testing framework may not cover native block internals with the same ease as DSL code.
4. **Accept maintenance burden** - Native blocks are coupling to Nim's standard library. If Nim releases a breaking change in a module you use, that is your problem to fix.

---

## Documentation Placement Philosophy

This page intentionally lives at the end of the documentation, not in the getting-started guide, not in the tutorial, and not linked prominently from the homepage.

This is a deliberate choice:

- New users should not encounter the escape hatch until they have fully explored what the DSL offers
- The escape hatch should feel like a discovery ("oh, I can do that if I really need to") not an invitation ("here's how to bypass the DSL")
- AI agents generating Doot code should be instructed to use the escape hatch only as a last resort, after confirming the DSL cannot handle the requirement
- Code reviewers should treat `native do` blocks with the same scrutiny as `unsafe` blocks in Rust: correct usage is fine, but it warrants extra attention

---

## When to Graduate Instead

The escape hatch is for isolated, specific needs within an otherwise DSL-friendly application. It is NOT a way to gradually rewrite your Doot app in Nim.

**Consider graduating from Doot entirely when:**

- More than 10-20% of your route handlers contain `native do` blocks
- Your native blocks are growing to 50+ lines each
- You find yourself re-implementing DSL features (auth, routing, template rendering) in native code
- You need external dependencies (Nim packages via nimble) that the Doot runtime does not include
- Your application's core logic is inherently unsuited to the DSL's constraints

Graduating is not failure. It means your application has specific needs that a deliberately simple DSL cannot serve. See [docs/philosophy.md](philosophy.md#graduation-path) for guidance on where to go next.

---

## Complete Example

A handler that generates a CSV export of all posts, demonstrating a legitimate use of native code for file generation:

```
route GET "/admin/posts/export", auth: required, role: "admin" do |ctx|
  posts = db.posts.all(order: "created_at desc")

  native do
    import std/strformat
    import std/times
    import std/strutils

    var csv = "id,title,author_id,published,created_at\n"

    for post in posts:
      let title = post.title.replace("\"", "\"\"")  # Escape quotes for CSV
      csv.add(fmt"{post.id},\"{title}\",{post.user_id},{post.published},{post.created_at}" & "\n")

    let filename = fmt"posts-export-{now().format(\"yyyyMMdd\")}.csv"
    ctx.sendFile(csv, "text/csv", filename=filename)
  end
end
```

And a handler that does NOT need the escape hatch (showing the contrast):

```
# This does NOT need native do ... end
# The DSL handles it naturally
route GET "/posts/:id", auth: public do |ctx|
  post = db.posts.find(ctx.params["id"])
  comments = db.comments.all(where: "post_id = #{post.id}", order: "created_at asc")
  render "posts/show", post: post, comments: comments
end
```

The difference is clear: standard CRUD operations, database queries, and template rendering are the DSL's core competency. File generation with complex string manipulation is where the escape hatch earns its place.

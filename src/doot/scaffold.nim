## Project scaffolding for 'doot new <name>'.
## Creates directory structure with starter files.

import std/[os, strutils, sysrand]

type
  ScaffoldError* = object
    message*: string

proc isValidProjectName*(name: string): bool =
  ## Validates project name: alphanumeric + hyphens, no spaces,
  ## no leading/trailing hyphens, not empty.
  if name.len == 0:
    return false
  if name[0] == '-' or name[^1] == '-':
    return false
  for c in name:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '-'}:
      return false
  return true

proc generateSessionSecret*(): string =
  ## Generate a 32-byte random hex string for session secret.
  var bytes: array[32, byte]
  if not urandom(bytes):
    # Fallback: use a timestamp-based value (not cryptographically secure)
    return "CHANGE_ME_" & "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4"
  result = ""
  for b in bytes:
    result &= b.toHex(2).toLowerAscii()

proc generateAppDo*(): string =
  ## Generate the default app.do content.
  result = """# My App - Main Configuration

config do
  port 3000
  session_secret env("SESSION_SECRET")
end

schema do
  # Define your tables here
  # table "posts" do
  #   field "title", :string, required: true
  #   field "body", :text
  #   timestamps
  # end
end
"""

proc generateBaseLayout*(): string =
  ## Generate the default views/layouts/base.do content.
  result = """doctype html
html
  head
    title "My App"
    meta charset="utf-8"
    meta name="viewport" content="width=device-width, initial-scale=1"
    link rel="stylesheet" href="/static/app.css"
    block head
  body
    main.container
      block content
    footer
      p "Built with Doot"
"""

proc generateAppCss*(): string =
  ## Generate the starter stylesheet.
  result = """/* app.css - Starter stylesheet */
* {
  margin: 0;
  padding: 0;
  box-sizing: border-box;
}

body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  line-height: 1.6;
  color: #333;
  max-width: 800px;
  margin: 0 auto;
  padding: 2rem;
}

.container {
  width: 100%;
  max-width: 800px;
  margin: 0 auto;
  padding: 0 1rem;
}
"""

proc generateEnvFile*(secret: string): string =
  ## Generate .env file with session secret.
  result = "# Environment variables for your Doot app\n"
  result &= "# Do not commit this file to version control\n\n"
  result &= "SESSION_SECRET=" & secret & "\n"

proc generateEnvExample*(): string =
  ## Generate .env.example file.
  result = "# Environment variables template\n"
  result &= "# Copy this to .env and fill in your values\n\n"
  result &= "SESSION_SECRET=your_secret_here\n"

proc generateGitignore*(): string =
  ## Generate .gitignore file.
  result = "# Environment variables (secrets)\n"
  result &= ".env\n\n"
  result &= "# Build artifacts\n"
  result &= ".doot-build/\n\n"
  result &= "# User uploads\n"
  result &= "uploads/\n\n"
  result &= "# Database files\n"
  result &= "*.db\n"

proc scaffoldProject*(name: string): ScaffoldError =
  ## Create a new Doot project with the given name.
  ## Returns ScaffoldError with empty message on success.
  if not isValidProjectName(name):
    return ScaffoldError(message: "Invalid project name: '" & name &
      "'. Use only letters, numbers, and hyphens (no leading/trailing hyphens).")

  if dirExists(name):
    return ScaffoldError(message: "Directory '" & name & "' already exists.")

  # Create directory structure
  createDir(name)
  createDir(name / "views" / "layouts")
  createDir(name / "static")
  createDir(name / "migrations")
  createDir(name / "uploads")

  # Generate files
  writeFile(name / "app.do", generateAppDo())
  writeFile(name / "views" / "layouts" / "base.do", generateBaseLayout())
  writeFile(name / "static" / "app.css", generateAppCss())

  let secret = generateSessionSecret()
  writeFile(name / ".env", generateEnvFile(secret))
  writeFile(name / ".env.example", generateEnvExample())
  writeFile(name / ".gitignore", generateGitignore())

  return ScaffoldError(message: "")

proc printWelcomeMessage*(name: string) =
  ## Print the post-scaffold welcome message.
  echo ""
  echo "  Created " & name & "/"
  echo ""
  echo "  Next steps:"
  echo "    cd " & name
  echo "    doot dev"
  echo ""
  echo "  Your app will be running at http://localhost:3000"
  echo ""

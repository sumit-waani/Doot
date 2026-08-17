## Environment variable validation for the dootd production daemon.
## Scans .do files for env("KEY") references and validates
## that all required env vars are configured.

import std/[os, strutils, tables, sets]

proc extractEnvReferences*(doFileContent: string): seq[string] =
  ## Extract all env var keys referenced in .do file content.
  ## Looks for patterns like env("KEY") and returns the list of keys.
  ## Only matches standalone env( calls, not patterns like environment( or myenv(.
  result = @[]
  var seen = initHashSet[string]()
  var i = 0
  let content = doFileContent
  while i < content.len:
    # Look for env(" pattern
    if i + 4 < content.len and content[i..i+3] == "env(" and content[i+4] == '"':
      # Check that the character before 'env(' is not a letter or underscore
      # (to avoid matching 'environment(' or 'myenv(')
      var isStandalone = true
      if i > 0:
        let prev = content[i-1]
        if prev in {'a'..'z', 'A'..'Z', '_', '0'..'9'}:
          isStandalone = false
      if isStandalone:
        # Found env(" - extract the key
        let startKey = i + 5
        var endKey = startKey
        while endKey < content.len and content[endKey] != '"':
          endKey += 1
        if endKey < content.len:
          let key = content[startKey..endKey-1]
          if key.len > 0 and key notin seen:
            result.add(key)
            seen.incl(key)
        i = endKey + 1
      else:
        i += 1
    else:
      i += 1

proc scanProjectEnvVars*(projectDir: string): seq[string] =
  ## Walk all .do files in a project directory and collect
  ## all referenced env var keys.
  result = @[]
  var seen = initHashSet[string]()
  if not dirExists(projectDir):
    return
  for path in walkDirRec(projectDir):
    if path.endsWith(".do"):
      try:
        let content = readFile(path)
        let refs = extractEnvReferences(content)
        for r in refs:
          if r notin seen:
            result.add(r)
            seen.incl(r)
      except IOError:
        discard

proc validateEnvVars*(required: seq[string], configured: Table[string, string]): tuple[valid: bool, missing: seq[string]] =
  ## Validate that all required env vars are present in the configured table.
  ## Returns (valid: true, missing: @[]) if all are present.
  var missing: seq[string] = @[]
  for key in required:
    if not configured.hasKey(key) or configured[key].len == 0:
      missing.add(key)
  result = (valid: missing.len == 0, missing: missing)

proc parseEnvVarsString*(envVarsStr: string): Table[string, string] =
  ## Parse an env vars string (KEY=VALUE format, one per line or comma-separated)
  ## into a Table. Also supports JSON-like {"KEY": "VALUE"} format (simple parsing).
  result = initTable[string, string]()
  if envVarsStr.len == 0:
    return
  # Try line-by-line KEY=VALUE format first
  for line in envVarsStr.splitLines():
    let trimmed = line.strip()
    if trimmed.len == 0 or trimmed.startsWith("#"):
      continue
    let eqPos = trimmed.find('=')
    if eqPos > 0:
      let key = trimmed[0..eqPos-1].strip()
      let value = trimmed[eqPos+1..^1].strip()
      result[key] = value
  # If no results from line format, try simple JSON-like parsing
  if result.len == 0 and envVarsStr.contains(":"):
    var content = envVarsStr.strip()
    if content.startsWith("{"):
      content = content[1..^1]
    if content.endsWith("}"):
      content = content[0..^2]
    for part in content.split(","):
      let trimmed = part.strip()
      let colonPos = trimmed.find(':')
      if colonPos > 0:
        var key = trimmed[0..colonPos-1].strip()
        var value = trimmed[colonPos+1..^1].strip()
        # Remove quotes
        if key.startsWith("\"") and key.endsWith("\""):
          key = key[1..^2]
        if value.startsWith("\"") and value.endsWith("\""):
          value = value[1..^2]
        if key.len > 0:
          result[key] = value

proc formatMissingEnvError*(appName: string, missing: seq[string]): string =
  ## Format a user-friendly error message listing missing env vars.
  result = "App '" & appName & "' is missing required environment variables:\n"
  for key in missing:
    result.add("  - " & key & "\n")
  result.add("\nConfigure these variables in the app settings before deploying.")

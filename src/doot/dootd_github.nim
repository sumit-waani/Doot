## GitHub integration for the dootd production daemon.
## Handles cloning and pulling repositories using PAT authentication.

import std/[osproc, strutils, os]

type
  GitResult* = object
    success*: bool
    output*: string

proc validateGithubUrl*(url: string): bool =
  ## Check if a URL is a valid GitHub repository URL.
  ## Accepts: https://github.com/user/repo or https://github.com/user/repo.git
  if not url.startsWith("https://github.com/"):
    return false
  let path = url[len("https://github.com/")..^1]
  # Remove trailing .git if present
  let cleanPath = if path.endsWith(".git"): path[0..^5] else: path
  let parts = cleanPath.split('/')
  if parts.len < 2:
    return false
  # User and repo must be non-empty
  if parts[0].len == 0 or parts[1].len == 0:
    return false
  # Basic char check for user/repo
  for part in parts[0..1]:
    for c in part:
      if c notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}:
        return false
  return true

proc sanitizeGitUrl*(url: string, pat: string): string =
  ## Convert a GitHub URL to include PAT for HTTPS authentication.
  ## Input: https://github.com/user/repo
  ## Output: https://<pat>@github.com/user/repo.git
  var cleanUrl = url.strip()
  if cleanUrl.endsWith("/"):
    cleanUrl = cleanUrl[0..^2]
  if not cleanUrl.endsWith(".git"):
    cleanUrl = cleanUrl & ".git"
  # Replace https://github.com with https://<pat>@github.com
  if pat.len > 0:
    result = cleanUrl.replace("https://github.com", "https://" & pat & "@github.com")
  else:
    result = cleanUrl

proc cloneRepo*(githubUrl: string, pat: string, branch: string,
                destDir: string): GitResult =
  ## Clone a GitHub repository to the destination directory.
  ## Uses PAT for authentication via HTTPS URL embedding.
  let authUrl = sanitizeGitUrl(githubUrl, pat)
  let cmd = "git clone --branch " & branch & " " & authUrl & " " & destDir
  try:
    let (output, exitCode) = execCmdEx(cmd)
    result = GitResult(success: exitCode == 0, output: output)
  except OSError:
    result = GitResult(success: false, output: "Failed to execute git clone")

proc pullRepo*(pat: string, branch: string, repoDir: string): GitResult =
  ## Pull the latest changes from a repository.
  ## Executes git pull origin <branch> in the given directory.
  if not dirExists(repoDir):
    return GitResult(success: false, output: "Repository directory does not exist: " & repoDir)
  let cmd = "git -C " & repoDir & " pull origin " & branch
  try:
    let (output, exitCode) = execCmdEx(cmd)
    result = GitResult(success: exitCode == 0, output: output)
  except OSError:
    result = GitResult(success: false, output: "Failed to execute git pull")

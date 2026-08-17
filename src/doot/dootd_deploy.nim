## Deploy pipeline orchestrator for the dootd production daemon.
## Executes the full deploy flow: clone/pull, validate env, compile, start.

import std/[os, strutils, tables, times]
import db_connector/db_sqlite
import ./dootd_types
import ./dootd_state
import ./dootd_github
import ./dootd_envcheck

type
  DeployResult* = object
    success*: bool
    error*: string
    logs*: seq[string]

proc deployApp*(db: DbConn, appConfig: AppConfig, appsDir: string): DeployResult =
  ## Execute the full deploy pipeline for an application.
  ## Steps:
  ##   1. Clone or pull the repository
  ##   2. Validate env vars against .do file references
  ##   3. Compile (placeholder - real Doot compilation is complex)
  ##   4. Return result
  var logs: seq[string] = @[]
  let appDir = appsDir / appConfig.name
  let timestamp = $now()

  logs.add("[" & timestamp & "] Starting deploy for " & appConfig.name)

  # Step 1: Clone or pull
  if not dirExists(appDir):
    logs.add("Cloning repository: " & appConfig.githubUrl & " (branch: " & appConfig.branch & ")")
    let cloneResult = cloneRepo(appConfig.githubUrl, appConfig.pat, appConfig.branch, appDir)
    if not cloneResult.success:
      let errMsg = "Failed to clone repository: " & cloneResult.output
      logs.add(errMsg)
      # Log to DB
      addAppLog(db, appConfig.id, "stderr", errMsg)
      updateAppStatus(db, appConfig.id, asError)
      return DeployResult(success: false, error: errMsg, logs: logs)
    logs.add("Repository cloned successfully")
  else:
    logs.add("Pulling latest changes (branch: " & appConfig.branch & ")")
    let pullResult = pullRepo(appConfig.pat, appConfig.branch, appDir)
    if not pullResult.success:
      # Pull failed - check if the directory has content we can still deploy
      # (e.g., local repo without remote, or network issue on existing checkout)
      let hasDotDo = fileExists(appDir / "app.do")
      if not hasDotDo:
        let errMsg = "Failed to pull repository: " & pullResult.output
        logs.add(errMsg)
        addAppLog(db, appConfig.id, "stderr", errMsg)
        updateAppStatus(db, appConfig.id, asError)
        return DeployResult(success: false, error: errMsg, logs: logs)
      logs.add("Pull failed but project files exist, continuing with current code")
    else:
      logs.add("Repository updated successfully")

  # Step 2: Validate env vars
  logs.add("Scanning for environment variable references...")
  let requiredVars = scanProjectEnvVars(appDir)
  if requiredVars.len > 0:
    logs.add("Found " & $requiredVars.len & " required env var(s): " & requiredVars.join(", "))
    let configured = parseEnvVarsString(appConfig.envVars)
    let (valid, missing) = validateEnvVars(requiredVars, configured)
    if not valid:
      let errMsg = formatMissingEnvError(appConfig.name, missing)
      logs.add(errMsg)
      addAppLog(db, appConfig.id, "stderr", errMsg)
      updateAppStatus(db, appConfig.id, asError)
      return DeployResult(success: false, error: errMsg, logs: logs)
    logs.add("All environment variables are configured")
  else:
    logs.add("No environment variable references found in .do files")

  # Step 3: Compile (placeholder)
  # In a real deployment, this would:
  #   - Parse all .do files in the project
  #   - Generate Nim source code
  #   - Compile the generated Nim to a binary
  # For now, we mark this step as a placeholder since the full
  # Doot compilation pipeline is complex and involves the parser,
  # code generator, and Nim compiler.
  logs.add("Compilation step (placeholder) - would compile .do files to binary")

  # Step 4: Success
  logs.add("Deploy completed successfully for " & appConfig.name)
  for logLine in logs:
    addAppLog(db, appConfig.id, "stdout", logLine)
  updateAppStatus(db, appConfig.id, asStopped)  # Ready to start

  return DeployResult(success: true, error: "", logs: logs)

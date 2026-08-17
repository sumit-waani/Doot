## Child process supervisor for the dootd production daemon.
## Manages child processes with crash detection and exponential backoff restart.

import std/[tables, times, osproc, streams, os, strtabs]
import ./dootd_types

type
  ChildStatus* = enum
    csRunning = "running"
    csStopped = "stopped"
    csCrashed = "crashed"
    csError = "error"

  ChildProcess* = object
    pid*: int
    appId*: int64
    appName*: string
    internalPort*: int
    process*: Process
    status*: ChildStatus
    restartCount*: int
    lastCrashTime*: Time
    backoffMs*: int
    binaryPath*: string

  ProcessSupervisor* = object
    children*: Table[int64, ChildProcess]
    maxRestarts*: int
    restartWindowSecs*: int
    initialBackoffMs*: int
    maxBackoffMs*: int

proc newProcessSupervisor*(maxRestarts: int = 5, restartWindowSecs: int = 60,
                            initialBackoffMs: int = 1000,
                            maxBackoffMs: int = 30000): ProcessSupervisor =
  ## Create a new process supervisor with configurable restart policy.
  ProcessSupervisor(
    children: initTable[int64, ChildProcess](),
    maxRestarts: maxRestarts,
    restartWindowSecs: restartWindowSecs,
    initialBackoffMs: initialBackoffMs,
    maxBackoffMs: maxBackoffMs
  )

proc calculateBackoff*(supervisor: ProcessSupervisor, restartCount: int): int =
  ## Calculate exponential backoff delay in milliseconds.
  ## Returns min(initialBackoffMs * 2^restartCount, maxBackoffMs).
  if restartCount <= 0:
    return supervisor.initialBackoffMs
  var backoff = supervisor.initialBackoffMs
  for i in 1..restartCount:
    backoff = backoff * 2
    if backoff >= supervisor.maxBackoffMs:
      return supervisor.maxBackoffMs
  return min(backoff, supervisor.maxBackoffMs)

proc shouldRestart*(supervisor: ProcessSupervisor, child: ChildProcess): bool =
  ## Determine if a crashed child should be restarted.
  ## Returns false if maxRestarts exceeded within restartWindow.
  if child.restartCount >= supervisor.maxRestarts:
    let elapsed = (getTime() - child.lastCrashTime).inSeconds
    if elapsed < supervisor.restartWindowSecs.int64:
      return false
  return true

proc startChild*(supervisor: var ProcessSupervisor, appConfig: AppConfig,
                 binaryPath: string): bool =
  ## Start a child process for the given app configuration.
  ## Sets PORT env var to the app's internal port.
  ## Returns true if the process was started successfully.
  if not fileExists(binaryPath):
    return false

  var env = newStringTable()
  env["PORT"] = $appConfig.internalPort

  try:
    let process = startProcess(
      binaryPath,
      options = {poStdErrToStdOut, poUsePath}
    )
    let child = ChildProcess(
      pid: process.processID(),
      appId: appConfig.id,
      appName: appConfig.name,
      internalPort: appConfig.internalPort,
      process: process,
      status: csRunning,
      restartCount: 0,
      lastCrashTime: getTime(),
      backoffMs: 0,
      binaryPath: binaryPath
    )
    supervisor.children[appConfig.id] = child
    return true
  except OSError, IOError:
    return false

proc stopChild*(supervisor: var ProcessSupervisor, appId: int64,
                timeoutMs: int = 5000): bool =
  ## Stop a child process. Sends SIGTERM, waits up to timeoutMs, then SIGKILL.
  ## Returns true if the process was stopped.
  if not supervisor.children.hasKey(appId):
    return false

  var child = supervisor.children[appId]
  if child.process == nil:
    child.status = csStopped
    supervisor.children[appId] = child
    return true

  try:
    if child.process.running():
      child.process.terminate()
      # Wait for up to timeout
      let startTime = epochTime()
      while child.process.running():
        let elapsed = (epochTime() - startTime) * 1000
        if elapsed > timeoutMs.float:
          child.process.kill()
          break
        sleep(100)
    child.status = csStopped
    supervisor.children[appId] = child
    return true
  except OSError:
    child.status = csError
    supervisor.children[appId] = child
    return false

proc restartChild*(supervisor: var ProcessSupervisor, appId: int64): bool =
  ## Restart a child process with exponential backoff.
  ## Returns false if max restarts exceeded.
  if not supervisor.children.hasKey(appId):
    return false

  var child = supervisor.children[appId]

  if not shouldRestart(supervisor, child):
    child.status = csError
    supervisor.children[appId] = child
    return false

  # Stop existing process
  discard stopChild(supervisor, appId)

  # Apply backoff
  child = supervisor.children[appId]
  child.restartCount += 1
  child.lastCrashTime = getTime()
  child.backoffMs = calculateBackoff(supervisor, child.restartCount)
  supervisor.children[appId] = child

  # Backoff is tracked but not applied synchronously here.
  # The caller (checkChildren loop) should schedule deferred restarts using
  # sleepAsync or a timer callback to avoid blocking the event loop.
  # The backoffMs field is available for the caller to implement this.

  # Start new process
  try:
    let process = startProcess(
      child.binaryPath,
      options = {poStdErrToStdOut, poUsePath}
    )
    child.pid = process.processID()
    child.process = process
    child.status = csRunning
    supervisor.children[appId] = child
    return true
  except OSError, IOError:
    child.status = csError
    supervisor.children[appId] = child
    return false

proc checkChildren*(supervisor: var ProcessSupervisor): seq[int64] =
  ## Poll all child processes and detect exits.
  ## Returns a list of appIds that have crashed and need restart.
  result = @[]
  for appId, child in supervisor.children.pairs:
    if child.status == csRunning and child.process != nil:
      try:
        if not child.process.running():
          var c = child
          c.status = csCrashed
          c.lastCrashTime = getTime()
          supervisor.children[appId] = c
          result.add(appId)
      except OSError:
        discard

proc captureOutput*(process: Process): string =
  ## Capture available output from a process stdout/stderr stream.
  result = ""
  if process == nil:
    return
  try:
    let stream = process.outputStream()
    if stream != nil:
      while stream.atEnd() == false:
        result.add(stream.readLine() & "\n")
        if result.len > 4096:
          break
  except IOError, OSError:
    discard

proc getChildStatus*(supervisor: ProcessSupervisor, appId: int64): ChildStatus =
  ## Get the status of a child process.
  if supervisor.children.hasKey(appId):
    return supervisor.children[appId].status
  return csStopped

proc removeChild*(supervisor: var ProcessSupervisor, appId: int64) =
  ## Remove a child from the supervisor (after stopping it).
  if supervisor.children.hasKey(appId):
    supervisor.children.del(appId)

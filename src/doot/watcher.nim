## Poll-based file watcher for the Doot dev server.
## Monitors specified paths for file changes using mtime comparison.
## Supports debouncing to avoid triggering on rapid successive saves.

import std/[os, tables, times, sets, strutils]

type
  FileChange* = object
    path*: string
    kind*: FileChangeKind

  FileChangeKind* = enum
    fckModified
    fckCreated
    fckDeleted

  WatcherConfig* = object
    pollIntervalMs*: int      ## Poll interval in milliseconds (default 500)
    debounceMs*: int          ## Debounce delay in milliseconds (default 150)
    watchPatterns*: seq[string]  ## File extensions to watch (e.g., ".do")
    watchPaths*: seq[string]     ## Specific files to watch (e.g., ".env")
    excludeDirs*: seq[string]    ## Directory names to exclude

  FileWatcher* = object
    config*: WatcherConfig
    baseDir*: string
    mtimes*: Table[string, Time]
    lastChangeTime*: Time
    pendingChanges*: seq[FileChange]
    debouncing*: bool

proc newWatcherConfig*(pollIntervalMs: int = 500, debounceMs: int = 150): WatcherConfig =
  ## Create a default watcher configuration for Doot projects.
  result = WatcherConfig(
    pollIntervalMs: pollIntervalMs,
    debounceMs: debounceMs,
    watchPatterns: @[".do"],
    watchPaths: @[".env"],
    excludeDirs: @[".git", ".doot-build", "migrations", "uploads", "static", "node_modules"]
  )

proc newFileWatcher*(baseDir: string, config: WatcherConfig = newWatcherConfig()): FileWatcher =
  ## Create a new file watcher for the given base directory.
  result = FileWatcher(
    config: config,
    baseDir: baseDir,
    mtimes: initTable[string, Time](),
    lastChangeTime: Time(),
    pendingChanges: @[],
    debouncing: false
  )

proc shouldWatch(watcher: FileWatcher, path: string): bool =
  ## Determine if a file should be monitored based on config.
  let filename = extractFilename(path)
  let ext = splitFile(path).ext

  # Check if it's a specifically watched file
  for watchPath in watcher.config.watchPaths:
    if filename == watchPath or path.endsWith(watchPath):
      return true

  # Check if it matches a watched extension
  for pattern in watcher.config.watchPatterns:
    if ext == pattern:
      return true

  return false

proc isExcludedDir(watcher: FileWatcher, dirName: string): bool =
  ## Check if a directory should be excluded from watching.
  for excluded in watcher.config.excludeDirs:
    if dirName == excluded:
      return true
  return false

proc scanFiles*(watcher: var FileWatcher): seq[string] =
  ## Scan the base directory for all watchable files.
  ## Returns the list of found file paths.
  result = @[]
  if not dirExists(watcher.baseDir):
    return

  proc walkRecursive(dir: string, watcher: var FileWatcher, files: var seq[string]) =
    for kind, path in walkDir(dir):
      case kind
      of pcDir:
        let dirName = lastPathPart(path)
        if not watcher.isExcludedDir(dirName):
          walkRecursive(path, watcher, files)
      of pcFile:
        if watcher.shouldWatch(path):
          files.add(path)
      else:
        discard

  walkRecursive(watcher.baseDir, watcher, result)

proc recordBaseline*(watcher: var FileWatcher) =
  ## Scan all monitored paths and record baseline modification times.
  watcher.mtimes.clear()
  let files = watcher.scanFiles()
  for path in files:
    try:
      let info = getFileInfo(path)
      watcher.mtimes[path] = info.lastWriteTime
    except OSError:
      discard

proc detectChanges*(watcher: var FileWatcher): seq[FileChange] =
  ## Compare current file states to recorded mtimes.
  ## Returns detected changes (new, modified, deleted files).
  result = @[]

  # Get current file set
  let currentFiles = watcher.scanFiles()
  var currentSet = initHashSet[string]()
  for f in currentFiles:
    currentSet.incl(f)

  # Check for modified or new files
  for path in currentFiles:
    try:
      let info = getFileInfo(path)
      let currentMtime = info.lastWriteTime
      if path in watcher.mtimes:
        if currentMtime != watcher.mtimes[path]:
          result.add(FileChange(path: path, kind: fckModified))
          watcher.mtimes[path] = currentMtime
      else:
        result.add(FileChange(path: path, kind: fckCreated))
        watcher.mtimes[path] = currentMtime
    except OSError:
      discard

  # Check for deleted files
  var deletedPaths: seq[string] = @[]
  for path in watcher.mtimes.keys:
    if path notin currentSet:
      result.add(FileChange(path: path, kind: fckDeleted))
      deletedPaths.add(path)

  # Remove deleted paths from the mtime table
  for path in deletedPaths:
    watcher.mtimes.del(path)

proc shouldTrigger*(watcher: var FileWatcher, changes: seq[FileChange]): bool =
  ## Check if we should trigger a recompile based on debounce timing.
  ## Returns true if debounce period has elapsed since last change.
  if changes.len == 0:
    if watcher.debouncing:
      let now = getTime()
      let elapsed = (now - watcher.lastChangeTime).inMilliseconds
      if elapsed >= watcher.config.debounceMs:
        watcher.debouncing = false
        return true
    return false
  else:
    # New changes detected - start/reset debounce timer
    watcher.lastChangeTime = getTime()
    watcher.pendingChanges = changes
    watcher.debouncing = true
    return false

proc getPendingChanges*(watcher: var FileWatcher): seq[FileChange] =
  ## Get and clear pending changes after debounce.
  result = watcher.pendingChanges
  watcher.pendingChanges = @[]

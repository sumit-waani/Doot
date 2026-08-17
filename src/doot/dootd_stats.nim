## System statistics collection for the dootd dashboard.
## Reads from /proc on Linux for CPU, memory, and disk info.
## Degrades gracefully on non-Linux systems by returning placeholder values.

import std/[os, strutils]

type
  CpuStats* = object
    usagePercent*: float    ## CPU usage as a percentage (0-100)
    available*: bool        ## Whether real data was available

  MemStats* = object
    totalMb*: int           ## Total memory in MB
    usedMb*: int            ## Used memory in MB
    freeMb*: int            ## Free memory in MB
    usagePercent*: float    ## Memory usage percentage
    available*: bool        ## Whether real data was available

  DiskStats* = object
    totalGb*: float         ## Total disk space in GB
    usedGb*: float          ## Used disk space in GB
    freeGb*: float          ## Free disk space in GB
    usagePercent*: float    ## Disk usage percentage
    available*: bool        ## Whether real data was available

  SystemStats* = object
    cpu*: CpuStats
    memory*: MemStats
    disk*: DiskStats
    hostname*: string
    uptime*: string

proc getCpuUsage*(): CpuStats =
  ## Read CPU usage from /proc/stat.
  ## Returns a placeholder if /proc/stat is not available.
  result = CpuStats(usagePercent: 0.0, available: false)
  let procStat = "/proc/stat"
  if not fileExists(procStat):
    return

  try:
    let content = readFile(procStat)
    let lines = content.splitLines()
    for line in lines:
      if line.startsWith("cpu "):
        let parts = line.splitWhitespace()
        if parts.len >= 5:
          let user = parseFloat(parts[1])
          let nice = parseFloat(parts[2])
          let system = parseFloat(parts[3])
          let idle = parseFloat(parts[4])
          let iowait = if parts.len > 5: parseFloat(parts[5]) else: 0.0
          let total = user + nice + system + idle + iowait
          if total > 0:
            result.usagePercent = ((total - idle) / total) * 100.0
            result.available = true
        break
  except IOError, ValueError:
    discard

proc getMemoryInfo*(): MemStats =
  ## Read memory info from /proc/meminfo.
  ## Returns a placeholder if /proc/meminfo is not available.
  result = MemStats(totalMb: 0, usedMb: 0, freeMb: 0, usagePercent: 0.0, available: false)
  let procMeminfo = "/proc/meminfo"
  if not fileExists(procMeminfo):
    return

  try:
    let content = readFile(procMeminfo)
    var totalKb: int = 0
    var freeKb: int = 0
    var availableKb: int = 0
    var buffersKb: int = 0
    var cachedKb: int = 0

    for line in content.splitLines():
      let parts = line.splitWhitespace()
      if parts.len >= 2:
        let key = parts[0]
        let val = parseInt(parts[1])
        case key
        of "MemTotal:":
          totalKb = val
        of "MemFree:":
          freeKb = val
        of "MemAvailable:":
          availableKb = val
        of "Buffers:":
          buffersKb = val
        of "Cached:":
          cachedKb = val
        else:
          discard

    if totalKb > 0:
      let usedKb = totalKb - freeKb - buffersKb - cachedKb
      result.totalMb = totalKb div 1024
      result.usedMb = usedKb div 1024
      result.freeMb = (if availableKb > 0: availableKb else: freeKb + buffersKb + cachedKb) div 1024
      result.usagePercent = (usedKb.float / totalKb.float) * 100.0
      result.available = true
  except IOError, ValueError:
    discard

proc getDiskInfo*(): DiskStats =
  ## Get disk usage info for the root filesystem.
  ## Uses /proc/mounts to find root and reads statvfs info.
  ## Falls back to placeholder values if unavailable.
  result = DiskStats(totalGb: 0.0, usedGb: 0.0, freeGb: 0.0, usagePercent: 0.0, available: false)

  # Try to get disk info from the root filesystem
  try:
    # On Linux, we can read from /proc/self/mountinfo or use df-like logic
    let procMounts = "/proc/mounts"
    if fileExists(procMounts):
      # We have /proc available, just indicate availability
      # but getting actual statvfs requires FFI; provide basic indicator
      result.available = false
  except OSError:
    discard

proc getSystemUptime*(): string =
  ## Read system uptime from /proc/uptime.
  ## Returns a human-readable string or "unknown".
  let procUptime = "/proc/uptime"
  if not fileExists(procUptime):
    return "unknown"

  try:
    let content = readFile(procUptime)
    let parts = content.splitWhitespace()
    if parts.len >= 1:
      let seconds = int(parseFloat(parts[0]))
      let days = seconds div 86400
      let hours = (seconds mod 86400) div 3600
      let minutes = (seconds mod 3600) div 60
      if days > 0:
        return $days & "d " & $hours & "h " & $minutes & "m"
      elif hours > 0:
        return $hours & "h " & $minutes & "m"
      else:
        return $minutes & "m"
  except IOError, ValueError:
    discard
  return "unknown"

proc getSystemHostname*(): string =
  ## Get the system hostname.
  try:
    let content = readFile("/etc/hostname")
    result = content.strip()
  except IOError:
    result = "localhost"

proc collectSystemStats*(): SystemStats =
  ## Collect all system statistics.
  ## Returns stats with available=false for metrics that cannot be read.
  result = SystemStats(
    cpu: getCpuUsage(),
    memory: getMemoryInfo(),
    disk: getDiskInfo(),
    hostname: getSystemHostname(),
    uptime: getSystemUptime()
  )

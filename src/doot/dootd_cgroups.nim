## cgroups v2 isolation for the dootd production daemon.
## Provides resource limits (memory, CPU) for managed applications.
## All functions are no-ops if cgroups v2 is not available (graceful degradation).

import std/[os, strutils]

const
  CgroupBase* = "/sys/fs/cgroup"
  CgroupDootd* = CgroupBase / "dootd"
  CgroupControllers* = CgroupBase / "cgroup.controllers"

proc cgroupsAvailable*(): bool =
  ## Check if cgroups v2 is available on this system.
  ## Returns true if /sys/fs/cgroup/cgroup.controllers exists.
  return fileExists(CgroupControllers)

proc cgroupPath*(appName: string): string =
  ## Get the cgroup directory path for an app.
  result = CgroupDootd / appName

proc createAppCgroup*(appName: string): bool =
  ## Create a cgroup directory for the given app.
  ## Returns true if successful, false if cgroups unavailable or failed.
  if not cgroupsAvailable():
    return false
  let path = cgroupPath(appName)
  try:
    createDir(path)
    return dirExists(path)
  except OSError:
    return false

proc setMemoryLimit*(appName: string, limitMb: int): bool =
  ## Set memory limit for an app's cgroup.
  ## Writes to memory.max file. limitMb=0 means unlimited.
  ## Returns true if successful.
  if not cgroupsAvailable():
    return false
  if limitMb <= 0:
    return true  # No limit to set
  let path = cgroupPath(appName) / "memory.max"
  let limitBytes = limitMb * 1024 * 1024
  try:
    writeFile(path, $limitBytes)
    return true
  except IOError, OSError:
    return false

proc setCpuShares*(appName: string, shares: int): bool =
  ## Set CPU weight for an app's cgroup.
  ## Writes to cpu.weight file. shares=0 means default.
  ## cpu.weight range is 1-10000 (100 is default).
  ## Returns true if successful.
  if not cgroupsAvailable():
    return false
  if shares <= 0:
    return true  # No weight to set
  let path = cgroupPath(appName) / "cpu.weight"
  let weight = max(1, min(shares, 10000))
  try:
    writeFile(path, $weight)
    return true
  except IOError, OSError:
    return false

proc addProcessToCgroup*(appName: string, pid: int): bool =
  ## Add a process to the app's cgroup.
  ## Writes the PID to cgroup.procs file.
  ## Returns true if successful.
  if not cgroupsAvailable():
    return false
  let path = cgroupPath(appName) / "cgroup.procs"
  try:
    writeFile(path, $pid)
    return true
  except IOError, OSError:
    return false

proc removeAppCgroup*(appName: string): bool =
  ## Remove the cgroup directory for an app.
  ## Returns true if successful or if cgroups not available.
  if not cgroupsAvailable():
    return true  # Nothing to remove
  let path = cgroupPath(appName)
  if not dirExists(path):
    return true
  try:
    removeDir(path)
    return true
  except OSError:
    return false

proc memoryMaxPath*(appName: string): string =
  ## Get the path to the memory.max file for an app's cgroup.
  result = cgroupPath(appName) / "memory.max"

proc cpuWeightPath*(appName: string): string =
  ## Get the path to the cpu.weight file for an app's cgroup.
  result = cgroupPath(appName) / "cpu.weight"

proc cgroupProcsPath*(appName: string): string =
  ## Get the path to the cgroup.procs file for an app's cgroup.
  result = cgroupPath(appName) / "cgroup.procs"

## Background job queue and scheduler for the Doot runtime.
## SQLite-backed queue with in-process async worker pool.
## No external services required - everything runs within the application process.

import std/[json, times, strutils, tables, asyncdispatch, options]
import db_connector/db_sqlite

# ------------------------------------------------------------------
# Types
# ------------------------------------------------------------------

type
  JobStatus* = enum
    jsPending = "pending"
    jsRunning = "running"
    jsCompleted = "completed"
    jsFailed = "failed"

  JobRecord* = object
    id*: int64
    jobType*: string
    payload*: string
    status*: JobStatus
    runAt*: string
    attempts*: int
    maxAttempts*: int
    lockedAt*: string
    error*: string
    createdAt*: string
    updatedAt*: string

  JobHandler* = proc(payload: JsonNode): Future[void] {.closure.}

  ScheduleEntry* = object
    name*: string
    interval*: Duration
    handler*: JobHandler
    lastRun*: Time

  JobCounts* = object
    pending*: int
    running*: int
    completed*: int
    failed*: int

  WorkerPool* = ref object
    db*: DbConn
    poolSize*: int
    pollInterval*: int  # milliseconds
    maxAttempts*: int
    stuckTimeout*: Duration
    handlers*: Table[string, JobHandler]
    schedules*: seq[ScheduleEntry]
    running*: bool

# ------------------------------------------------------------------
# SQL Constants
# ------------------------------------------------------------------

const JobsTableSQL* = """
  CREATE TABLE IF NOT EXISTS _doot_jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    job_type TEXT NOT NULL,
    payload TEXT NOT NULL DEFAULT '{}',
    status TEXT NOT NULL DEFAULT 'pending',
    run_at TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    max_attempts INTEGER NOT NULL DEFAULT 3,
    locked_at TEXT,
    error TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )
"""

const JobsIndexStatusSQL* = """
  CREATE INDEX IF NOT EXISTS idx_doot_jobs_status ON _doot_jobs(status)
"""

const JobsIndexRunAtSQL* = """
  CREATE INDEX IF NOT EXISTS idx_doot_jobs_run_at ON _doot_jobs(run_at)
"""

# ------------------------------------------------------------------
# Interval Parsing
# ------------------------------------------------------------------

proc parseInterval*(s: string): Duration =
  ## Parse a human-readable interval string into a Duration.
  ## Supports: "30 seconds", "5 minutes", "1 hour", "1 day", "1 week"
  let parts = s.strip().split(" ", maxsplit = 1)
  if parts.len != 2:
    raise newException(ValueError, "Invalid interval format: '" & s & "'. Expected format: '<number> <unit>'")

  var amount: int
  try:
    amount = parseInt(parts[0])
  except ValueError:
    raise newException(ValueError, "Invalid interval number: '" & parts[0] & "'")

  let unit = parts[1].toLowerAscii().strip()
  case unit
  of "second", "seconds", "sec", "secs":
    result = initDuration(seconds = amount)
  of "minute", "minutes", "min", "mins":
    result = initDuration(minutes = amount)
  of "hour", "hours", "hr", "hrs":
    result = initDuration(hours = amount)
  of "day", "days":
    result = initDuration(days = amount)
  of "week", "weeks":
    result = initDuration(weeks = amount)
  else:
    raise newException(ValueError, "Unknown interval unit: '" & unit & "'. Valid units: seconds, minutes, hours, days, weeks")

# ------------------------------------------------------------------
# Table Initialization
# ------------------------------------------------------------------

proc initJobsTable*(db: DbConn) =
  ## Create the _doot_jobs table and indexes if they do not exist.
  db.exec(sql(JobsTableSQL))
  db.exec(sql(JobsIndexStatusSQL))
  db.exec(sql(JobsIndexRunAtSQL))

# ------------------------------------------------------------------
# Job Queue Operations
# ------------------------------------------------------------------

proc enqueueJob*(db: DbConn, jobType: string, payload: JsonNode = newJObject(),
                 runAt: DateTime = now(), maxAttempts: int = 3): int64 =
  ## Insert a new job into the queue. Returns the new job ID.
  let nowStr = $now()
  let runAtStr = $runAt
  let payloadStr = $payload
  result = db.insertID(
    sql"""INSERT INTO _doot_jobs (job_type, payload, status, run_at, attempts, max_attempts, created_at, updated_at)
          VALUES (?, ?, 'pending', ?, 0, ?, ?, ?)""",
    jobType, payloadStr, runAtStr, $maxAttempts, nowStr, nowStr
  )

proc enqueueJobWithDelay*(db: DbConn, jobType: string, payload: JsonNode = newJObject(),
                          delay: Duration = initDuration(seconds = 0), maxAttempts: int = 3): int64 =
  ## Insert a new job into the queue with a delay before it becomes eligible for execution.
  let runAt = now() + delay
  result = enqueueJob(db, jobType, payload, runAt, maxAttempts)

proc claimNextJob*(db: DbConn): Option[JobRecord] =
  ## Atomically claim the next pending job that is ready to run.
  ## Sets status to 'running' and locked_at to current time.
  ## Returns none if no jobs are available.
  let nowStr = $now()

  # Find the next eligible job
  let row = db.getRow(
    sql"""SELECT id, job_type, payload, status, run_at, attempts, max_attempts, locked_at, error, created_at, updated_at
          FROM _doot_jobs
          WHERE status = 'pending' AND run_at <= ?
          ORDER BY run_at ASC, id ASC
          LIMIT 1""",
    nowStr
  )

  if row[0] == "":
    return none(JobRecord)

  let jobId = parseBiggestInt(row[0])

  # Lock the job
  db.exec(
    sql"""UPDATE _doot_jobs SET status = 'running', locked_at = ?, updated_at = ?
          WHERE id = ? AND status = 'pending'""",
    nowStr, nowStr, $jobId
  )

  result = some(JobRecord(
    id: jobId,
    jobType: row[1],
    payload: row[2],
    status: jsRunning,
    runAt: row[4],
    attempts: parseInt(row[5]),
    maxAttempts: parseInt(row[6]),
    lockedAt: nowStr,
    error: row[8],
    createdAt: row[9],
    updatedAt: row[10]
  ))

proc completeJob*(db: DbConn, jobId: int64) =
  ## Mark a job as completed.
  let nowStr = $now()
  db.exec(
    sql"""UPDATE _doot_jobs SET status = 'completed', locked_at = NULL, updated_at = ?
          WHERE id = ?""",
    nowStr, $jobId
  )

proc failJob*(db: DbConn, jobId: int64, error: string = "", maxAttempts: int = 3) =
  ## Mark a job as failed. If attempts < maxAttempts, re-enqueue for retry.
  ## Otherwise, set status to 'failed' permanently.
  let nowStr = $now()

  # Increment attempts
  db.exec(
    sql"""UPDATE _doot_jobs SET attempts = attempts + 1, updated_at = ?
          WHERE id = ?""",
    nowStr, $jobId
  )

  # Check current attempts
  let row = db.getRow(
    sql"SELECT attempts, max_attempts FROM _doot_jobs WHERE id = ?",
    $jobId
  )

  if row[0] == "":
    return

  let attempts = parseInt(row[0])
  let maxAtt = parseInt(row[1])

  if attempts < maxAtt:
    # Re-enqueue for retry
    db.exec(
      sql"""UPDATE _doot_jobs SET status = 'pending', locked_at = NULL, error = ?, updated_at = ?
            WHERE id = ?""",
      error, nowStr, $jobId
    )
  else:
    # Permanently failed
    db.exec(
      sql"""UPDATE _doot_jobs SET status = 'failed', locked_at = NULL, error = ?, updated_at = ?
            WHERE id = ?""",
      error, nowStr, $jobId
    )

proc retryJob*(db: DbConn, jobId: int64) =
  ## Manually retry a failed job by resetting it to pending.
  let nowStr = $now()
  db.exec(
    sql"""UPDATE _doot_jobs SET status = 'pending', locked_at = NULL, error = NULL, updated_at = ?
          WHERE id = ? AND status = 'failed'""",
    nowStr, $jobId
  )

proc unlockStuckJobs*(db: DbConn, timeout: Duration = initDuration(minutes = 30)): int =
  ## Find jobs that have been running longer than the timeout and reset them to pending.
  ## Returns the number of jobs unlocked.
  let cutoff = now() - timeout
  let cutoffStr = $cutoff
  let nowStr = $now()

  # Get count of stuck jobs first
  let countRow = db.getRow(
    sql"""SELECT COUNT(*) FROM _doot_jobs
          WHERE status = 'running' AND locked_at IS NOT NULL AND locked_at < ?""",
    cutoffStr
  )

  let count = if countRow[0] != "": parseInt(countRow[0]) else: 0

  if count > 0:
    db.exec(
      sql"""UPDATE _doot_jobs SET status = 'pending', locked_at = NULL, updated_at = ?
            WHERE status = 'running' AND locked_at IS NOT NULL AND locked_at < ?""",
      nowStr, cutoffStr
    )

  result = count

# ------------------------------------------------------------------
# Status Queries
# ------------------------------------------------------------------

proc getJobCounts*(db: DbConn): JobCounts =
  ## Get counts of jobs by status.
  let rows = db.getAllRows(
    sql"SELECT status, COUNT(*) FROM _doot_jobs GROUP BY status"
  )
  for row in rows:
    case row[0]
    of "pending":
      result.pending = parseInt(row[1])
    of "running":
      result.running = parseInt(row[1])
    of "completed":
      result.completed = parseInt(row[1])
    of "failed":
      result.failed = parseInt(row[1])
    else:
      discard

proc getFailedJobs*(db: DbConn, limit: int = 50): seq[JobRecord] =
  ## Get the most recent failed jobs.
  result = @[]
  let rows = db.getAllRows(
    sql"""SELECT id, job_type, payload, status, run_at, attempts, max_attempts, locked_at, error, created_at, updated_at
          FROM _doot_jobs WHERE status = 'failed'
          ORDER BY updated_at DESC LIMIT ?""",
    $limit
  )
  for row in rows:
    result.add(JobRecord(
      id: parseBiggestInt(row[0]),
      jobType: row[1],
      payload: row[2],
      status: jsFailed,
      runAt: row[4],
      attempts: parseInt(row[5]),
      maxAttempts: parseInt(row[6]),
      lockedAt: row[7],
      error: row[8],
      createdAt: row[9],
      updatedAt: row[10]
    ))

proc getRecentJobs*(db: DbConn, limit: int = 50): seq[JobRecord] =
  ## Get the most recently updated jobs.
  result = @[]
  let rows = db.getAllRows(
    sql"""SELECT id, job_type, payload, status, run_at, attempts, max_attempts, locked_at, error, created_at, updated_at
          FROM _doot_jobs
          ORDER BY updated_at DESC LIMIT ?""",
    $limit
  )
  for row in rows:
    var status: JobStatus
    case row[3]
    of "pending": status = jsPending
    of "running": status = jsRunning
    of "completed": status = jsCompleted
    of "failed": status = jsFailed
    else: status = jsPending
    result.add(JobRecord(
      id: parseBiggestInt(row[0]),
      jobType: row[1],
      payload: row[2],
      status: status,
      runAt: row[4],
      attempts: parseInt(row[5]),
      maxAttempts: parseInt(row[6]),
      lockedAt: row[7],
      error: row[8],
      createdAt: row[9],
      updatedAt: row[10]
    ))

# ------------------------------------------------------------------
# Worker Pool
# ------------------------------------------------------------------

proc newWorkerPool*(db: DbConn, poolSize: int = 2, pollInterval: int = 5000,
                    maxAttempts: int = 3, stuckTimeout: Duration = initDuration(minutes = 30)): WorkerPool =
  ## Create a new worker pool. pollInterval is in milliseconds.
  result = WorkerPool(
    db: db,
    poolSize: poolSize,
    pollInterval: pollInterval,
    maxAttempts: maxAttempts,
    stuckTimeout: stuckTimeout,
    handlers: initTable[string, JobHandler](),
    schedules: @[],
    running: false
  )

proc registerJobHandler*(pool: WorkerPool, jobType: string, handler: JobHandler) =
  ## Register a handler function for a specific job type.
  pool.handlers[jobType] = handler

proc addSchedule*(pool: WorkerPool, name: string, interval: Duration, handler: JobHandler) =
  ## Add a scheduled job that will be enqueued at the given interval.
  pool.schedules.add(ScheduleEntry(
    name: name,
    interval: interval,
    handler: handler,
    lastRun: getTime()
  ))

proc workerLoop(pool: WorkerPool, workerId: int) {.async.} =
  ## A single worker loop that polls for and executes jobs.
  while pool.running:
    let jobOpt = claimNextJob(pool.db)
    if jobOpt.isSome:
      let job = jobOpt.get
      if pool.handlers.hasKey(job.jobType):
        let handler = pool.handlers[job.jobType]
        let payload = parseJson(job.payload)
        let fut = handler(payload)
        yield fut
        if fut.failed:
          failJob(pool.db, job.id, fut.error.msg, job.maxAttempts)
        else:
          completeJob(pool.db, job.id)
      else:
        failJob(pool.db, job.id, "No handler registered for job type: " & job.jobType, job.maxAttempts)
    else:
      await sleepAsync(pool.pollInterval)

proc schedulerLoop(pool: WorkerPool) {.async.} =
  ## The scheduler loop that enqueues scheduled jobs at their configured intervals.
  while pool.running:
    let currentTime = getTime()
    for i in 0 ..< pool.schedules.len:
      let elapsed = currentTime - pool.schedules[i].lastRun
      if elapsed >= pool.schedules[i].interval:
        # Enqueue the scheduled job
        discard enqueueJob(pool.db, pool.schedules[i].name, newJObject())
        pool.schedules[i].lastRun = currentTime

    await sleepAsync(pool.pollInterval)

proc stuckJobChecker(pool: WorkerPool) {.async.} =
  ## Periodically check for and unlock stuck jobs.
  while pool.running:
    discard unlockStuckJobs(pool.db, pool.stuckTimeout)
    # Check every 60 seconds
    await sleepAsync(60000)

proc startWorkerPool*(pool: WorkerPool) {.async.} =
  ## Start the worker pool with the configured number of workers.
  pool.running = true

  # Start worker loops
  var futures: seq[Future[void]] = @[]
  for i in 0 ..< pool.poolSize:
    futures.add(workerLoop(pool, i))

  # Start scheduler loop
  futures.add(schedulerLoop(pool))

  # Start stuck job checker
  futures.add(stuckJobChecker(pool))

  # Wait for all to complete (they run until stopped)
  await all(futures)

proc stopWorkerPool*(pool: WorkerPool) =
  ## Stop the worker pool. Workers will finish their current iteration and exit.
  pool.running = false

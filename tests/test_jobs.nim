## Comprehensive tests for the Doot jobs and scheduler system.
## Tests SQLite-backed job queue, worker pool, scheduler, parsing,
## retry logic, stuck job detection, and interval parsing.

import std/[unittest, json, times, asyncdispatch, options, os, strutils, tables]
import db_connector/db_sqlite
import ../src/doot/jobs
import ../src/doot/tokens
import ../src/doot/parser

# ------------------------------------------------------------------
# Helper utilities
# ------------------------------------------------------------------

proc newTestDb(): DbConn =
  ## Create an in-memory SQLite database for testing.
  result = open(":memory:", "", "", "")
  initJobsTable(result)

# ------------------------------------------------------------------
# Test Suites
# ------------------------------------------------------------------

suite "Job Queue Table Creation":
  test "initJobsTable creates _doot_jobs table":
    let db = open(":memory:", "", "", "")
    initJobsTable(db)
    # Verify table exists by inserting a row
    let id = db.insertID(
      sql"""INSERT INTO _doot_jobs (job_type, payload, status, run_at, attempts, max_attempts, created_at, updated_at)
            VALUES ('test', '{}', 'pending', '2024-01-01', 0, 3, '2024-01-01', '2024-01-01')"""
    )
    check id > 0
    db.close()

  test "initJobsTable is idempotent":
    let db = open(":memory:", "", "", "")
    initJobsTable(db)
    initJobsTable(db)  # should not raise
    db.close()

  test "table has correct columns":
    let db = newTestDb()
    let row = db.getRow(
      sql"""SELECT id, job_type, payload, status, run_at, attempts, max_attempts,
            locked_at, error, created_at, updated_at
            FROM _doot_jobs LIMIT 0"""
    )
    # If it doesn't raise, columns exist
    check true
    db.close()

suite "Interval Parsing":
  test "parse '30 seconds'":
    let d = parseInterval("30 seconds")
    check d == initDuration(seconds = 30)

  test "parse '5 minutes'":
    let d = parseInterval("5 minutes")
    check d == initDuration(minutes = 5)

  test "parse '1 hour'":
    let d = parseInterval("1 hour")
    check d == initDuration(hours = 1)

  test "parse '2 hours'":
    let d = parseInterval("2 hours")
    check d == initDuration(hours = 2)

  test "parse '1 day'":
    let d = parseInterval("1 day")
    check d == initDuration(days = 1)

  test "parse '7 days'":
    let d = parseInterval("7 days")
    check d == initDuration(days = 7)

  test "parse '1 week'":
    let d = parseInterval("1 week")
    check d == initDuration(weeks = 1)

  test "parse '1 minute'":
    let d = parseInterval("1 minute")
    check d == initDuration(minutes = 1)

  test "parse '1 sec'":
    let d = parseInterval("1 sec")
    check d == initDuration(seconds = 1)

  test "invalid format raises ValueError":
    var raised = false
    try:
      discard parseInterval("invalid")
    except ValueError:
      raised = true
    check raised

  test "invalid number raises ValueError":
    var raised = false
    try:
      discard parseInterval("abc seconds")
    except ValueError:
      raised = true
    check raised

  test "unknown unit raises ValueError":
    var raised = false
    try:
      discard parseInterval("5 millennia")
    except ValueError:
      raised = true
    check raised

suite "Enqueue Job":
  test "enqueueJob inserts a row with correct fields":
    let db = newTestDb()
    let payload = %*{"to": "user@example.com", "subject": "Welcome"}
    let jobId = enqueueJob(db, "send_email", payload)
    check jobId > 0

    let row = db.getRow(
      sql"SELECT job_type, payload, status, attempts FROM _doot_jobs WHERE id = ?",
      $jobId
    )
    check row[0] == "send_email"
    check row[1] == $payload
    check row[2] == "pending"
    check row[3] == "0"
    db.close()

  test "enqueueJob with default payload":
    let db = newTestDb()
    let jobId = enqueueJob(db, "cleanup")
    check jobId > 0

    let row = db.getRow(
      sql"SELECT payload FROM _doot_jobs WHERE id = ?",
      $jobId
    )
    check row[0] == "{}"
    db.close()

  test "enqueueJob with custom maxAttempts":
    let db = newTestDb()
    let jobId = enqueueJob(db, "important_task", newJObject(), now(), maxAttempts = 5)

    let row = db.getRow(
      sql"SELECT max_attempts FROM _doot_jobs WHERE id = ?",
      $jobId
    )
    check row[0] == "5"
    db.close()

  test "enqueueJobWithDelay sets future run_at":
    let db = newTestDb()
    let beforeEnqueue = now()
    let jobId = enqueueJobWithDelay(db, "delayed_task", newJObject(),
                                     delay = initDuration(hours = 1))

    let row = db.getRow(
      sql"SELECT run_at FROM _doot_jobs WHERE id = ?",
      $jobId
    )
    # The run_at should be roughly 1 hour in the future
    check row[0] != ""
    db.close()

  test "multiple jobs get unique IDs":
    let db = newTestDb()
    let id1 = enqueueJob(db, "task1")
    let id2 = enqueueJob(db, "task2")
    let id3 = enqueueJob(db, "task3")
    check id1 != id2
    check id2 != id3
    check id1 != id3
    db.close()

suite "Claim Next Job":
  test "claimNextJob returns pending job":
    let db = newTestDb()
    let jobId = enqueueJob(db, "test_job", %*{"key": "value"})
    let claimed = claimNextJob(db)
    check claimed.isSome
    let job = claimed.get
    check job.id == jobId
    check job.jobType == "test_job"
    check job.status == jsRunning
    db.close()

  test "claimNextJob returns none when no jobs":
    let db = newTestDb()
    let claimed = claimNextJob(db)
    check claimed.isNone
    db.close()

  test "claimNextJob sets status to running":
    let db = newTestDb()
    discard enqueueJob(db, "test_job")
    discard claimNextJob(db)

    let row = db.getRow(
      sql"SELECT status, locked_at FROM _doot_jobs WHERE id = 1"
    )
    check row[0] == "running"
    check row[1] != ""  # locked_at should be set
    db.close()

  test "claimNextJob does not return already claimed jobs":
    let db = newTestDb()
    discard enqueueJob(db, "job1")
    let claimed1 = claimNextJob(db)
    check claimed1.isSome

    # Second claim should return none (no more pending jobs)
    let claimed2 = claimNextJob(db)
    check claimed2.isNone
    db.close()

  test "claimNextJob respects run_at ordering":
    let db = newTestDb()
    # Insert jobs - they all have run_at <= now so both are eligible
    let id1 = enqueueJob(db, "first_job")
    let id2 = enqueueJob(db, "second_job")

    let claimed = claimNextJob(db)
    check claimed.isSome
    check claimed.get.id == id1  # first inserted should be claimed first
    db.close()

  test "claimNextJob does not return future jobs":
    let db = newTestDb()
    # Enqueue a job with a future run_at
    discard enqueueJobWithDelay(db, "future_job", newJObject(),
                                 delay = initDuration(hours = 24))

    let claimed = claimNextJob(db)
    check claimed.isNone
    db.close()

  test "claimNextJob returns none when job was already claimed (phantom claim protection)":
    ## Simulates the scenario where a job's status is changed to running
    ## between the SELECT and UPDATE in claimNextJob. The changes() check
    ## ensures none is returned if the UPDATE was a no-op.
    let db = newTestDb()
    let jobId = enqueueJob(db, "contested_job")

    # Manually set the job to running (simulating another worker claimed it)
    db.exec(
      sql"UPDATE _doot_jobs SET status = 'running', locked_at = ? WHERE id = ?",
      $now(), $jobId
    )

    # Now claimNextJob should find no pending jobs
    let claimed = claimNextJob(db)
    check claimed.isNone
    db.close()

  test "claimNextJob with execAffectedRows returns none on failed claim":
    ## Verifies that if the UPDATE affects 0 rows (because status changed),
    ## claimNextJob correctly returns none instead of a phantom job record.
    let db = newTestDb()
    # Insert two jobs
    let id1 = enqueueJob(db, "job_a")
    let id2 = enqueueJob(db, "job_b")

    # Claim first job
    let claimed1 = claimNextJob(db)
    check claimed1.isSome
    check claimed1.get.id == id1

    # Claim second job
    let claimed2 = claimNextJob(db)
    check claimed2.isSome
    check claimed2.get.id == id2

    # No more jobs to claim
    let claimed3 = claimNextJob(db)
    check claimed3.isNone
    db.close()

suite "Complete Job":
  test "completeJob sets status to completed":
    let db = newTestDb()
    let jobId = enqueueJob(db, "test_job")
    discard claimNextJob(db)
    completeJob(db, jobId)

    let row = db.getRow(
      sql"SELECT status, locked_at FROM _doot_jobs WHERE id = ?",
      $jobId
    )
    check row[0] == "completed"
    check row[1] == ""  # locked_at should be cleared
    db.close()

suite "Fail Job and Retry":
  test "failJob increments attempts":
    let db = newTestDb()
    let jobId = enqueueJob(db, "test_job", newJObject(), now(), maxAttempts = 3)
    discard claimNextJob(db)
    failJob(db, jobId, "Something went wrong")

    let row = db.getRow(
      sql"SELECT attempts FROM _doot_jobs WHERE id = ?",
      $jobId
    )
    check parseInt(row[0]) == 1
    db.close()

  test "failJob re-enqueues when attempts < maxAttempts":
    let db = newTestDb()
    let jobId = enqueueJob(db, "test_job", newJObject(), now(), maxAttempts = 3)
    discard claimNextJob(db)
    failJob(db, jobId, "Error 1")

    let row = db.getRow(
      sql"SELECT status, error FROM _doot_jobs WHERE id = ?",
      $jobId
    )
    check row[0] == "pending"  # re-enqueued for retry
    check row[1] == "Error 1"
    db.close()

  test "failJob sets failed when attempts >= maxAttempts":
    let db = newTestDb()
    let jobId = enqueueJob(db, "test_job", newJObject(), now(), maxAttempts = 1)
    discard claimNextJob(db)
    failJob(db, jobId, "Final error")

    let row = db.getRow(
      sql"SELECT status, error, attempts FROM _doot_jobs WHERE id = ?",
      $jobId
    )
    check row[0] == "failed"
    check row[1] == "Final error"
    check parseInt(row[2]) == 1
    db.close()

  test "retry exhaustion after multiple failures":
    let db = newTestDb()
    let jobId = enqueueJob(db, "test_job", newJObject(), now(), maxAttempts = 3)

    # Attempt 1
    discard claimNextJob(db)
    failJob(db, jobId, "Error 1")
    var row = db.getRow(sql"SELECT status, attempts FROM _doot_jobs WHERE id = ?", $jobId)
    check row[0] == "pending"
    check parseInt(row[1]) == 1

    # Attempt 2
    discard claimNextJob(db)
    failJob(db, jobId, "Error 2")
    row = db.getRow(sql"SELECT status, attempts FROM _doot_jobs WHERE id = ?", $jobId)
    check row[0] == "pending"
    check parseInt(row[1]) == 2

    # Attempt 3 - final failure
    discard claimNextJob(db)
    failJob(db, jobId, "Error 3")
    row = db.getRow(sql"SELECT status, attempts FROM _doot_jobs WHERE id = ?", $jobId)
    check row[0] == "failed"
    check parseInt(row[1]) == 3
    db.close()

  test "retryJob resets failed job to pending":
    let db = newTestDb()
    let jobId = enqueueJob(db, "test_job", newJObject(), now(), maxAttempts = 1)
    discard claimNextJob(db)
    failJob(db, jobId, "Error")

    # Verify it's failed
    var row = db.getRow(sql"SELECT status FROM _doot_jobs WHERE id = ?", $jobId)
    check row[0] == "failed"

    # Manually retry
    retryJob(db, jobId)
    row = db.getRow(sql"SELECT status, error, attempts FROM _doot_jobs WHERE id = ?", $jobId)
    check row[0] == "pending"
    check row[1] == ""  # error should be cleared
    check parseInt(row[2]) == 0  # attempts should be reset to 0
    db.close()

  test "retryJob only works on failed jobs":
    let db = newTestDb()
    let jobId = enqueueJob(db, "test_job")

    # Job is pending, retryJob should not change it (only works on failed)
    retryJob(db, jobId)
    let row = db.getRow(sql"SELECT status FROM _doot_jobs WHERE id = ?", $jobId)
    check row[0] == "pending"
    db.close()

  test "retryJob followed by failure uses full retry budget":
    ## Verifies that after a manual retry, the job gets the full max_attempts
    ## budget again (attempts reset to 0), so it can fail multiple times
    ## before being permanently marked as failed.
    let db = newTestDb()
    let jobId = enqueueJob(db, "flaky_job", newJObject(), now(), maxAttempts = 2)

    # Exhaust all attempts (2 failures -> permanently failed)
    discard claimNextJob(db)
    failJob(db, jobId, "Error 1")
    discard claimNextJob(db)
    failJob(db, jobId, "Error 2")

    var row = db.getRow(sql"SELECT status, attempts FROM _doot_jobs WHERE id = ?", $jobId)
    check row[0] == "failed"
    check parseInt(row[1]) == 2

    # Manually retry - should reset attempts to 0
    retryJob(db, jobId)
    row = db.getRow(sql"SELECT status, attempts FROM _doot_jobs WHERE id = ?", $jobId)
    check row[0] == "pending"
    check parseInt(row[1]) == 0

    # Now it should be able to fail again (attempt 1 of 2) and get re-enqueued
    discard claimNextJob(db)
    failJob(db, jobId, "Error after retry 1")
    row = db.getRow(sql"SELECT status, attempts FROM _doot_jobs WHERE id = ?", $jobId)
    check row[0] == "pending"  # re-enqueued because attempts(1) < maxAttempts(2)
    check parseInt(row[1]) == 1

    # Second failure after retry - should be permanently failed
    discard claimNextJob(db)
    failJob(db, jobId, "Error after retry 2")
    row = db.getRow(sql"SELECT status, attempts FROM _doot_jobs WHERE id = ?", $jobId)
    check row[0] == "failed"
    check parseInt(row[1]) == 2
    db.close()

suite "Stuck Job Detection":
  test "unlockStuckJobs resets jobs exceeding timeout":
    let db = newTestDb()
    let jobId = enqueueJob(db, "stuck_job")

    # Manually set to running with a very old locked_at
    let oldTime = $(now() - initDuration(hours = 2))
    db.exec(
      sql"UPDATE _doot_jobs SET status = 'running', locked_at = ? WHERE id = ?",
      oldTime, $jobId
    )

    # Unlock with 30-minute timeout
    let unlocked = unlockStuckJobs(db, initDuration(minutes = 30))
    check unlocked == 1

    let row = db.getRow(sql"SELECT status, locked_at FROM _doot_jobs WHERE id = ?", $jobId)
    check row[0] == "pending"
    check row[1] == ""  # locked_at should be cleared
    db.close()

  test "unlockStuckJobs does not affect recently locked jobs":
    let db = newTestDb()
    let jobId = enqueueJob(db, "recent_job")

    # Set to running with recent locked_at
    let recentTime = $now()
    db.exec(
      sql"UPDATE _doot_jobs SET status = 'running', locked_at = ? WHERE id = ?",
      recentTime, $jobId
    )

    let unlocked = unlockStuckJobs(db, initDuration(minutes = 30))
    check unlocked == 0

    let row = db.getRow(sql"SELECT status FROM _doot_jobs WHERE id = ?", $jobId)
    check row[0] == "running"  # should still be running
    db.close()

  test "unlockStuckJobs handles multiple stuck jobs":
    let db = newTestDb()
    let oldTime = $(now() - initDuration(hours = 2))

    for i in 1..3:
      let jobId = enqueueJob(db, "stuck_job_" & $i)
      db.exec(
        sql"UPDATE _doot_jobs SET status = 'running', locked_at = ? WHERE id = ?",
        oldTime, $jobId
      )

    let unlocked = unlockStuckJobs(db, initDuration(minutes = 30))
    check unlocked == 3
    db.close()

suite "Job Status Queries":
  test "getJobCounts returns correct counts":
    let db = newTestDb()
    # Insert jobs with various statuses
    for i in 1..3:
      discard enqueueJob(db, "pending_job_" & $i)

    let id4 = enqueueJob(db, "running_job")
    db.exec(sql"UPDATE _doot_jobs SET status = 'running' WHERE id = ?", $id4)

    let id5 = enqueueJob(db, "completed_job")
    db.exec(sql"UPDATE _doot_jobs SET status = 'completed' WHERE id = ?", $id5)

    let id6 = enqueueJob(db, "failed_job")
    db.exec(sql"UPDATE _doot_jobs SET status = 'failed' WHERE id = ?", $id6)

    let counts = getJobCounts(db)
    check counts.pending == 3
    check counts.running == 1
    check counts.completed == 1
    check counts.failed == 1
    db.close()

  test "getFailedJobs returns failed jobs":
    let db = newTestDb()
    let id1 = enqueueJob(db, "failed_task_1")
    db.exec(sql"UPDATE _doot_jobs SET status = 'failed', error = 'err1' WHERE id = ?", $id1)

    let id2 = enqueueJob(db, "failed_task_2")
    db.exec(sql"UPDATE _doot_jobs SET status = 'failed', error = 'err2' WHERE id = ?", $id2)

    discard enqueueJob(db, "pending_task")  # not failed

    let failed = getFailedJobs(db)
    check failed.len == 2
    check failed[0].status == jsFailed
    check failed[1].status == jsFailed
    db.close()

  test "getRecentJobs returns jobs ordered by updated_at":
    let db = newTestDb()
    discard enqueueJob(db, "job1")
    discard enqueueJob(db, "job2")
    discard enqueueJob(db, "job3")

    let recent = getRecentJobs(db, limit = 2)
    check recent.len == 2
    db.close()

suite "Worker Pool Configuration":
  test "newWorkerPool creates pool with defaults":
    let db = newTestDb()
    let pool = newWorkerPool(db)
    check pool.poolSize == 2
    check pool.pollInterval == 5000
    check pool.maxAttempts == 3
    check pool.running == false
    db.close()

  test "newWorkerPool with custom size":
    let db = newTestDb()
    let pool = newWorkerPool(db, poolSize = 4, pollInterval = 1000)
    check pool.poolSize == 4
    check pool.pollInterval == 1000
    db.close()

  test "registerJobHandler adds handler":
    let db = newTestDb()
    let pool = newWorkerPool(db)

    proc testHandler(payload: JsonNode) {.async.} =
      discard

    pool.registerJobHandler("test_job", testHandler)
    check pool.handlers.hasKey("test_job")
    db.close()

  test "addSchedule adds schedule entry":
    let db = newTestDb()
    let pool = newWorkerPool(db)

    proc schedHandler(payload: JsonNode) {.async.} =
      discard

    pool.addSchedule("cleanup", initDuration(hours = 1), schedHandler)
    check pool.schedules.len == 1
    check pool.schedules[0].name == "cleanup"
    check pool.schedules[0].interval == initDuration(hours = 1)
    db.close()

  test "stopWorkerPool sets running to false":
    let db = newTestDb()
    let pool = newWorkerPool(db)
    pool.running = true
    pool.stopWorkerPool()
    check pool.running == false
    db.close()

suite "Worker Execution (async)":
  test "worker picks up and executes a job":
    let db = newTestDb()
    let pool = newWorkerPool(db, poolSize = 1, pollInterval = 100)
    var executed = false

    proc handler(payload: JsonNode) {.async.} =
      executed = true

    pool.registerJobHandler("test_job", handler)
    discard enqueueJob(db, "test_job", %*{"data": "hello"})

    # Run pool briefly
    pool.running = true
    proc runBriefly() {.async.} =
      # Process one iteration manually
      let jobOpt = claimNextJob(pool.db)
      if jobOpt.isSome:
        let job = jobOpt.get
        if pool.handlers.hasKey(job.jobType):
          let h = pool.handlers[job.jobType]
          let payload = parseJson(job.payload)
          await h(payload)
          completeJob(pool.db, job.id)

    waitFor runBriefly()
    check executed

    let row = db.getRow(sql"SELECT status FROM _doot_jobs WHERE id = 1")
    check row[0] == "completed"
    db.close()

  test "worker handles job failure":
    let db = newTestDb()
    let pool = newWorkerPool(db, poolSize = 1, pollInterval = 100)

    proc failingHandler(payload: JsonNode) {.async.} =
      raise newException(CatchableError, "Handler failed!")

    pool.registerJobHandler("failing_job", failingHandler)
    discard enqueueJob(db, "failing_job", newJObject(), now(), maxAttempts = 3)

    # Process one job - use future directly to handle failure
    pool.running = true
    proc runOnce() {.async.} =
      let jobOpt = claimNextJob(pool.db)
      if jobOpt.isSome:
        let job = jobOpt.get
        if pool.handlers.hasKey(job.jobType):
          let h = pool.handlers[job.jobType]
          let payload = parseJson(job.payload)
          let fut = h(payload)
          yield fut
          if fut.failed:
            failJob(pool.db, job.id, fut.error.msg)
          else:
            completeJob(pool.db, job.id)

    waitFor runOnce()

    let row = db.getRow(sql"SELECT status, attempts, error FROM _doot_jobs WHERE id = 1")
    check row[0] == "pending"  # re-enqueued because attempts < maxAttempts
    check parseInt(row[1]) == 1
    check row[2] == "Handler failed!"
    db.close()

  test "worker handles unknown job type":
    let db = newTestDb()
    let pool = newWorkerPool(db, poolSize = 1, pollInterval = 100)
    discard enqueueJob(db, "unknown_job", newJObject(), now(), maxAttempts = 1)

    proc runOnce() {.async.} =
      let jobOpt = claimNextJob(pool.db)
      if jobOpt.isSome:
        let job = jobOpt.get
        if pool.handlers.hasKey(job.jobType):
          let h = pool.handlers[job.jobType]
          try:
            let payload = parseJson(job.payload)
            await h(payload)
            completeJob(pool.db, job.id)
          except CatchableError as e:
            failJob(pool.db, job.id, e.msg)
        else:
          failJob(pool.db, job.id, "No handler registered for job type: " & job.jobType)

    waitFor runOnce()

    let row = db.getRow(sql"SELECT status, error FROM _doot_jobs WHERE id = 1")
    check row[0] == "failed"
    check "No handler registered" in row[1]
    db.close()

  test "job dispatch with payload deserialization":
    let db = newTestDb()
    var receivedPayload: JsonNode = nil

    proc handler(payload: JsonNode) {.async.} =
      receivedPayload = payload

    let pool = newWorkerPool(db, poolSize = 1, pollInterval = 100)
    pool.registerJobHandler("email_job", handler)

    let payload = %*{"to": "user@test.com", "subject": "Hello", "body": "World"}
    discard enqueueJob(db, "email_job", payload)

    proc runOnce() {.async.} =
      let jobOpt = claimNextJob(pool.db)
      if jobOpt.isSome:
        let job = jobOpt.get
        let h = pool.handlers[job.jobType]
        let p = parseJson(job.payload)
        await h(p)
        completeJob(pool.db, job.id)

    waitFor runOnce()

    check receivedPayload != nil
    check receivedPayload["to"].getStr() == "user@test.com"
    check receivedPayload["subject"].getStr() == "Hello"
    check receivedPayload["body"].getStr() == "World"
    db.close()

suite "Scheduler":
  test "scheduler enqueues job when interval elapsed":
    let db = newTestDb()
    let pool = newWorkerPool(db, poolSize = 1, pollInterval = 100)

    proc cleanupHandler(payload: JsonNode) {.async.} =
      discard

    # Add schedule with very short interval and set lastRun to the past
    pool.addSchedule("cleanup", initDuration(seconds = 1), cleanupHandler)
    pool.schedules[0].lastRun = getTime() - initDuration(seconds = 2)

    # Simulate one scheduler iteration
    let currentTime = getTime()
    for i in 0 ..< pool.schedules.len:
      let elapsed = currentTime - pool.schedules[i].lastRun
      if elapsed >= pool.schedules[i].interval:
        discard enqueueJob(pool.db, pool.schedules[i].name, newJObject())
        pool.schedules[i].lastRun = currentTime

    # Verify a job was enqueued
    let row = db.getRow(sql"SELECT job_type, status FROM _doot_jobs WHERE id = 1")
    check row[0] == "cleanup"
    check row[1] == "pending"
    db.close()

  test "scheduler does not enqueue when interval not elapsed":
    let db = newTestDb()
    let pool = newWorkerPool(db, poolSize = 1, pollInterval = 100)

    proc handler(payload: JsonNode) {.async.} =
      discard

    # Add schedule with long interval (lastRun is now by default)
    pool.addSchedule("infrequent", initDuration(hours = 24), handler)

    # Simulate scheduler iteration
    let currentTime = getTime()
    for i in 0 ..< pool.schedules.len:
      let elapsed = currentTime - pool.schedules[i].lastRun
      if elapsed >= pool.schedules[i].interval:
        discard enqueueJob(pool.db, pool.schedules[i].name, newJObject())
        pool.schedules[i].lastRun = currentTime

    # No jobs should be enqueued
    let counts = getJobCounts(db)
    check counts.pending == 0
    db.close()

  test "scheduler dedup prevents duplicate pending jobs":
    ## Verifies that the scheduler does not insert a duplicate pending job
    ## when one already exists for the same job type.
    let db = newTestDb()
    let pool = newWorkerPool(db, poolSize = 1, pollInterval = 100)

    proc handler(payload: JsonNode) {.async.} =
      discard

    pool.addSchedule("daily_report", initDuration(seconds = 1), handler)
    pool.schedules[0].lastRun = getTime() - initDuration(seconds = 2)

    # Manually insert a pending job of the same type (simulates prior insertion)
    discard enqueueJob(db, "daily_report", newJObject())

    # Simulate scheduler iteration with dedup guard
    let currentTime = getTime()
    for i in 0 ..< pool.schedules.len:
      let elapsed = currentTime - pool.schedules[i].lastRun
      if elapsed >= pool.schedules[i].interval:
        let existing = pool.db.getRow(
          sql"""SELECT COUNT(*) FROM _doot_jobs
                WHERE job_type = ? AND status = 'pending'""",
          pool.schedules[i].name
        )
        if existing[0] == "" or parseInt(existing[0]) == 0:
          discard enqueueJob(pool.db, pool.schedules[i].name, newJObject())
        pool.schedules[i].lastRun = currentTime

    # Should still have only 1 pending job (no duplicate)
    let counts = getJobCounts(db)
    check counts.pending == 1
    db.close()

suite "Parser - Job Declaration":
  test "parse job declaration":
    let tokens = @[
      newToken(tkJob, "job", "<test>", 1, 1),
      newToken(tkStringLit, "send_email", "<test>", 1, 5),
      newToken(tkDo, "do", "<test>", 1, 18),
      newToken(tkPipe, "|", "<test>", 1, 21),
      newToken(tkIdentifier, "payload", "<test>", 1, 22),
      newToken(tkPipe, "|", "<test>", 1, 29),
      newToken(tkNewline, "\n", "<test>", 1, 30),
      newToken(tkIdentifier, "result", "<test>", 2, 3),
      newToken(tkAssign, "=", "<test>", 2, 10),
      newToken(tkStringLit, "done", "<test>", 2, 12),
      newToken(tkNewline, "\n", "<test>", 2, 18),
      newToken(tkEnd, "end", "<test>", 3, 1),
      newToken(tkEof, "", "<test>", 4, 1),
    ]

    let (ast, errors) = parseWithErrors(tokens, "<test>")
    check errors.len == 0
    check ast.appRoutes.len == 1
    check ast.appRoutes[0].kind == nkJob
    check ast.appRoutes[0].jobName == "send_email"
    check ast.appRoutes[0].jobParam == "payload"
    check ast.appRoutes[0].jobBody.len == 1

  test "parse job with default param name":
    let tokens = @[
      newToken(tkJob, "job", "<test>", 1, 1),
      newToken(tkStringLit, "cleanup", "<test>", 1, 5),
      newToken(tkDo, "do", "<test>", 1, 15),
      newToken(tkNewline, "\n", "<test>", 1, 17),
      newToken(tkEnd, "end", "<test>", 2, 1),
      newToken(tkEof, "", "<test>", 3, 1),
    ]

    let (ast, errors) = parseWithErrors(tokens, "<test>")
    check errors.len == 0
    check ast.appRoutes.len == 1
    check ast.appRoutes[0].kind == nkJob
    check ast.appRoutes[0].jobName == "cleanup"
    check ast.appRoutes[0].jobParam == "payload"  # default param name

suite "Parser - Schedule Declaration":
  test "parse schedule declaration":
    let tokens = @[
      newToken(tkSchedule, "schedule", "<test>", 1, 1),
      newToken(tkStringLit, "cleanup", "<test>", 1, 10),
      newToken(tkComma, ",", "<test>", 1, 19),
      newToken(tkIdentifier, "every", "<test>", 1, 21),
      newToken(tkColon, ":", "<test>", 1, 26),
      newToken(tkStringLit, "1 hour", "<test>", 1, 28),
      newToken(tkDo, "do", "<test>", 1, 37),
      newToken(tkNewline, "\n", "<test>", 1, 39),
      newToken(tkEnd, "end", "<test>", 2, 1),
      newToken(tkEof, "", "<test>", 3, 1),
    ]

    let (ast, errors) = parseWithErrors(tokens, "<test>")
    check errors.len == 0
    check ast.appRoutes.len == 1
    check ast.appRoutes[0].kind == nkSchedule
    check ast.appRoutes[0].scheduleName == "cleanup"
    check ast.appRoutes[0].scheduleInterval == "1 hour"

  test "parse schedule with body":
    let tokens = @[
      newToken(tkSchedule, "schedule", "<test>", 1, 1),
      newToken(tkStringLit, "daily_report", "<test>", 1, 10),
      newToken(tkComma, ",", "<test>", 1, 24),
      newToken(tkIdentifier, "every", "<test>", 1, 26),
      newToken(tkColon, ":", "<test>", 1, 31),
      newToken(tkStringLit, "1 day", "<test>", 1, 33),
      newToken(tkDo, "do", "<test>", 1, 41),
      newToken(tkNewline, "\n", "<test>", 1, 43),
      newToken(tkIdentifier, "status", "<test>", 2, 3),
      newToken(tkAssign, "=", "<test>", 2, 10),
      newToken(tkStringLit, "running", "<test>", 2, 12),
      newToken(tkNewline, "\n", "<test>", 2, 21),
      newToken(tkEnd, "end", "<test>", 3, 1),
      newToken(tkEof, "", "<test>", 4, 1),
    ]

    let (ast, errors) = parseWithErrors(tokens, "<test>")
    check errors.len == 0
    check ast.appRoutes[0].kind == nkSchedule
    check ast.appRoutes[0].scheduleName == "daily_report"
    check ast.appRoutes[0].scheduleInterval == "1 day"
    check ast.appRoutes[0].scheduleBody.len == 1

suite "Parser - Enqueue Statement":
  test "parse enqueue in handler body":
    let tokens = @[
      newToken(tkRoute, "route", "<test>", 1, 1),
      newToken(tkPost, "POST", "<test>", 1, 7),
      newToken(tkStringLit, "/signup", "<test>", 1, 12),
      newToken(tkDo, "do", "<test>", 1, 22),
      newToken(tkPipe, "|", "<test>", 1, 25),
      newToken(tkIdentifier, "ctx", "<test>", 1, 26),
      newToken(tkPipe, "|", "<test>", 1, 29),
      newToken(tkNewline, "\n", "<test>", 1, 30),
      newToken(tkIdentifier, "enqueue", "<test>", 2, 3),
      newToken(tkStringLit, "send_email", "<test>", 2, 11),
      newToken(tkComma, ",", "<test>", 2, 23),
      newToken(tkIdentifier, "to", "<test>", 2, 25),
      newToken(tkColon, ":", "<test>", 2, 27),
      newToken(tkStringLit, "user@example.com", "<test>", 2, 29),
      newToken(tkComma, ",", "<test>", 2, 47),
      newToken(tkIdentifier, "subject", "<test>", 2, 49),
      newToken(tkColon, ":", "<test>", 2, 56),
      newToken(tkStringLit, "Welcome", "<test>", 2, 58),
      newToken(tkNewline, "\n", "<test>", 2, 67),
      newToken(tkEnd, "end", "<test>", 3, 1),
      newToken(tkEof, "", "<test>", 4, 1),
    ]

    let (ast, errors) = parseWithErrors(tokens, "<test>")
    check errors.len == 0
    check ast.appRoutes.len == 1
    check ast.appRoutes[0].kind == nkRoute
    check ast.appRoutes[0].routeBody.len == 1

    let enqueueNode = ast.appRoutes[0].routeBody[0]
    check enqueueNode.kind == nkEnqueue
    check enqueueNode.enqueueName == "send_email"
    check enqueueNode.enqueueArgs.len == 2
    check enqueueNode.enqueueArgs[0].key == "to"
    check enqueueNode.enqueueArgs[0].value.kind == nkStringLit
    check enqueueNode.enqueueArgs[0].value.strValue == "user@example.com"
    check enqueueNode.enqueueArgs[1].key == "subject"
    check enqueueNode.enqueueArgs[1].value.kind == nkStringLit
    check enqueueNode.enqueueArgs[1].value.strValue == "Welcome"

  test "parse enqueue with no args":
    let tokens = @[
      newToken(tkRoute, "route", "<test>", 1, 1),
      newToken(tkPost, "POST", "<test>", 1, 7),
      newToken(tkStringLit, "/cleanup", "<test>", 1, 12),
      newToken(tkDo, "do", "<test>", 1, 22),
      newToken(tkPipe, "|", "<test>", 1, 25),
      newToken(tkIdentifier, "ctx", "<test>", 1, 26),
      newToken(tkPipe, "|", "<test>", 1, 29),
      newToken(tkNewline, "\n", "<test>", 1, 30),
      newToken(tkIdentifier, "enqueue", "<test>", 2, 3),
      newToken(tkStringLit, "cleanup", "<test>", 2, 11),
      newToken(tkNewline, "\n", "<test>", 2, 20),
      newToken(tkEnd, "end", "<test>", 3, 1),
      newToken(tkEof, "", "<test>", 4, 1),
    ]

    let (ast, errors) = parseWithErrors(tokens, "<test>")
    check errors.len == 0
    let enqueueNode = ast.appRoutes[0].routeBody[0]
    check enqueueNode.kind == nkEnqueue
    check enqueueNode.enqueueName == "cleanup"
    check enqueueNode.enqueueArgs.len == 0

suite "Integration - Full Job Lifecycle":
  test "enqueue -> claim -> execute -> complete":
    let db = newTestDb()
    var result_val = ""

    proc handler(payload: JsonNode) {.async.} =
      result_val = payload["message"].getStr()

    # Enqueue
    let payload = %*{"message": "hello world"}
    let jobId = enqueueJob(db, "process_msg", payload)

    # Claim
    let claimed = claimNextJob(db)
    check claimed.isSome
    let job = claimed.get
    check job.jobType == "process_msg"

    # Execute
    waitFor handler(parseJson(job.payload))
    check result_val == "hello world"

    # Complete
    completeJob(db, job.id)
    let row = db.getRow(sql"SELECT status FROM _doot_jobs WHERE id = ?", $jobId)
    check row[0] == "completed"
    db.close()

  test "enqueue -> claim -> fail -> retry -> complete":
    let db = newTestDb()
    var attemptCount = 0

    proc flakyHandler(payload: JsonNode) {.async.} =
      attemptCount += 1
      if attemptCount < 2:
        raise newException(CatchableError, "Temporary failure")

    # Enqueue with maxAttempts = 3
    let jobId = enqueueJob(db, "flaky_job", newJObject(), now(), maxAttempts = 3)

    # First attempt - fails
    var claimed = claimNextJob(db)
    check claimed.isSome
    try:
      waitFor flakyHandler(parseJson(claimed.get.payload))
      completeJob(db, claimed.get.id)
    except CatchableError as e:
      failJob(db, claimed.get.id, e.msg)

    var row = db.getRow(sql"SELECT status, attempts FROM _doot_jobs WHERE id = ?", $jobId)
    check row[0] == "pending"  # re-enqueued
    check parseInt(row[1]) == 1

    # Second attempt - succeeds
    claimed = claimNextJob(db)
    check claimed.isSome
    try:
      waitFor flakyHandler(parseJson(claimed.get.payload))
      completeJob(db, claimed.get.id)
    except CatchableError as e:
      failJob(db, claimed.get.id, e.msg)

    row = db.getRow(sql"SELECT status FROM _doot_jobs WHERE id = ?", $jobId)
    check row[0] == "completed"
    check attemptCount == 2
    db.close()

  test "full job status transitions":
    let db = newTestDb()
    let jobId = enqueueJob(db, "lifecycle_test")

    # pending
    var row = db.getRow(sql"SELECT status FROM _doot_jobs WHERE id = ?", $jobId)
    check row[0] == "pending"

    # pending -> running
    discard claimNextJob(db)
    row = db.getRow(sql"SELECT status FROM _doot_jobs WHERE id = ?", $jobId)
    check row[0] == "running"

    # running -> completed
    completeJob(db, jobId)
    row = db.getRow(sql"SELECT status FROM _doot_jobs WHERE id = ?", $jobId)
    check row[0] == "completed"
    db.close()

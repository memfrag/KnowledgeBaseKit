import Foundation
import GRDB

public enum JobKind: String, Sendable, CaseIterable, Codable {
    case embed
    case extract
}

public enum JobState: String, Sendable, Codable {
    case pending
    case running
    /// Dead-lettered: attempts exhausted. Skipped by the queue, never retried automatically.
    case failed
}

public struct Job: Sendable, Hashable {
    public var id: Int64
    public var kind: JobKind
    public var targetID: ChunkID
    public var state: JobState
    public var attempts: Int
    public var nextAfter: Date
    public var lastError: String?
    public var createdAt: Date
}

/// The durable background queue behind embedding and extraction.
///
/// Jobs are rows rather than in-memory tasks, so a crash mid-index resumes instead of
/// restarting, and so ingestion can return as soon as chunks and FTS are written.
public enum JobRepository {

    public static func enqueue(
        kind: JobKind,
        targetID: ChunkID,
        in db: Database,
        now: Date = Date()
    ) throws {
        // One outstanding job per (kind, target). Re-enqueuing an existing job resets it to
        // pending with a cleared attempt count — the chunk's content changed, so a previous
        // dead-lettering no longer describes the work at hand.
        try db.execute(
            sql: """
                INSERT INTO jobs (kind, target_id, state, attempts, next_after, last_error, created_at)
                VALUES (?, ?, 'pending', 0, ?, NULL, ?)
                ON CONFLICT(kind, target_id) DO UPDATE SET
                    state      = 'pending',
                    attempts   = 0,
                    next_after = excluded.next_after,
                    last_error = NULL
                """,
            arguments: [
                kind.rawValue,
                targetID.rawValue,
                now.timeIntervalSince1970,
                now.timeIntervalSince1970,
            ]
        )
    }

    public static func enqueueAll(
        kind: JobKind,
        targetIDs: [ChunkID],
        in db: Database,
        now: Date = Date()
    ) throws {
        for id in targetIDs {
            try enqueue(kind: kind, targetID: id, in: db, now: now)
        }
    }

    /// Claims up to `limit` jobs whose backoff has elapsed, marking them `running`.
    ///
    /// Claiming and marking happen in one transaction so that two workers in the same process
    /// cannot take the same job. Cross-process contention is not a concern: writing requires
    /// the exclusive lock, so only one process is ever running jobs.
    public static func claim(
        kind: JobKind,
        limit: Int,
        in db: Database,
        now: Date = Date()
    ) throws -> [Job] {
        let jobs = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM jobs
                 WHERE kind = ? AND state = 'pending' AND next_after <= ?
                 ORDER BY next_after, id
                 LIMIT ?
                """,
            arguments: [kind.rawValue, now.timeIntervalSince1970, limit]
        ).map(decode)

        guard !jobs.isEmpty else { return [] }

        try db.execute(
            sql: "UPDATE jobs SET state = 'running' WHERE id IN (\(databaseQuestionMarks(count: jobs.count)))",
            arguments: StatementArguments(jobs.map(\.id))
        )

        return jobs
    }

    public static func complete(_ job: Job, in db: Database) throws {
        try db.execute(sql: "DELETE FROM jobs WHERE id = ?", arguments: [job.id])
    }

    /// Records a failure, scheduling a retry or dead-lettering when attempts are exhausted.
    ///
    /// `isTransient` marks a failure that is not the job's fault — a connection failure to
    /// Ollama, say. It is rescheduled without consuming an attempt, so an offline laptop does
    /// not dead-letter the entire queue while the user is away.
    public static func fail(
        _ job: Job,
        error: String,
        isTransient: Bool,
        retry: RetryConfiguration,
        in db: Database,
        now: Date = Date()
    ) throws {
        let attempts = isTransient ? job.attempts : job.attempts + 1

        if !isTransient, attempts >= retry.maximumAttempts {
            try db.execute(
                sql: "UPDATE jobs SET state = 'failed', attempts = ?, last_error = ? WHERE id = ?",
                arguments: [attempts, error, job.id]
            )
            return
        }

        // Transient failures still back off, so an unreachable server is polled at a capped
        // interval rather than spun on.
        let delay = retry.backoff(forAttempt: isTransient ? 1 : attempts)
        try db.execute(
            sql: """
                UPDATE jobs
                   SET state = 'pending', attempts = ?, next_after = ?, last_error = ?
                 WHERE id = ?
                """,
            arguments: [attempts, now.addingTimeInterval(delay).timeIntervalSince1970, error, job.id]
        )
    }

    /// Returns dead-lettered jobs to the queue with a cleared attempt count.
    @discardableResult
    public static func retryFailed(kind: JobKind?, in db: Database, now: Date = Date()) throws -> Int {
        let sql: String
        let arguments: StatementArguments
        if let kind {
            sql = """
                UPDATE jobs SET state = 'pending', attempts = 0, next_after = ?, last_error = NULL
                 WHERE state = 'failed' AND kind = ?
                """
            arguments = [now.timeIntervalSince1970, kind.rawValue]
        } else {
            sql = """
                UPDATE jobs SET state = 'pending', attempts = 0, next_after = ?, last_error = NULL
                 WHERE state = 'failed'
                """
            arguments = [now.timeIntervalSince1970]
        }
        try db.execute(sql: sql, arguments: arguments)
        return db.changesCount
    }

    /// Returns any `running` jobs to `pending`.
    ///
    /// Called on open: a job left `running` belonged to a process that died, and since only
    /// one process may write, nothing else can still be working on it.
    @discardableResult
    public static func reclaimAbandoned(in db: Database) throws -> Int {
        try db.execute(sql: "UPDATE jobs SET state = 'pending' WHERE state = 'running'")
        return db.changesCount
    }

    public static func deleteFailed(in db: Database) throws -> Int {
        try db.execute(sql: "DELETE FROM jobs WHERE state = 'failed'")
        return db.changesCount
    }

    public static func delete(kind: JobKind, targetID: ChunkID, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM jobs WHERE kind = ? AND target_id = ?",
            arguments: [kind.rawValue, targetID.rawValue]
        )
    }

    // MARK: - Reporting

    public struct QueueDepth: Sendable, Hashable {
        public var pending: Int
        public var running: Int
        public var failed: Int

        public var isEmpty: Bool { pending == 0 && running == 0 }
    }

    public static func depth(kind: JobKind, in db: Database) throws -> QueueDepth {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT
                    sum(CASE WHEN state = 'pending' THEN 1 ELSE 0 END) AS pending,
                    sum(CASE WHEN state = 'running' THEN 1 ELSE 0 END) AS running,
                    sum(CASE WHEN state = 'failed'  THEN 1 ELSE 0 END) AS failed
                  FROM jobs WHERE kind = ?
                """,
            arguments: [kind.rawValue]
        )
        return QueueDepth(
            pending: row?["pending"] ?? 0,
            running: row?["running"] ?? 0,
            failed: row?["failed"] ?? 0
        )
    }

    public static func failedJobs(limit: Int, in db: Database) throws -> [Job] {
        try Row.fetchAll(
            db,
            sql: "SELECT * FROM jobs WHERE state = 'failed' ORDER BY id LIMIT ?",
            arguments: [limit]
        ).map(decode)
    }

    /// When the next pending job becomes eligible, for scheduling the worker's next wake-up.
    public static func nextEligibleDate(kind: JobKind, in db: Database) throws -> Date? {
        try Double.fetchOne(
            db,
            sql: "SELECT min(next_after) FROM jobs WHERE kind = ? AND state = 'pending'",
            arguments: [kind.rawValue]
        ).map(Date.init(timeIntervalSince1970:))
    }

    // MARK: - Coding

    private static func decode(_ row: Row) -> Job {
        Job(
            id: row["id"],
            kind: JobKind(rawValue: row["kind"]) ?? .embed,
            targetID: ChunkID(rawValue: row["target_id"]),
            state: JobState(rawValue: row["state"]) ?? .pending,
            attempts: row["attempts"],
            nextAfter: Date(timeIntervalSince1970: row["next_after"]),
            lastError: row["last_error"],
            createdAt: Date(timeIntervalSince1970: row["created_at"])
        )
    }
}

import CodexBarCore
import Foundation
import Testing

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

struct OpenCodeFreeUsageReaderTests {
    @Test
    func `queries only today free model assistant and compaction messages read-only`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeFreeUsageReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("opencode.db")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 7 * 3600)!
        let now = Date(timeIntervalSince1970: 1_795_420_000) // 2026-11-23 local WIB
        let todayStartMs = Int64(calendar.startOfDay(for: now).timeIntervalSince1970 * 1000)
        let yesterdayMs = todayStartMs - 60_000

        try Self.createDatabase(at: dbURL, rows: [
            // Included today
            ("m1", "assistant", todayStartMs + 10_000, #"{"model":{"id":"hy4-flash-free","providerID":"opencode"},"tokens":{"input":1200,"output":350,"reasoning":40,"cache":{"read":8000}}}"#),
            ("m2", "compaction", todayStartMs + 20_000, #"{"model":{"id":"hy4-flash-free","providerID":"opencode"},"tokens":{"input":300,"output":50,"reasoning":0,"cache":{"read":1000}}}"#),
            ("m3", "assistant", todayStartMs + 30_000, #"{"model":{"id":"deepseek-v4.1-flash-free","providerID":"opencode"},"tokens":{"input":500,"output":100,"reasoning":20,"cache":{"read":500}}}"#),
            // Excluded: user message, non-free model, yesterday
            ("m4", "user", todayStartMs + 40_000, #"{"model":{"id":"hy4-flash-free","providerID":"opencode"},"tokens":{"input":999,"output":999}}"#),
            ("m5", "assistant", todayStartMs + 50_000, #"{"model":{"id":"qwen3.8:27b","providerID":"colab"},"tokens":{"input":999,"output":999}}"#),
            ("m6", "assistant", yesterdayMs, #"{"model":{"id":"hy4-flash-free","providerID":"opencode"},"tokens":{"input":999,"output":999}}"#),
        ])

        let summary = OpenCodeFreeUsageReader.load(
            databaseURL: dbURL,
            ledgerURL: dir.appendingPathComponent("missing-ledger.json"),
            now: now,
            calendar: calendar)

        #expect(summary.hasLocalSource)
        #expect(summary.models.count == 2)

        let hy4 = try #require(summary.models.first { $0.modelID == "hy4-flash-free" })
        #expect(hy4.requests == 2)
        #expect(hy4.inputTokens == 1500)
        #expect(hy4.outputTokens == 400)
        #expect(hy4.reasoningTokens == 40)
        #expect(hy4.cacheReadTokens == 9000)

        let ds = try #require(summary.models.first { $0.modelID == "deepseek-v4.1-flash-free" })
        #expect(ds.requests == 1)
        #expect(ds.inputTokens == 500)
        #expect(ds.outputTokens == 100)
    }

    @Test
    func `parses agent-hub ledger and marks future blocked_until as warning`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeFreeLedgerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 7 * 3600)!
        let now = Date(timeIntervalSince1970: 1_795_420_000)
        let futureRecovery = now.addingTimeInterval(1800)
        let pastRecovery = now.addingTimeInterval(-600)

        let ledgerURL = dir.appendingPathComponent("ledger.json")
        let ledgerJSON = """
        {
          "opencode": {
            "opencode/hy4-flash-free": {
              "runs": { "2026-11-23": 3 },
              "blocked_until": \(futureRecovery.timeIntervalSince1970),
              "last_limit_error": "429 rate limit"
            },
            "opencode/glm-5.3-flash-free": {
              "runs": { "2026-11-23": 1 },
              "blocked_until": \(pastRecovery.timeIntervalSince1970)
            }
          }
        }
        """
        try Data(ledgerJSON.utf8).write(to: ledgerURL)

        let summary = OpenCodeFreeUsageReader.load(
            databaseURL: dir.appendingPathComponent("missing-opencode.db"),
            ledgerURL: ledgerURL,
            now: now,
            calendar: calendar)
        #expect(summary.hasLocalSource)

        let section = try #require(OpenCodeFreeUsageReader.detailSection(
            from: summary,
            now: now,
            calendar: calendar))
        #expect(section.title == "OpenCode Free")

        let hy4Row = try #require(section.rows.first { $0.label == "hy4-flash-free" })
        #expect(hy4Row.severity == .warning)
        #expect(hy4Row.secondaryValue?.contains("Terkena limit, pulih ") == true)

        let glmRow = try #require(section.rows.first { $0.label == "glm-5.3-flash-free" })
        #expect(glmRow.severity == nil)
        #expect(glmRow.secondaryValue?.contains("Terkena limit") == false)
    }

    @Test
    func `claude automatic menu bar window prefers weekly while explicit primary stays session`() throws {
        let now = Date(timeIntervalSince1970: 1_795_420_000)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 87, windowMinutes: 300, resetsAt: now.addingTimeInterval(3600), resetDescription: nil),
            secondary: RateWindow(usedPercent: 16, windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400), resetDescription: nil),
            updatedAt: now)

        let autoWindow = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .claude,
            snapshot: snapshot,
            supportsAverage: false,
            antigravityPrioritizeExhaustedQuotas: false,
            now: now)
        #expect(autoWindow?.windowMinutes == 10080)
        #expect(autoWindow?.remainingPercent == 84)

        let sessionWindow = MenuBarMetricWindowResolver.rateWindow(
            preference: .primary,
            provider: .claude,
            snapshot: snapshot,
            supportsAverage: false,
            antigravityPrioritizeExhaustedQuotas: false,
            now: now)
        #expect(sessionWindow?.windowMinutes == 300)
        #expect(sessionWindow?.remainingPercent == 13)
    }

    private static func createDatabase(
        at url: URL,
        rows: [(id: String, type: String, timeCreated: Int64, data: String)]) throws
    {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "OpenCodeFreeUsageReaderTests", code: 1)
        }
        defer { sqlite3_close(db) }

        let createSQL = """
        CREATE TABLE session_message (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            type TEXT NOT NULL,
            seq INTEGER NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL
        );
        """
        guard sqlite3_exec(db, createSQL, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "OpenCodeFreeUsageReaderTests", code: 2)
        }

        var stmt: OpaquePointer?
        let insertSQL = "INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES (?1, 's1', ?2, 1, ?3, ?3, ?4);"
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw NSError(domain: "OpenCodeFreeUsageReaderTests", code: 3)
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for row in rows {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, row.id, -1, transient)
            sqlite3_bind_text(stmt, 2, row.type, -1, transient)
            sqlite3_bind_int64(stmt, 3, row.timeCreated)
            sqlite3_bind_text(stmt, 4, row.data, -1, transient)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw NSError(domain: "OpenCodeFreeUsageReaderTests", code: 4)
            }
        }
    }
}

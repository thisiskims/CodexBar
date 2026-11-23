import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

public struct OpenCodeFreeModelUsage: Equatable, Sendable {
    public let modelID: String
    public let requests: Int
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let reasoningTokens: Int64
    public let cacheReadTokens: Int64
    public let blockedUntil: Date?
    public let lastLimitError: String?

    public init(
        modelID: String,
        requests: Int,
        inputTokens: Int64,
        outputTokens: Int64,
        reasoningTokens: Int64,
        cacheReadTokens: Int64,
        blockedUntil: Date? = nil,
        lastLimitError: String? = nil)
    {
        self.modelID = modelID
        self.requests = requests
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.blockedUntil = blockedUntil
        self.lastLimitError = lastLimitError
    }
}

public struct OpenCodeFreeUsageSummary: Equatable, Sendable {
    public let models: [OpenCodeFreeModelUsage]
    public let hasLocalSource: Bool

    public init(models: [OpenCodeFreeModelUsage], hasLocalSource: Bool) {
        self.models = models
        self.hasLocalSource = hasLocalSource
    }
}

public struct OpenCodeLedgerModelState: Equatable, Sendable {
    public let modelID: String
    public let runsToday: Int
    public let blockedUntil: Date?
    public let lastLimitError: String?

    public init(
        modelID: String,
        runsToday: Int = 0,
        blockedUntil: Date? = nil,
        lastLimitError: String? = nil)
    {
        self.modelID = modelID
        self.runsToday = runsToday
        self.blockedUntil = blockedUntil
        self.lastLimitError = lastLimitError
    }
}

public enum OpenCodeFreeUsageReader {
    public static let sectionTitle = "OpenCode Free"

    public static func defaultDatabaseURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("opencode.db", isDirectory: false)
    }

    public static func defaultLedgerURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("agent-hub", isDirectory: true)
            .appendingPathComponent("ledger.json", isDirectory: false)
    }

    public static func hasLocalSource(
        databaseURL: URL = defaultDatabaseURL(),
        ledgerURL: URL = defaultLedgerURL(),
        fileManager: FileManager = .default) -> Bool
    {
        fileManager.fileExists(atPath: databaseURL.path) || fileManager.fileExists(atPath: ledgerURL.path)
    }

    public static func load(
        databaseURL: URL = defaultDatabaseURL(),
        ledgerURL: URL = defaultLedgerURL(),
        now: Date = Date(),
        calendar: Calendar = .current,
        fileManager: FileManager = .default) -> OpenCodeFreeUsageSummary
    {
        let dbExists = fileManager.fileExists(atPath: databaseURL.path)
        let ledgerExists = fileManager.fileExists(atPath: ledgerURL.path)

        let dbRows = dbExists
            ? self.queryTodayFreeUsage(databaseURL: databaseURL, now: now, calendar: calendar)
            : []
        let ledgerStates = ledgerExists
            ? self.readLedger(ledgerURL: ledgerURL, now: now, calendar: calendar)
            : [:]

        var mergedByModel: [String: OpenCodeFreeModelUsage] = [:]
        for row in dbRows {
            let ledger = ledgerStates[row.modelID]
            mergedByModel[row.modelID] = OpenCodeFreeModelUsage(
                modelID: row.modelID,
                requests: row.requests,
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                reasoningTokens: row.reasoningTokens,
                cacheReadTokens: row.cacheReadTokens,
                blockedUntil: ledger?.blockedUntil,
                lastLimitError: ledger?.lastLimitError)
        }

        for (modelID, ledger) in ledgerStates where mergedByModel[modelID] == nil {
            let isBlocked = ledger.blockedUntil.map { $0 > now } ?? false
            guard isBlocked || ledger.runsToday > 0 else { continue }
            mergedByModel[modelID] = OpenCodeFreeModelUsage(
                modelID: modelID,
                requests: ledger.runsToday,
                inputTokens: 0,
                outputTokens: 0,
                reasoningTokens: 0,
                cacheReadTokens: 0,
                blockedUntil: ledger.blockedUntil,
                lastLimitError: ledger.lastLimitError)
        }

        let sorted = mergedByModel.values.sorted { lhs, rhs in
            if lhs.requests != rhs.requests {
                return lhs.requests > rhs.requests
            }
            return lhs.modelID < rhs.modelID
        }

        return OpenCodeFreeUsageSummary(
            models: sorted,
            hasLocalSource: dbExists || ledgerExists)
    }

    public static func detailSection(
        from summary: OpenCodeFreeUsageSummary,
        now: Date = Date(),
        calendar: Calendar = .current) -> ProviderDetailSection?
    {
        guard summary.hasLocalSource || !summary.models.isEmpty else { return nil }

        let rows: [ProviderDetailSection.Row]
        if summary.models.isEmpty {
            rows = [
                .makeRow(
                    label: "Hari ini",
                    value: "Belum ada pemakaian"),
            ]
        } else {
            rows = summary.models
                .prefix(ProviderDetailSection.maximumRowsPerSection)
                .map { self.makeRow(for: $0, now: now, calendar: calendar) }
        }

        return try? ProviderDetailSection(title: self.sectionTitle, rows: rows)
    }

    static func makeRow(
        for usage: OpenCodeFreeModelUsage,
        now: Date,
        calendar: Calendar = .current) -> ProviderDetailSection.Row
    {
        let label = Self.truncated(usage.modelID)
        let value = Self.truncated(
            "\(usage.requests) req · \(Self.formatTokens(usage.inputTokens)) in · \(Self.formatTokens(usage.outputTokens)) out")

        var secondaryParts: [String] = []
        var severity: ProviderDetailSection.Row.Severity?
        if let blockedUntil = usage.blockedUntil, blockedUntil > now {
            let recovery = Self.formatRecoveryTime(blockedUntil, now: now, calendar: calendar)
            secondaryParts.append("Terkena limit, pulih \(recovery)")
            severity = .warning
        }
        if usage.reasoningTokens > 0 || usage.cacheReadTokens > 0 || secondaryParts.isEmpty {
            secondaryParts.append(
                "Reas \(Self.formatTokens(usage.reasoningTokens)) · Cache \(Self.formatTokens(usage.cacheReadTokens))")
        }

        let secondaryValue = Self.truncated(secondaryParts.joined(separator: " · "))
        return .makeRow(
            label: label,
            value: value,
            secondaryValue: secondaryValue,
            severity: severity)
    }

    public static func readLedger(
        ledgerURL: URL,
        now: Date = Date(),
        calendar: Calendar = .current) -> [String: OpenCodeLedgerModelState]
    {
        guard let data = try? Data(contentsOf: ledgerURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let opencode = root["opencode"] as? [String: Any]
        else {
            return [:]
        }

        let todayKey = Self.dayKey(for: now, calendar: calendar)
        var result: [String: OpenCodeLedgerModelState] = [:]

        for (rawKey, rawValue) in opencode {
            guard let entry = rawValue as? [String: Any] else { continue }
            let modelID = rawKey.hasPrefix("opencode/")
                ? String(rawKey.dropFirst("opencode/".count))
                : rawKey
            guard modelID.hasSuffix("-free") else { continue }

            let runsMap = entry["runs"] as? [String: Any]
            let runsToday: Int = if let count = runsMap?[todayKey] as? Int {
                max(0, count)
            } else if let num = runsMap?[todayKey] as? NSNumber {
                max(0, num.intValue)
            } else {
                0
            }

            let blockedUntil: Date? = if let epoch = (entry["blocked_until"] as? NSNumber)?.doubleValue,
                                         epoch.isFinite, epoch > 0
            {
                Date(timeIntervalSince1970: epoch)
            } else {
                nil
            }

            let lastLimitError = (entry["last_limit_error"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            result[modelID] = OpenCodeLedgerModelState(
                modelID: modelID,
                runsToday: runsToday,
                blockedUntil: blockedUntil,
                lastLimitError: lastLimitError?.isEmpty == false ? lastLimitError : nil)
        }

        return result
    }

    static func queryTodayFreeUsage(
        databaseURL: URL,
        now: Date = Date(),
        calendar: Calendar = .current) -> [OpenCodeFreeModelUsage]
    {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let startOfDay = calendar.startOfDay(for: now)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return []
        }
        let startMs = Int64(startOfDay.timeIntervalSince1970 * 1000)
        let endMs = Int64(nextDay.timeIntervalSince1970 * 1000)

        var uriAllowed = CharacterSet.urlPathAllowed
        uriAllowed.remove(charactersIn: "?#")
        let encodedPath = databaseURL.path.addingPercentEncoding(withAllowedCharacters: uriAllowed) ?? databaseURL.path
        let uriString = "file:\(encodedPath)?mode=ro"

        var db: OpaquePointer?
        let openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uriString, &db, openFlags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        _ = sqlite3_exec(db, "PRAGMA query_only = ON;", nil, nil, nil)

        let sql = """
        SELECT
            json_extract(data, '$.model.id') AS model_id,
            COUNT(*) AS requests,
            SUM(COALESCE(CAST(json_extract(data, '$.tokens.input') AS INTEGER), 0)) AS input_tokens,
            SUM(COALESCE(CAST(json_extract(data, '$.tokens.output') AS INTEGER), 0)) AS output_tokens,
            SUM(COALESCE(CAST(json_extract(data, '$.tokens.reasoning') AS INTEGER), 0)) AS reasoning_tokens,
            SUM(COALESCE(CAST(json_extract(data, '$.tokens.cache.read') AS INTEGER), 0)) AS cache_read_tokens
        FROM session_message
        WHERE type IN ('assistant', 'compaction')
          AND json_extract(data, '$.model.id') LIKE '%-free'
          AND time_created >= ?1
          AND time_created < ?2
        GROUP BY model_id
        ORDER BY requests DESC, model_id ASC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, startMs)
        sqlite3_bind_int64(stmt, 2, endMs)

        var rows: [OpenCodeFreeModelUsage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let rawModel = sqlite3_column_text(stmt, 0) else { continue }
            let modelID = String(cString: rawModel)
            let requests = Int(sqlite3_column_int64(stmt, 1))
            let inputTokens = sqlite3_column_int64(stmt, 2)
            let outputTokens = sqlite3_column_int64(stmt, 3)
            let reasoningTokens = sqlite3_column_int64(stmt, 4)
            let cacheReadTokens = sqlite3_column_int64(stmt, 5)

            rows.append(OpenCodeFreeModelUsage(
                modelID: modelID,
                requests: requests,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                reasoningTokens: reasoningTokens,
                cacheReadTokens: cacheReadTokens))
        }
        return rows
        #else
        return []
        #endif
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let y = components.year ?? 1970
        let m = components.month ?? 1
        let d = components.day ?? 1
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    private static func formatTokens(_ count: Int64) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    private static func formatRecoveryTime(_ date: Date, now: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "d MMM HH:mm"
        return formatter.string(from: date)
    }

    private static func truncated(_ value: String) -> String {
        let maxLen = ProviderDetailSection.maximumStringLength
        guard value.count > maxLen else { return value }
        return String(value.prefix(maxLen - 1)) + "…"
    }
}

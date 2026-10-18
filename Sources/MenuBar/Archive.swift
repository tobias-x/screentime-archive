import Foundation
import SQLite3

/// Read-only access to the archive written by screentime-archiver.
/// The archive lives outside Apple's protected folders, so this app needs no Full Disk Access.
enum Archive {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ScreenTimeArchive/archive.sqlite")

    struct Device: Identifiable, Hashable {
        let id: String
        let name: String
        let platform: String
        var label = ""      // short display label, e.g. "iPhone" / "Mac"
    }

    /// One device's usage on one day (a stacked-bar segment).
    struct DayUsage: Identifiable {
        let date: Date
        let key: String      // yyyy-MM-dd
        let deviceID: String
        let seconds: Double
        var id: String { key + deviceID }
    }

    struct AppUsage: Identifiable {
        let bundleID: String
        let deviceID: String
        let name: String
        let seconds: Double
        var id: String { deviceID + bundleID }
    }

    struct Snapshot {
        var devices: [Device] = []           // stacking order, bottom first
        var dates: [Date] = []
        var usage: [DayUsage] = []
        var topApps: [AppUsage] = []
        var lastRun: Date?
        var lastRunError: String?
        var error: String?

        func seconds(day key: String, device: String? = nil) -> Double {
            usage.filter { $0.key == key && (device == nil || $0.deviceID == device) }.reduce(0) { $0 + $1.seconds }
        }
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Loads the last `dayCount` days for all devices, plus the top apps across devices for
    /// `selectedDay` (or the whole range).
    static func load(dayCount: Int, selectedDay: String?, topN: Int = 10) -> Snapshot {
        var snap = Snapshot()
        guard FileManager.default.fileExists(atPath: url.path) else {
            snap.error = "No archive yet. Run the archiver once (see README)."
            return snap
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            snap.error = "Cannot open archive."
            return snap
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        // iPhone first so it sits on the baseline of the stack.
        var devices = query(db, "SELECT device_id, name, platform FROM devices ORDER BY platform = 'ios' DESC, platform, first_seen") {
            Device(id: text($0, 0), name: text($0, 1), platform: text($0, 2))
        }
        for i in devices.indices {
            let p = devices[i].platform
            let short = p == "ios" ? "iPhone" : p == "macos" ? "Mac" : nil
            let unique = devices.filter { $0.platform == p }.count == 1
            devices[i].label = (unique ? short : nil) ?? devices[i].name
        }
        snap.devices = devices

        if let run = query(db, "SELECT run_at, status, message FROM runs ORDER BY run_at DESC LIMIT 1", map: { s in
            (Date(timeIntervalSince1970: sqlite3_column_double(s, 0)), text(s, 1), text(s, 2))
        }).first {
            snap.lastRun = run.0
            if run.1 != "ok" { snap.lastRunError = run.2 }
        }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        snap.dates = (0..<dayCount).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
        let firstKey = dayFormatter.string(from: snap.dates.first ?? today)

        var totals: [String: Double] = [:]  // "date|device" -> seconds
        query(db, "SELECT local_date, device_id, SUM(seconds) FROM hourly_usage WHERE local_date >= ? GROUP BY 1, 2",
              bind: [firstKey]) { s in
            totals[text(s, 0) + "|" + text(s, 1)] = sqlite3_column_double(s, 2)
        }
        snap.usage = snap.dates.flatMap { d in
            let k = dayFormatter.string(from: d)
            return devices.map { DayUsage(date: d, key: k, deviceID: $0.id, seconds: totals[k + "|" + $0.id] ?? 0) }
        }

        let (dateClause, dateArg) = selectedDay.map { ("local_date = ?", $0) } ?? ("local_date >= ?", firstKey)
        snap.topApps = query(db, """
            SELECT h.bundle_id, h.device_id, n.name, SUM(h.seconds) AS secs
            FROM hourly_usage h LEFT JOIN app_names n USING (bundle_id)
            WHERE h.\(dateClause)
            GROUP BY h.device_id, h.bundle_id ORDER BY secs DESC LIMIT \(topN)
            """, bind: [dateArg]) { s in
            let bundle = text(s, 0)
            let override = sqlite3_column_type(s, 2) == SQLITE_NULL ? nil : text(s, 2)
            return AppUsage(bundleID: bundle, deviceID: text(s, 1),
                            name: override ?? AppNames.displayName(for: bundle), seconds: sqlite3_column_double(s, 3))
        }
        return snap
    }

    // MARK: SQLite plumbing

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
    }

    @discardableResult
    private static func query<T>(_ db: OpaquePointer, _ sql: String, bind: [String] = [], map: (OpaquePointer) -> T) -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in bind.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), v, -1, transient) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(map(stmt)) }
        return out
    }
}

func formatDuration(_ seconds: Double) -> String {
    let mins = Int((seconds / 60).rounded())
    if mins < 1 { return seconds > 0 ? "<1m" : "0m" }
    let h = mins / 60, m = mins % 60
    if h == 0 { return "\(m)m" }
    return m == 0 ? "\(h)h" : "\(h)h \(m)m"
}

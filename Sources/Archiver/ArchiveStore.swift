import Foundation
import SQLite3

/// The permanent archive. Timestamps are Unix seconds.
final class ArchiveStore {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ScreenTimeArchive/archive.sqlite")

    static let schema = """
    CREATE TABLE IF NOT EXISTS devices (
        device_id  TEXT PRIMARY KEY,
        name       TEXT NOT NULL,          -- editable; never overwritten once set
        platform   TEXT NOT NULL,          -- ios | macos | unknown
        os_build   TEXT,
        source     TEXT NOT NULL,
        first_seen REAL NOT NULL,          -- Unix seconds
        last_seen  REAL NOT NULL
    );
    -- Raw foreground sessions, kept forever. Timestamps are Unix seconds (UTC).
    CREATE TABLE IF NOT EXISTS sessions (
        device_id TEXT NOT NULL,
        bundle_id TEXT NOT NULL,
        start_ts  REAL NOT NULL,
        end_ts    REAL NOT NULL,
        PRIMARY KEY (device_id, bundle_id, start_ts)
    ) WITHOUT ROWID;
    -- Per-app usage split into local-time hours (derived from sessions).
    CREATE TABLE IF NOT EXISTS hourly_usage (
        device_id  TEXT NOT NULL,
        bundle_id  TEXT NOT NULL,
        hour_start INTEGER NOT NULL,       -- Unix seconds of the local hour's start
        local_date TEXT NOT NULL,          -- YYYY-MM-DD in local time
        local_hour INTEGER NOT NULL,       -- 0-23
        seconds    REAL NOT NULL,
        PRIMARY KEY (device_id, bundle_id, hour_start)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS hourly_by_date ON hourly_usage (device_id, local_date);
    -- Optional display-name overrides, e.g. INSERT INTO app_names VALUES ('com.example.app', 'Example');
    CREATE TABLE IF NOT EXISTS app_names (
        bundle_id TEXT PRIMARY KEY,
        name      TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS runs (
        run_at        REAL NOT NULL,
        device_id     TEXT,
        source        TEXT,
        sessions_seen INTEGER,
        sessions_new  INTEGER,
        status        TEXT NOT NULL,       -- ok | error
        message       TEXT
    );
    PRAGMA user_version = 1;
    """

    let db: DB

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try DB(path: url.path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        try db.exec("PRAGMA journal_mode = WAL;")
        try db.exec(Self.schema)
    }

    /// Inserts sessions (ignoring ones already archived) and rebuilds the affected hourly rows.
    /// Returns the number of new sessions.
    func archive(_ result: SourceResult) throws -> Int {
        let device = result.device
        let now = Date().timeIntervalSince1970
        try db.exec("BEGIN IMMEDIATE")
        do {
            try db.prepare("""
                INSERT INTO devices (device_id, name, platform, os_build, source, first_seen, last_seen)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (device_id) DO UPDATE SET
                    platform = excluded.platform, os_build = COALESCE(excluded.os_build, os_build),
                    source = excluded.source, last_seen = excluded.last_seen
                """).bind(device.id, device.name, device.platform, device.osBuild, device.source, now, now).run()

            let ins = try db.prepare("INSERT OR IGNORE INTO sessions (device_id, bundle_id, start_ts, end_ts) VALUES (?, ?, ?, ?)")
            var inserted = 0
            var earliestNew = Double.infinity
            for s in result.sessions {
                try ins.bind(device.id, s.bundleID, s.start, s.end).run()
                if db.changes > 0 {
                    inserted += 1
                    earliestNew = min(earliestNew, s.start)
                }
            }
            if inserted > 0 { try rebuildHourly(deviceID: device.id, from: earliestNew) }
            try db.exec("COMMIT")
            return inserted
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    /// Recomputes hourly buckets from the archived sessions, from the hour containing `earliest` onwards.
    private func rebuildHourly(deviceID: String, from earliest: Double) throws {
        let cal = Calendar.current
        let boundary = cal.dateInterval(of: .hour, for: Date(timeIntervalSince1970: earliest))!.start.timeIntervalSince1970

        try db.prepare("DELETE FROM hourly_usage WHERE device_id = ? AND hour_start >= ?").bind(deviceID, Int(boundary)).run()

        var buckets: [String: [Int: Double]] = [:]  // bundle -> hour_start -> seconds
        let q = try db.prepare("SELECT bundle_id, start_ts, end_ts FROM sessions WHERE device_id = ? AND end_ts > ?").bind(deviceID, boundary)
        while try q.step() {
            guard let bundle = q.string(0) else { continue }
            var t = max(q.double(1), boundary)
            let end = q.double(2)
            while t < end {
                let hour = cal.dateInterval(of: .hour, for: Date(timeIntervalSince1970: t))!
                let next = min(end, hour.end.timeIntervalSince1970)
                buckets[bundle, default: [:]][Int(hour.start.timeIntervalSince1970), default: 0] += next - t
                t = next
            }
        }

        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "yyyy-MM-dd"
        let ins = try db.prepare("""
            INSERT INTO hourly_usage (device_id, bundle_id, hour_start, local_date, local_hour, seconds)
            VALUES (?, ?, ?, ?, ?, ?)
            """)
        for (bundle, hours) in buckets {
            for (hourStart, secs) in hours {
                let d = Date(timeIntervalSince1970: Double(hourStart))
                try ins.bind(deviceID, bundle, hourStart, fmt.string(from: d), cal.component(.hour, from: d), secs).run()
            }
        }
    }

    func recordRun(device: String?, source: String, seen: Int, new: Int, error: String? = nil) {
        _ = try? db.prepare("INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?, ?)")
            .bind(Date().timeIntervalSince1970, device, source, seen, new, error == nil ? "ok" : "error", error).run()
    }

    func printStatus() throws {
        let st = try db.prepare("""
            SELECT d.name, d.platform, d.device_id, COUNT(s.start_ts),
                   MIN(s.start_ts), MAX(s.end_ts), SUM(s.end_ts - s.start_ts)
            FROM devices d LEFT JOIN sessions s USING (device_id) GROUP BY d.device_id ORDER BY d.name
            """)
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        while try st.step() {
            let first = st.isNull(4) ? "-" : df.string(from: Date(timeIntervalSince1970: st.double(4)))
            let last = st.isNull(5) ? "-" : df.string(from: Date(timeIntervalSince1970: st.double(5)))
            print("\(st.string(0) ?? "?") [\(st.string(1) ?? "?")] \(st.string(2) ?? "")")
            print("  sessions: \(st.int(3))  range: \(first) → \(last)  total: \(String(format: "%.1f", st.double(6) / 3600)) h")
        }
    }

    func checkpoint() { _ = try? db.exec("PRAGMA wal_checkpoint(TRUNCATE);") }
}

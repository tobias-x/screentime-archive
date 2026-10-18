import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal SQLite wrapper (the system SQLite3 module, no dependencies).
final class DB {
    let handle: OpaquePointer

    init(path: String, flags: Int32) throws {
        var h: OpaquePointer?
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            if let h { sqlite3_close(h) }
            throw ArchiverError("cannot open \(path): \(msg)")
        }
        handle = h
        sqlite3_busy_timeout(h, 10_000)
    }

    deinit { sqlite3_close(handle) }

    var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw ArchiverError("SQL error: \(msg)\n  in: \(sql.prefix(200))")
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ArchiverError("prepare failed: \(errorMessage)\n  in: \(sql.prefix(200))")
        }
        return Statement(stmt, db: self)
    }

    var changes: Int { Int(sqlite3_changes(handle)) }

    func tableExists(_ name: String) -> Bool {
        guard let st = try? prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?") else { return false }
        st.bind(name)
        return (try? st.step()) == true
    }
}

final class Statement {
    let stmt: OpaquePointer
    unowned let db: DB
    init(_ s: OpaquePointer, db: DB) { stmt = s; self.db = db }
    deinit { sqlite3_finalize(stmt) }

    @discardableResult
    func bind(_ values: Any?...) -> Statement {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case nil: sqlite3_bind_null(stmt, idx)
            case let x as Int: sqlite3_bind_int64(stmt, idx, Int64(x))
            case let x as Double: sqlite3_bind_double(stmt, idx, x)
            case let x as String: sqlite3_bind_text(stmt, idx, x, -1, SQLITE_TRANSIENT)
            default: fatalError("unsupported bind type \(type(of: v))")
            }
        }
        return self
    }

    func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw ArchiverError("step failed: \(db.errorMessage)")
    }

    func run() throws { while try step() {} }

    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    func string(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
}

/// Takes a transactionally consistent snapshot of a live SQLite database (including its WAL)
/// using the online backup API, so we never read a half-written file. Falls back to copying
/// the db/-wal/-shm files if the source can't be opened read-only.
/// The returned copy is private to us, so it is safe to open read-write.
func snapshotSQLite(_ src: URL, into dir: URL) throws -> URL {
    let dest = dir.appendingPathComponent(src.lastPathComponent)
    do {
        let source = try DB(path: src.path, flags: SQLITE_OPEN_READONLY)
        let target = try DB(path: dest.path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard let backup = sqlite3_backup_init(target.handle, "main", source.handle, "main") else {
            throw ArchiverError("backup init failed: \(target.errorMessage)")
        }
        var rc: Int32
        repeat {
            rc = sqlite3_backup_step(backup, -1)
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED { usleep(200_000) }
        } while rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED
        sqlite3_backup_finish(backup)
        guard rc == SQLITE_DONE else { throw ArchiverError("backup failed: rc=\(rc) \(target.errorMessage)") }
        // The copy inherits WAL mode; switch it to a self-contained file.
        try target.exec("PRAGMA journal_mode = DELETE;")
        return dest
    } catch {
        log("  backup API failed for \(src.lastPathComponent) (\(error)); falling back to file copy")
        try? FileManager.default.removeItem(at: dest)
        for suffix in ["", "-wal", "-shm"] {
            let s = URL(fileURLWithPath: src.path + suffix)
            if FileManager.default.fileExists(atPath: s.path) {
                try FileManager.default.copyItem(at: s, to: URL(fileURLWithPath: dest.path + suffix))
            }
        }
        return dest
    }
}

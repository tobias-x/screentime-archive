import Foundation
import SQLite3
import IOKit

let appleEpochOffset: Double = 978_307_200  // 2001-01-01 minus 1970-01-01, in seconds
let maxSessionSeconds: Double = 24 * 3600

/// Where Apple keeps Screen Time data. Overridable for tests.
struct Paths {
    var biome: URL
    var knowledgeDB: URL

    static let standard: Paths = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Paths(biome: home.appendingPathComponent("Library/Biome"),
                     knowledgeDB: home.appendingPathComponent("Library/Application Support/Knowledge/knowledgeC.db"))
    }()

    var appInFocusRemote: URL { biome.appendingPathComponent("streams/restricted/App.InFocus/remote") }
    var biomeSyncDB: URL { biome.appendingPathComponent("sync/sync.db") }
}

struct Device {
    let id: String
    let name: String
    let platform: String   // "ios", "macos", "unknown"
    let osBuild: String?
    let source: String
}

struct Session: Hashable {
    let bundleID: String
    let start: Double  // Unix seconds
    let end: Double
}

struct SourceResult {
    let device: Device
    let sessions: [Session]
}

func platformName(biomePlatform: Int?) -> String {
    switch biomePlatform {
    case 2: "ios"     // iOS / iPadOS
    case 3: "macos"
    default: "unknown"
    }
}

func defaultName(platform: String) -> String {
    switch platform {
    case "ios": "iPhone"
    case "macos": "Mac"
    default: "Remote device"
    }
}

// MARK: - Biome App.InFocus (other devices, macOS 14+)

enum BiomeSource {
    struct Event {
        let kind: UInt64, starting: Bool, timestamp: Double, bundleID: String
    }

    /// App.InFocus protobuf fields: 2 = kind (1 = app; 3 = system overlay such as Control Center,
    /// excluded as Screen Time does), 3 = starting (1) / ending (0), 4 = Apple-epoch timestamp, 6 = bundle id.
    static func event(from payload: Data) -> Event? {
        guard let msg = Protobuf.decode(payload),
              case .varint(let kind)? = msg[2]?.first,
              case .varint(let starting)? = msg[3]?.first,
              case .fixed64(let appleTs)? = msg[4]?.first,
              case .bytes(let bundleBytes)? = msg[6]?.first,
              let bundle = String(data: bundleBytes, encoding: .utf8), !bundle.isEmpty
        else { return nil }
        return Event(kind: kind, starting: starting == 1, timestamp: appleTs + appleEpochOffset, bundleID: bundle)
    }

    /// Pairs start/end events into sessions. Starts with no end yet are left for a later run.
    static func sessions(from events: [Event]) -> [Session] {
        var open: [String: Double] = [:]
        var sessions: [Session] = []
        for e in events where e.kind == 1 {
            if e.starting {
                open[e.bundleID] = e.timestamp
            } else if let s = open.removeValue(forKey: e.bundleID), e.timestamp > s, e.timestamp - s <= maxSessionSeconds {
                sessions.append(Session(bundleID: e.bundleID, start: s, end: e.timestamp))
            }
        }
        return sessions
    }

    /// Segment files are named by creation time (µs since 2001), so numeric order is chronological.
    static func segments(in dir: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { Int($0.lastPathComponent) != nil }
            .sorted { Int($0.lastPathComponent)! < Int($1.lastPathComponent)! }
    }

    static func deviceDirs(_ paths: Paths) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: paths.appInFocusRemote.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: paths.appInFocusRemote, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    /// Device metadata from Biome's sync database: platform and OS build per peer.
    static func peers(_ paths: Paths, tmp: URL) -> [String: (platform: Int, build: String?)] {
        var peers: [String: (platform: Int, build: String?)] = [:]
        guard let snap = try? snapshotSQLite(paths.biomeSyncDB, into: tmp),
              let db = try? DB(path: snap.path, flags: SQLITE_OPEN_READWRITE),
              db.tableExists("DevicePeer"),
              let st = try? db.prepare("SELECT device_identifier, platform, model FROM DevicePeer WHERE me = 0")
        else { return peers }
        while (try? st.step()) == true {
            if let id = st.string(0) { peers[id] = (st.int(1), st.string(2)) }
        }
        return peers
    }

    static func read(_ paths: Paths, tmp: URL) throws -> [SourceResult] {
        let fm = FileManager.default
        let peers = peers(paths, tmp: tmp)
        var results: [SourceResult] = []
        for dir in try deviceDirs(paths) {
            let id = dir.lastPathComponent
            let segs = try segments(in: dir)
            if segs.isEmpty { continue }

            // Copy segments first: Biome may be appending to them while we read.
            let copyDir = tmp.appendingPathComponent("segb-\(id)")
            try fm.createDirectory(at: copyDir, withIntermediateDirectories: true)
            var events: [Event] = []
            var stats = SEGB.Stats()
            for seg in segs {
                let copy = copyDir.appendingPathComponent(seg.lastPathComponent)
                try fm.copyItem(at: seg, to: copy)
                events += try SEGB.records(copy, stats: &stats).compactMap(event(from:))
            }
            if stats.live > 0 && events.isEmpty {
                log("  WARNING: \(stats.live) records for \(id) but none decoded. Apple may have changed the format; please run --diagnose and open an issue.")
            }

            let peer = peers[id]
            let platform = platformName(biomePlatform: peer?.platform)
            let device = Device(id: id, name: defaultName(platform: platform), platform: platform,
                                osBuild: peer?.build, source: "biome:App.InFocus")
            results.append(SourceResult(device: device, sessions: sessions(from: events)))
        }
        return results
    }
}

// MARK: - knowledgeC (this Mac; other devices on older macOS)

enum KnowledgeSource {
    static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        guard service != 0,
              let cf = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        else { return nil }
        return cf.takeRetainedValue() as? String
    }

    static func open(_ paths: Paths, tmp: URL) throws -> DB {
        let snap = try snapshotSQLite(paths.knowledgeDB, into: tmp)
        let db = try DB(path: snap.path, flags: SQLITE_OPEN_READWRITE)  // our private copy
        guard db.tableExists("ZOBJECT") else { throw ArchiverError("knowledgeC.db has no ZOBJECT table (unexpected schema)") }
        return db
    }

    /// App usage grouped by source device. Rows without a device id were recorded on this Mac.
    static func sessionsByDevice(_ db: DB) throws -> [String: [Session]] {
        let st = try db.prepare("""
            SELECT COALESCE(s.ZDEVICEID, ''), o.ZVALUESTRING, o.ZSTARTDATE, o.ZENDDATE
            FROM ZOBJECT o LEFT JOIN ZSOURCE s ON s.Z_PK = o.ZSOURCE
            WHERE o.ZSTREAMNAME = '/app/usage' AND o.ZVALUESTRING IS NOT NULL AND o.ZENDDATE > o.ZSTARTDATE
            """)
        var out: [String: [Session]] = [:]
        while try st.step() {
            guard let device = st.string(0), let bundle = st.string(1) else { continue }
            let s = st.double(2) + appleEpochOffset, e = st.double(3) + appleEpochOffset
            if e - s <= maxSessionSeconds { out[device, default: []].append(Session(bundleID: bundle, start: s, end: e)) }
        }
        return out
    }

    static func readLocal(_ db: DB) throws -> SourceResult {
        let sessions = try sessionsByDevice(db)[""] ?? []
        let device = Device(id: hardwareUUID() ?? "local-mac", name: Host.current().localizedName ?? "This Mac",
                            platform: "macos", osBuild: ProcessInfo.processInfo.operatingSystemVersionString,
                            source: "knowledgeC:/app/usage")
        return SourceResult(device: device, sessions: sessions)
    }

    /// Older macOS versions synced other devices' usage into knowledgeC (ZSOURCE.ZDEVICEID + ZSYNCPEER).
    static func readRemote(_ db: DB) throws -> [SourceResult] {
        var models: [String: String] = [:]
        if db.tableExists("ZSYNCPEER"), let st = try? db.prepare("SELECT ZDEVICEID, ZMODEL FROM ZSYNCPEER") {
            while (try? st.step()) == true {
                if let id = st.string(0), let model = st.string(1) { models[id] = model }
            }
        }
        return try sessionsByDevice(db).compactMap { id, sessions in
            guard !id.isEmpty else { return nil }
            let model = models[id] ?? ""
            let platform = model.hasPrefix("iPhone") || model.hasPrefix("iPad") ? "ios" : model.hasPrefix("Mac") ? "macos" : "unknown"
            let device = Device(id: id, name: defaultName(platform: platform), platform: platform,
                                osBuild: model.isEmpty ? nil : model, source: "knowledgeC:/app/usage (synced)")
            return SourceResult(device: device, sessions: sessions)
        }
    }
}

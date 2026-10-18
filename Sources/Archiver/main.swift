// screentime-archiver: copies Apple's Screen Time data into a permanent SQLite archive.
//
// Sources (see README for formats):
//   * Other devices (Screen Time "Share Across Devices"):
//       ~/Library/Biome/streams/restricted/App.InFocus/remote/<device>/<segment>   (SEGB + protobuf)
//       ~/Library/Biome/sync/sync.db (DevicePeer) for device metadata
//     Older macOS: synced rows in knowledgeC.db, used only when Biome has no remote devices.
//   * This Mac: ~/Library/Application Support/Knowledge/knowledgeC.db (ZOBJECT, '/app/usage')
//
// Requires Full Disk Access.

import Foundation

struct ArchiverError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func log(_ message: String) {
    let ts = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
    print("[\(ts)] \(message)")
    fflush(stdout)
}

func isPermissionError(_ error: Error) -> Bool {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(ns.code) { return true }
    if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError, u.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(u.code) { return true }
    let text = "\(error)"
    return text.contains("authorization denied") || text.contains("not permitted")
}

let fdaHint = "Grant Full Disk Access to \(CommandLine.arguments[0]) in System Settings › Privacy & Security › Full Disk Access."

func makeTempDir() -> URL {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("screentime-archiver-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
}

// MARK: - Archive run

func runArchive(paths: Paths, store: ArchiveStore) -> Int32 {
    let tmp = makeTempDir()
    defer { try? FileManager.default.removeItem(at: tmp) }
    var failures = 0

    func archive(_ result: SourceResult, label: String) throws {
        let new = try store.archive(result)
        log("\(result.device.name) [\(result.device.platform), \(label)]: \(result.sessions.count) sessions read, \(new) new")
        store.recordRun(device: result.device.id, source: result.device.source, seen: result.sessions.count, new: new)
    }
    func fail(_ source: String, _ error: Error) {
        failures += 1
        log("ERROR reading \(source): \(error)")
        if isPermissionError(error) { log(fdaHint) }
        store.recordRun(device: nil, source: source, seen: 0, new: 0, error: "\(error)")
    }

    // Each source is independent: one failing must not block the other.
    var biomeRemoteCount = 0
    do {
        let results = try BiomeSource.read(paths, tmp: tmp)
        biomeRemoteCount = results.count
        for r in results { try archive(r, label: "Biome") }
    } catch {
        fail("biome:App.InFocus", error)
    }

    do {
        let db = try KnowledgeSource.open(paths, tmp: tmp)
        try archive(try KnowledgeSource.readLocal(db), label: "this Mac")
        if biomeRemoteCount == 0 {
            let remote = try KnowledgeSource.readRemote(db)
            for r in remote { try archive(r, label: "knowledgeC sync") }
            if remote.isEmpty { log("no other devices found. Is Screen Time \"Share Across Devices\" on?") }
        }
    } catch {
        fail("knowledgeC:/app/usage", error)
    }

    store.checkpoint()
    log(failures == 0 ? "done" : "finished with \(failures) error(s)")
    return failures == 0 ? 0 : 1
}

// MARK: - Diagnostics (prints counts and formats only, never app names, so output is safe to share)

func runDiagnose(paths: Paths) -> Int32 {
    let tmp = makeTempDir()
    defer { try? FileManager.default.removeItem(at: tmp) }
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
    func range(_ s: [Session]) -> String {
        guard let a = s.map(\.start).min(), let b = s.map(\.end).max() else { return "-" }
        return "\(df.string(from: Date(timeIntervalSince1970: a))) → \(df.string(from: Date(timeIntervalSince1970: b)))"
    }
    func short(_ id: String) -> String { String(id.prefix(8)) }

    var arch = utsname(); uname(&arch)
    let machine = withUnsafeBytes(of: &arch.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    print("screentime-archiver diagnostics")
    print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)  arch: \(machine)")

    print("\n[Biome] \(paths.appInFocusRemote.path)")
    do {
        let peers = BiomeSource.peers(paths, tmp: tmp)
        print("  sync.db peers: \(peers.isEmpty ? "none/unreadable" : peers.map { "\(short($0.key)) platform=\($0.value.platform) build=\($0.value.build ?? "-")" }.joined(separator: ", "))")
        let dirs = try BiomeSource.deviceDirs(paths)
        if dirs.isEmpty { print("  no remote device folders") }
        for dir in dirs {
            let segs = try BiomeSource.segments(in: dir)
            var stats = SEGB.Stats()
            var formats: [String: Int] = [:], kinds: [UInt64: Int] = [:], fieldSets: [String: Int] = [:]
            var events: [BiomeSource.Event] = []
            var errors: [String] = []
            for seg in segs {
                let data = (try? Data(contentsOf: seg)) ?? Data()
                formats[SEGB.format(of: data).rawValue, default: 0] += 1
                do {
                    for p in try SEGB.records(seg, stats: &stats) {
                        if let msg = Protobuf.decode(p) { fieldSets[msg.keys.sorted().map(String.init).joined(separator: ","), default: 0] += 1 }
                        if let e = BiomeSource.event(from: p) { events.append(e); kinds[e.kind, default: 0] += 1 }
                    }
                } catch { errors.append("\(error)") }
            }
            let sessions = BiomeSource.sessions(from: events)
            print("  device \(short(dir.lastPathComponent)): \(segs.count) segments \(formats)")
            print("    entries=\(stats.entries) live=\(stats.live) deleted=\(stats.deleted) badCRC=\(stats.badCRC) decoded=\(events.count)")
            print("    kinds=\(kinds.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" })  fieldSets=\(fieldSets.sorted { $0.value > $1.value }.prefix(5).map { "[\($0.key)]×\($0.value)" })")
            print("    sessions=\(sessions.count)  range=\(range(sessions))  hours=\(String(format: "%.1f", sessions.reduce(0) { $0 + $1.end - $1.start } / 3600))")
            for e in Set(errors) { print("    error: \(e)") }
        }
    } catch {
        print("  ERROR: \(error)")
        if isPermissionError(error) { print("  \(fdaHint)") }
    }

    print("\n[knowledgeC] \(paths.knowledgeDB.path)")
    do {
        let db = try KnowledgeSource.open(paths, tmp: tmp)
        for (device, sessions) in try KnowledgeSource.sessionsByDevice(db).sorted(by: { $0.key < $1.key }) {
            print("  \(device.isEmpty ? "this Mac" : "synced \(short(device))"): sessions=\(sessions.count) range=\(range(sessions))")
        }
    } catch {
        print("  ERROR: \(error)")
        if isPermissionError(error) || "\(error)".contains("cannot open") { print("  \(fdaHint)") }
    }
    return 0
}

// MARK: - Main

let usage = """
usage: screentime-archiver [options]
  (no options)        archive new Screen Time data
  --status            summarise what's in the archive
  --diagnose          report what Apple data is visible (no app names; safe to paste in issues)
  --archive PATH      archive file (default: \(ArchiveStore.defaultURL.path))
  --biome-dir PATH    override ~/Library/Biome (testing)
  --knowledge-db PATH override knowledgeC.db location (testing)
"""

var archiveURL = ArchiveStore.defaultURL
var paths = Paths.standard
var mode = "archive"
var args = CommandLine.arguments.dropFirst()
func expand(_ p: String) -> URL { URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
while let a = args.popFirst() {
    switch a {
    case "--archive": archiveURL = expand(args.popFirst() ?? "")
    case "--biome-dir": paths.biome = expand(args.popFirst() ?? "")
    case "--knowledge-db": paths.knowledgeDB = expand(args.popFirst() ?? "")
    case "--status": mode = "status"
    case "--diagnose": mode = "diagnose"
    case "-h", "--help": print(usage); exit(0)
    default: print("unknown argument: \(a)\n\(usage)"); exit(2)
    }
}

if mode == "diagnose" { exit(runDiagnose(paths: paths)) }

do {
    let store = try ArchiveStore(url: archiveURL)
    if mode == "status" {
        try store.printStatus()
        exit(0)
    }
    log("archiving into \(archiveURL.path)")
    exit(runArchive(paths: paths, store: store))
} catch {
    log("ERROR: \(error)")
    exit(1)
}

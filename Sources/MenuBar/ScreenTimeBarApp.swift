import SwiftUI
import Charts
import AppKit

@main
struct ScreenTimeBarApp: App {
    @StateObject private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            UsageView(model: model)
        } label: {
            Image(systemName: "iphone")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class UsageModel: ObservableObject {
    static let dayCount = 14
    static let launchdLabel = "io.github.tobias-x.screentime-archiver"

    @Published var snapshot = Archive.Snapshot()
    @Published var selectedDay: String?          // nil = whole 14-day range
    @Published var archiving = false

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
    }

    func refresh() {
        snapshot = Archive.load(dayCount: Self.dayCount, selectedDay: selectedDay)
    }

    func select(day: String?) {
        selectedDay = (day == selectedDay) ? nil : day
        refresh()
    }

    /// Asks launchd to run the archiver job now, so it runs with the archiver's own Full Disk Access.
    func archiveNow() {
        archiving = true
        let label = "gui/\(getuid())/\(Self.launchdLabel)"
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["kickstart", label]
            try? p.run()
            p.waitUntilExit()
            // kickstart returns once the job has started; give it a moment to finish.
            try? await Task.sleep(for: .seconds(4))
            await MainActor.run {
                self.archiving = false
                self.refresh()
            }
        }
    }
}

/// Device colors: orange for iPhone, blue for Mac (validated as a CVD-safe pair on light and dark surfaces).
enum DeviceColor {
    static let iPhone = Color(light: 0xeb6834, dark: 0xd95926)
    static let mac = Color(light: 0x2a78d6, dark: 0x3987e5)
    static let other = Color(light: 0x8a8a86, dark: 0x9a9a96)

    static func color(for device: Archive.Device?) -> Color {
        switch device?.platform {
        case "ios": iPhone
        case "macos": mac
        default: other
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }
}

struct UsageView: View {
    @ObservedObject var model: UsageModel
    @State private var hoveredDay: String?

    private var snap: Archive.Snapshot { model.snapshot }
    private var todayKey: String { Archive.dayFormatter.string(from: Date()) }

    /// Average per day over days with data, excluding today (it's incomplete).
    private func average(device: String? = nil) -> Double {
        let keys = snap.dates.map { Archive.dayFormatter.string(from: $0) }
            .filter { $0 != todayKey && snap.seconds(day: $0) > 0 }
        guard !keys.isEmpty else { return 0 }
        return keys.reduce(0) { $0 + snap.seconds(day: $1, device: device) } / Double(keys.count)
    }

    private func device(_ id: String) -> Archive.Device? { snap.devices.first { $0.id == id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Screen Time").font(.headline)
            if let error = snap.error {
                Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                summary
                chart
                Divider()
                topApps
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { model.refresh() }
    }

    /// Combined average plus a legend that doubles as per-device averages.
    private var summary: some View {
        HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Daily average").font(.caption).foregroundStyle(.secondary)
                Text(formatDuration(average())).font(.title2.weight(.semibold)).monospacedDigit()
            }
            ForEach(snap.devices) { d in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle().fill(DeviceColor.color(for: d)).frame(width: 8, height: 8)
                        Text(d.label)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Text(formatDuration(average(device: d.id))).font(.callout.weight(.medium)).monospacedDigit()
                }
            }
            Spacer()
        }
    }

    private struct Segment: Identifiable {
        let id: String
        let date: Date
        let key: String
        let color: Color
        let start: Double, end: Double
        let isTop: Bool
    }

    /// Stacks devices manually so we control the 2px gap between segments and round only the top segment.
    private func segments(gap: Double) -> [Segment] {
        snap.dates.flatMap { date -> [Segment] in
            let key = Archive.dayFormatter.string(from: date)
            let parts = snap.devices.map { d in (d, snap.seconds(day: key, device: d.id) / 3600) }.filter { $0.1 > 0 }
            var cum = 0.0
            return parts.enumerated().map { i, part in
                let (d, hours) = part
                let isTop = i == parts.count - 1
                let end = cum + hours
                let seg = Segment(id: key + d.id, date: date, key: key, color: DeviceColor.color(for: d),
                                  start: cum, end: isTop ? end : max(cum, end - gap), isTop: isTop)
                cum = end
                return seg
            }
        }
    }

    private var chart: some View {
        let highlighted = hoveredDay ?? model.selectedDay
        let maxHours = snap.dates.map { snap.seconds(day: Archive.dayFormatter.string(from: $0)) / 3600 }.max() ?? 0
        let plotHeight = 130.0
        let gap = maxHours * 2 / plotHeight   // ≈2pt in data units
        return VStack(alignment: .leading, spacing: 4) {
            Chart(segments(gap: gap)) { seg in
                BarMark(
                    x: .value("Day", seg.date, unit: .day),
                    yStart: .value("Start", seg.start),
                    yEnd: .value("End", seg.end),
                    width: .ratio(0.6)
                )
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: seg.isTop ? 4 : 0, topTrailingRadius: seg.isTop ? 4 : 0))
                .foregroundStyle(seg.color.opacity(highlighted == nil || highlighted == seg.key ? 1 : 0.35))
            }
            .chartYScale(domain: 0...max(1, maxHours * 1.05))
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let h = v.as(Double.self) { Text("\(Int(h))h") } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.defaultDigits), centered: true)
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let p): hoveredDay = dayKey(at: p, proxy: proxy, geo: geo)
                            case .ended: hoveredDay = nil
                            }
                        }
                        .onTapGesture { p in
                            if let k = dayKey(at: p, proxy: proxy, geo: geo) { model.select(day: k) }
                        }
                }
            }
            .frame(height: plotHeight)

            chartCaption
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    @ViewBuilder private var chartCaption: some View {
        if let key = hoveredDay ?? model.selectedDay, let date = Archive.dayFormatter.date(from: key) {
            HStack(spacing: 10) {
                Text("\(date.formatted(.dateTime.weekday().day().month())): \(formatDuration(snap.seconds(day: key)))")
                ForEach(snap.devices) { d in
                    HStack(spacing: 4) {
                        Circle().fill(DeviceColor.color(for: d)).frame(width: 6, height: 6)
                        Text("\(d.label) \(formatDuration(snap.seconds(day: key, device: d.id)))")
                    }
                }
            }
        } else {
            Text("Click a bar to see that day's apps")
        }
    }

    private func dayKey(at point: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> String? {
        guard let plot = proxy.plotFrame else { return nil }
        let x = point.x - geo[plot].origin.x
        guard let date: Date = proxy.value(atX: x) else { return nil }
        let key = Archive.dayFormatter.string(from: date)
        return snap.dates.contains { Archive.dayFormatter.string(from: $0) == key } ? key : nil
    }

    private var topApps: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(topAppsTitle).font(.subheadline.weight(.semibold))
                Spacer()
                if model.selectedDay != nil {
                    Button("Show all \(UsageModel.dayCount) days") { model.select(day: nil) }
                        .buttonStyle(.link).font(.caption)
                }
            }
            if snap.topApps.isEmpty {
                Text("No usage recorded").foregroundStyle(.secondary).font(.callout)
            }
            let maxSecs = snap.topApps.first?.seconds ?? 1
            ForEach(snap.topApps) { app in
                let d = device(app.deviceID)
                let color = DeviceColor.color(for: d)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 7, height: 7)
                            .help(d?.label ?? "")
                        Text(app.name).lineLimit(1).help("\(app.bundleID) · \(d?.label ?? "")")
                        Spacer()
                        Text(formatDuration(app.seconds)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                    GeometryReader { g in
                        Capsule().fill(color.opacity(0.85))
                            .frame(width: max(2, g.size.width * app.seconds / maxSecs), height: 3)
                    }
                    .frame(height: 3)
                    .padding(.leading, 13)
                }
            }
        }
    }

    private var topAppsTitle: String {
        if let key = model.selectedDay, let date = Archive.dayFormatter.date(from: key) {
            return "Top apps · \(date.formatted(.dateTime.weekday().day().month()))"
        }
        return "Top apps · last \(UsageModel.dayCount) days"
    }

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                if let last = snap.lastRun {
                    Text("Archived \(last.formatted(.relative(presentation: .named)))")
                } else {
                    Text("Never archived")
                }
                if snap.lastRunError != nil {
                    Label("Last run had errors. Check Full Disk Access", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button {
                model.archiveNow()
            } label: {
                if model.archiving { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .help("Archive now")
            .disabled(model.archiving)
            Menu {
                Button("Open Archive Folder") {
                    NSWorkspace.shared.open(Archive.url.deletingLastPathComponent())
                }
                Button("Open Log") {
                    let log = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Logs/ScreenTimeArchive/archiver.log")
                    NSWorkspace.shared.open(log)
                }
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
    }
}

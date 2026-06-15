import AppKit
import Combine
import SwiftUI

private let apiURL = URL(string: "https://status.input.im/api/status")!
private let statusPageURL = URL(string: "https://status.input.im/")!
private let modelName = "gpt-5.5"

@main
struct GPT55StatusBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = StatusMonitor()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        monitor.onChange = { [weak self] in
            self?.updateStatusItem()
        }

        configureStatusItem()
        configurePopover()
        updateStatusItem()

        Task { await monitor.refresh() }
        scheduleRefreshTimer()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 280, height: 220)
        popover.contentViewController = NSHostingController(
            rootView: StatusPopoverView(
                monitor: monitor,
                onRefresh: { [weak self] in self?.triggerRefresh() },
                onOpenStatusPage: { NSWorkspace.shared.open(statusPageURL) }
            )
        )
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.triggerRefresh()
            }
        }
    }

    private func triggerRefresh() {
        Task { await monitor.refresh() }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let snapshot = monitor.snapshot
        let color: NSColor
        switch snapshot.mode {
        case .healthy:
            color = .systemGreen
        case .failing:
            color = .systemRed
        case .error, .loading:
            color = .systemOrange
        }

        let title = NSAttributedString(
            string: "GPT-5.5",
            attributes: [
                .foregroundColor: color,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            ]
        )
        button.attributedTitle = title
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

enum SnapshotMode {
    case loading
    case healthy
    case failing
    case error
}

struct StatusSnapshot {
    var mode: SnapshotMode = .loading
    var uptimePct: Double?
    var latencyMs: Int?
    var lastCheck: Date?
    var errorMessage: String?
    var isStale: Bool = false
    var history: [Bool?] = []

    var statusText: String {
        switch mode {
        case .loading: return "检查中"
        case .healthy: return "在线"
        case .failing: return "异常"
        case .error: return "错误"
        }
    }

    var statusColor: Color {
        switch mode {
        case .healthy: return .green
        case .failing: return .red
        case .error, .loading: return .orange
        }
    }

    var barColor: Color {
        switch mode {
        case .healthy: return .green
        case .failing: return .red
        case .error, .loading: return .gray
        }
    }

    static var loading: StatusSnapshot {
        StatusSnapshot(mode: .loading, uptimePct: nil, latencyMs: nil, lastCheck: nil, errorMessage: nil, isStale: false, history: [])
    }
}

@MainActor
final class StatusMonitor: ObservableObject {
    @Published private(set) var snapshot = StatusSnapshot.loading
    var onChange: (() -> Void)?

    func refresh() async {
        do {
            var request = URLRequest(url: apiURL, timeoutInterval: 12)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("GPT55StatusBarApp", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                throw URLError(.badServerResponse)
            }
            let payload = try JSONDecoder().decode(StatusResponse.self, from: data)

            guard let service = payload.services.first(where: { $0.model == modelName }) else {
                snapshot = StatusSnapshot(
                    mode: .error,
                    uptimePct: nil,
                    latencyMs: nil,
                    lastCheck: Date(),
                    errorMessage: "未找到模型",
                    isStale: false,
                    history: []
                )
                onChange?()
                return
            }

            let last = service.last
            let isHealthy = last?.ok == true
            snapshot = StatusSnapshot(
                mode: isHealthy ? .healthy : .failing,
                uptimePct: service.uptime_pct,
                latencyMs: last?.latency_ms,
                lastCheck: date(from: last?.ts ?? payload.generated_at),
                errorMessage: last?.error,
                isStale: false,
                history: recentHistory(from: service.history)
            )
            onChange?()
        } catch {
            snapshot = failedRefreshSnapshot(from: snapshot)
            onChange?()
        }
    }

    private func date(from timestamp: Int?) -> Date? {
        guard let timestamp else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    private func recentHistory(from samples: [StatusSample]) -> [Bool?] {
        let recent = samples.suffix(30).map { Optional($0.ok) }
        let missing = max(0, 30 - recent.count)
        return Array(repeating: nil, count: missing) + recent
    }

    private func failedRefreshSnapshot(from current: StatusSnapshot) -> StatusSnapshot {
        guard !current.history.isEmpty else {
            return StatusSnapshot(
                mode: .error,
                uptimePct: nil,
                latencyMs: nil,
                lastCheck: Date(),
                errorMessage: "请求失败",
                isStale: false,
                history: []
            )
        }

        return StatusSnapshot(
            mode: current.mode,
            uptimePct: current.uptimePct,
            latencyMs: current.latencyMs,
            lastCheck: current.lastCheck,
            errorMessage: "刷新失败，显示上次数据",
            isStale: true,
            history: current.history
        )
    }
}

struct StatusResponse: Decodable {
    let all_ok: Bool
    let generated_at: Int?
    let services: [StatusService]
}

struct StatusService: Decodable {
    let model: String
    let uptime_pct: Double
    let last: StatusSample?
    let history: [StatusSample]
}

struct StatusSample: Decodable {
    let ts: Int?
    let ok: Bool
    let latency_ms: Int?
    let error: String?
}

struct StatusPopoverView: View {
    @ObservedObject var monitor: StatusMonitor
    let onRefresh: () -> Void
    let onOpenStatusPage: () -> Void

    private let barCount = 30
    private static let lastCheckFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        let snapshot = monitor.snapshot

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text("GPT-5.5")
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.82))
                    .shadow(color: Color.black.opacity(0.10), radius: 1, x: 0, y: 1)

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(snapshot.statusColor)
                        .frame(width: 7, height: 7)
                    Text(snapshot.statusText)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(snapshot.statusColor)
                }
                .padding(.top, 1)
            }

            VStack(alignment: .leading, spacing: 9) {
                GlassStatLine(systemImage: "waveform.path.ecg", label: "可用率", value: uptimeText(snapshot.uptimePct))
                GlassStatLine(systemImage: "clock", label: "延迟", value: latencyText(snapshot.latencyMs))
                GlassStatLine(systemImage: "calendar", label: "最近检查", value: lastCheckText(snapshot.lastCheck))

                if let errorMessage = snapshot.errorMessage, !errorMessage.isEmpty {
                    GlassStatLine(
                        systemImage: snapshot.isStale ? "arrow.clockwise.icloud" : "exclamationmark.triangle",
                        label: snapshot.isStale ? "提示" : "错误",
                        value: errorMessage,
                        isMuted: snapshot.isStale
                    )
                }
            }

            Divider()
                .overlay(Color.white.opacity(0.20))

            StatusBarsView(samples: snapshot.history, fallbackColor: snapshot.barColor, count: barCount)
                .frame(height: 18)
                .shadow(color: snapshot.barColor.opacity(0.24), radius: 3, x: 0, y: 0)

            HStack(spacing: 9) {
                Button("打开状态页", action: onOpenStatusPage)
                    .buttonStyle(GlassButtonStyle())
                Button("刷新", action: onRefresh)
                    .buttonStyle(GlassButtonStyle())
            }
            .padding(.top, 3)
        }
        .padding(.horizontal, 18)
        .padding(.top, 15)
        .padding(.bottom, 15)
        .frame(width: 280, height: 220)
        .background(.ultraThinMaterial)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.38), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.20), radius: 16, x: 0, y: 8)
    }

    private func uptimeText(_ uptime: Double?) -> String {
        guard let uptime else { return "-" }
        return String(format: "%.2f%%", uptime)
    }

    private func latencyText(_ latency: Int?) -> String {
        guard let latency else { return "-" }
        return "\(latency)ms"
    }

    private func lastCheckText(_ date: Date?) -> String {
        guard let date else { return "-" }
        return Self.lastCheckFormatter.string(from: date)
    }
}

struct StatusBarsView: View {
    let samples: [Bool?]
    let fallbackColor: Color
    let count: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color(for: sample(at: index)))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func sample(at index: Int) -> Bool? {
        guard index < samples.count else { return nil }
        return samples[index]
    }

    private func color(for sample: Bool?) -> Color {
        switch sample {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return fallbackColor.opacity(0.32)
        }
    }
}

struct GlassStatLine: View {
    let systemImage: String
    let label: String
    let value: String
    var isMuted: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.black.opacity(isMuted ? 0.38 : 0.56))
                .frame(width: 16)

            Text(label)
                .font(.system(size: 12, weight: .medium, design: .default))
                .foregroundStyle(Color.black.opacity(isMuted ? 0.46 : 0.66))
                .frame(width: 58, alignment: .leading)

            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.black.opacity(isMuted ? 0.60 : 0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .shadow(color: Color.black.opacity(0.08), radius: 1, x: 0, y: 1)
        }
    }
}

struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium, design: .default))
            .foregroundStyle(Color.black.opacity(0.82))
            .frame(width: 119, height: 33)
            .background(.thinMaterial)
            .background(Color.white.opacity(configuration.isPressed ? 0.27 : 0.16))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.30), lineWidth: 1)
            )
    }
}

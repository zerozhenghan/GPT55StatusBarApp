import AppKit
import Combine
import SwiftUI

private let apiURL = URL(string: "https://status.input.im/api/status")!
private let statusPageURL = URL(string: "https://status.input.im/")!
private let modelName = "gpt-5.5"
private let displayModelName = "GPT-5.5"
private let historyCount = 60
private let leaderboardURL = URL(string: "https://scys.com/tokenrank/api/subapp/leaderboard")!
private let leaderboardHandle = "郑韩"
private let leaderboardUserID = 36449

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

        Task { await monitor.refresh(forceLeaderboard: true) }
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
        popover.contentSize = NSSize(width: 332, height: 612)
        popover.contentViewController = NSHostingController(
            rootView: DashboardPopoverView(
                monitor: monitor,
                onRefresh: { [weak self] in self?.triggerRefresh() },
                onOpenStatusPage: { NSWorkspace.shared.open(statusPageURL) },
                onOpenConfig: { Self.openUsageConfigFolder() },
                onQuit: { NSApp.terminate(nil) }
            )
        )
    }

    private static func openUsageConfigFolder() {
        let folder = UsageConfig.configDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let example = folder.appendingPathComponent("config.example.json")
        if !FileManager.default.fileExists(atPath: example.path) {
            let content = """
            {
              "name": "Codex",
              "base_url": "https://ai.input.im",
              "api_key": "在这里填写你的 API Key"
            }
            """
            try? content.write(to: example, atomically: true, encoding: .utf8)
        }

        NSWorkspace.shared.open(folder)
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                Task { await self?.monitor.refresh(forceLeaderboard: false) }
            }
        }
    }

    private func triggerRefresh() {
        Task { await monitor.refresh(forceLeaderboard: true) }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let snapshot = monitor.snapshot
        let presentation = menuBarPresentation(snapshot: snapshot, settings: MenuBarSettings.load())

        statusItem.length = NSStatusItem.variableLength
        button.image = nil
        button.imagePosition = .noImage
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = nil

        let title = NSAttributedString(
            string: presentation.title,
            attributes: [
                .foregroundColor: presentation.color,
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium)
            ]
        )
        button.attributedTitle = title
    }

    private func menuBarPresentation(snapshot: DashboardSnapshot, settings: MenuBarSettings) -> (title: String, color: NSColor) {
        switch settings.displayMode {
        case .model:
            return (displayModelName, statusMenuColor(snapshot.mode))
        case .status:
            return ("状态 \(snapshot.statusText)", statusMenuColor(snapshot.mode))
        case .siteName:
            let usage = selectedUsage(from: snapshot, settings: settings)
            return (usage?.accountName ?? "站点 --", usageMenuColor(usage))
        case .todayCost:
            let usage = selectedUsage(from: snapshot, settings: settings)
            return (menuCurrencyText(usage?.todayCost, unit: usage?.unit ?? "USD"), usageMenuColor(usage))
        case .balance:
            let usage = selectedUsage(from: snapshot, settings: settings)
            return (menuCurrencyText(usage?.remaining, unit: usage?.unit ?? "USD"), usageMenuColor(usage))
        case .averageDuration:
            let usage = selectedUsage(from: snapshot, settings: settings)
            return ("耗时 \(menuDurationText(usage?.averageDurationMs))", usageMenuColor(usage))
        }
    }

    private func selectedUsage(from snapshot: DashboardSnapshot, settings: MenuBarSettings) -> UsageSnapshot? {
        if let siteName = settings.siteName?.lowercased(), !siteName.isEmpty {
            return snapshot.usages.first { $0.accountName.lowercased() == siteName }
                ?? snapshot.usages.first { $0.accountName.lowercased().contains(siteName) }
        }
        return snapshot.usages.first { $0.mode == .valid } ?? snapshot.usages.first
    }

    private func statusMenuColor(_ mode: SnapshotMode) -> NSColor {
        switch mode {
        case .healthy:
            return .systemGreen
        case .failing:
            return .systemRed
        case .error, .loading:
            return .systemOrange
        }
    }

    private func usageMenuColor(_ usage: UsageSnapshot?) -> NSColor {
        guard let usage else { return .systemOrange }
        switch usage.mode {
        case .valid:
            return .systemGreen
        case .invalid, .error:
            return .systemRed
        case .loading, .notConfigured:
            return .systemOrange
        }
    }

    private func menuCurrencyText(_ value: Double?, unit: String) -> String {
        guard let value else { return "--" }
        return currencyText(value, unit: unit)
    }

    private func menuDurationText(_ value: Double?) -> String {
        guard let value else { return "--" }
        if value >= 1_000 {
            return String(format: "%.1fs", value / 1_000)
        }
        return "\(Int(value))ms"
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

struct StatusPoint {
    var ok: Bool
    var latencyMs: Int?
}

struct DashboardSnapshot {
    var mode: SnapshotMode = .loading
    var uptimePct: Double?
    var latencyMs: Int?
    var lastCheck: Date?
    var generatedAt: Date?
    var refreshedAt: Date?
    var errorMessage: String?
    var isStale: Bool = false
    var isRefreshing: Bool = false
    var history: [StatusPoint?] = []
    var usages: [UsageSnapshot] = [.notConfigured(accountName: "Codex")]
    var leaderboard: LeaderboardSnapshot = .empty

    var statusText: String {
        switch mode {
        case .loading: return "检查中"
        case .healthy: return "在线"
        case .failing: return "失败"
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

    var sampleCount: Int {
        history.compactMap { $0 }.count
    }

    static var loading: DashboardSnapshot {
        DashboardSnapshot(
            mode: .loading,
            uptimePct: nil,
            latencyMs: nil,
            lastCheck: nil,
            generatedAt: nil,
            refreshedAt: nil,
            errorMessage: nil,
            isStale: false,
            isRefreshing: false,
            history: []
        )
    }
}

struct LeaderboardSnapshot {
    var rank: Int?
    var score: Int?
    var codexScore: Int?
    var claudeCodeScore: Int?
    var refreshedAt: Date?
    var errorMessage: String?
    var isRefreshing: Bool = false

    var hasData: Bool {
        rank != nil || score != nil || codexScore != nil || claudeCodeScore != nil
    }

    static var empty: LeaderboardSnapshot {
        LeaderboardSnapshot()
    }

    func loading() -> LeaderboardSnapshot {
        LeaderboardSnapshot(
            rank: rank,
            score: score,
            codexScore: codexScore,
            claudeCodeScore: claudeCodeScore,
            refreshedAt: refreshedAt,
            errorMessage: nil,
            isRefreshing: true
        )
    }

    func failed(message: String) -> LeaderboardSnapshot {
        LeaderboardSnapshot(
            rank: rank,
            score: score,
            codexScore: codexScore,
            claudeCodeScore: claudeCodeScore,
            refreshedAt: refreshedAt,
            errorMessage: message,
            isRefreshing: false
        )
    }
}

enum UsageMode {
    case notConfigured
    case loading
    case valid
    case invalid
    case error
}

struct UsageSnapshot {
    var mode: UsageMode
    var accountName: String
    var remaining: Double?
    var unit: String
    var todayCost: Double?
    var todayLimit: Double?
    var week: Double?
    var weekLimit: Double?
    var month: Double?
    var monthLimit: Double?
    var averageDurationMs: Double?
    var expiresAt: Date?
    var lastSuccessAt: Date?
    var errorMessage: String?

    var validityText: String {
        switch mode {
        case .valid: return "有效"
        case .invalid: return "无效"
        case .loading: return "正在刷新"
        case .notConfigured: return "未配置"
        case .error: return "读取失败"
        }
    }

    var validityColor: Color {
        switch mode {
        case .valid: return .green
        case .invalid, .error: return .red
        case .loading: return .orange
        case .notConfigured: return .white.opacity(0.72)
        }
    }

    static func notConfigured(accountName: String) -> UsageSnapshot {
        UsageSnapshot(
            mode: .notConfigured,
            accountName: accountName,
            remaining: nil,
            unit: "USD",
            todayCost: nil,
            todayLimit: nil,
            week: nil,
            weekLimit: nil,
            month: nil,
            monthLimit: nil,
            averageDurationMs: nil,
            expiresAt: nil,
            lastSuccessAt: nil,
            errorMessage: "未配置 API Key"
        )
    }

    func loading() -> UsageSnapshot {
        UsageSnapshot(
            mode: .loading,
            accountName: accountName,
            remaining: remaining,
            unit: unit,
            todayCost: todayCost,
            todayLimit: todayLimit,
            week: week,
            weekLimit: weekLimit,
            month: month,
            monthLimit: monthLimit,
            averageDurationMs: averageDurationMs,
            expiresAt: expiresAt,
            lastSuccessAt: lastSuccessAt,
            errorMessage: nil
        )
    }

    func failed(message: String) -> UsageSnapshot {
        UsageSnapshot(
            mode: remaining == nil && todayCost == nil && week == nil && month == nil ? .error : mode,
            accountName: accountName,
            remaining: remaining,
            unit: unit,
            todayCost: todayCost,
            todayLimit: todayLimit,
            week: week,
            weekLimit: weekLimit,
            month: month,
            monthLimit: monthLimit,
            averageDurationMs: averageDurationMs,
            expiresAt: expiresAt,
            lastSuccessAt: lastSuccessAt,
            errorMessage: message
        )
    }
}

struct UsageConfig: Decodable {
    var name: String
    var baseURL: URL
    var apiKey: String

    var id: String {
        "\(name)-\(baseURL.absoluteString)"
    }

    enum CodingKeys: String, CodingKey {
        case name
        case baseURL = "base_url"
        case apiKey = "api_key"
    }

    static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GPT55StatusBarApp", isDirectory: true)
    }

    static var configFile: URL {
        configDirectory.appendingPathComponent("config.json")
    }

    static func loadAll() -> [UsageConfig] {
        let env = ProcessInfo.processInfo.environment
        var configs: [UsageConfig] = []

        if let apiKey = cleanKey(env["INPUT_IM_API_KEY"] ?? env["OPENAI_API_KEY"]) {
            let baseURL = URL(string: env["INPUT_IM_BASE_URL"] ?? "https://ai.input.im")!
            configs.append(UsageConfig(name: env["INPUT_IM_ACCOUNT_NAME"] ?? "Codex", baseURL: baseURL, apiKey: apiKey))
        }

        if let apiKey = cleanKey(env["LUCEN_API_KEY"] ?? env["LUCEN_CC_API_KEY"]) {
            let baseURL = URL(string: env["LUCEN_BASE_URL"] ?? "https://lucen.cc")!
            configs.append(UsageConfig(name: env["LUCEN_ACCOUNT_NAME"] ?? "Lucen", baseURL: baseURL, apiKey: apiKey))
        }

        if !configs.isEmpty {
            return unique(configs)
        }

        if let envFile = loadEnvFile() {
            return envFile
        }

        guard let data = try? Data(contentsOf: configFile),
              let config = try? JSONDecoder().decode(UsageConfig.self, from: data),
              !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !config.apiKey.contains("在这里填写") else {
            return []
        }
        return [config]
    }

    private static func load() -> UsageConfig? {
        loadAll().first
    }

    private static func loadEnvFile() -> [UsageConfig]? {
        let bundlePath = Bundle.main.bundleURL.deletingLastPathComponent().path
        let candidates = [
            bundlePath + "/账号配置.env",
            bundlePath + "/../账号配置.env",
            FileManager.default.currentDirectoryPath + "/账号配置.env",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/ai 编程项目/小工具/GPT55StatusBarApp/账号配置.env").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/账号配置.env").path
        ]

        for path in candidates {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path),
                  let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let configs = parseEnv(content)
            if !configs.isEmpty {
                return configs
            }
        }
        return nil
    }

    private static func parseEnv(_ content: String) -> [UsageConfig] {
        var values: [String: String] = [:]
        var looseValues: [String] = []
        for raw in content.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                values[String(key)] = value
            } else {
                looseValues.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
            }
        }

        var configs: [UsageConfig] = []

        if let apiKey = cleanKey(values["INPUT_IM_API_KEY"] ?? values["OPENAI_API_KEY"]) {
            let baseURL = URL(string: values["INPUT_IM_BASE_URL"] ?? "https://ai.input.im") ?? URL(string: "https://ai.input.im")!
            configs.append(UsageConfig(
                name: values["INPUT_IM_ACCOUNT_NAME"] ?? "Codex",
                baseURL: baseURL,
                apiKey: apiKey
            ))
        }

        if let apiKey = cleanKey(values["LUCEN_API_KEY"] ?? values["LUCEN_CC_API_KEY"]) {
            let baseURL = URL(string: values["LUCEN_BASE_URL"] ?? "https://lucen.cc") ?? URL(string: "https://lucen.cc")!
            configs.append(UsageConfig(
                name: values["LUCEN_ACCOUNT_NAME"] ?? "Lucen",
                baseURL: baseURL,
                apiKey: apiKey
            ))
        }

        if configs.isEmpty, let apiKey = cleanKey(values["API_KEY"] ?? looseValues.first) {
            let explicitBaseURL = values["BASE_URL"] ?? values["INPUT_IM_BASE_URL"] ?? values["LUCEN_BASE_URL"]
            let baseURLString = explicitBaseURL ?? "https://lucen.cc"
            let defaultName = explicitBaseURL == nil ? "Lucen" : "Codex"
            let baseURL = URL(string: baseURLString) ?? URL(string: "https://lucen.cc")!
            configs.append(UsageConfig(
                name: values["ACCOUNT_NAME"] ?? defaultName,
                baseURL: baseURL,
                apiKey: apiKey
            ))
        }

        return unique(configs)
    }

    private static func cleanKey(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.contains("在这里填写") else {
            return nil
        }
        return trimmed
    }

    private static func unique(_ configs: [UsageConfig]) -> [UsageConfig] {
        var seen: Set<String> = []
        return configs.filter { config in
            let key = config.id
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }
}

enum MenuBarDisplayMode: String {
    case todayCost = "today_cost"
    case balance
    case averageDuration = "average_duration"
    case status
    case model
    case siteName = "site_name"
}

struct MenuBarSettings {
    var displayMode: MenuBarDisplayMode = .todayCost
    var siteName: String?

    static func load() -> MenuBarSettings {
        let env = ProcessInfo.processInfo.environment
        var settings = MenuBarSettings(
            displayMode: MenuBarDisplayMode(rawValue: normalize(env["MENU_BAR_DISPLAY"])) ?? .todayCost,
            siteName: clean(env["MENU_BAR_SITE"])
        )

        if let values = loadEnvValues() {
            if let mode = MenuBarDisplayMode(rawValue: normalize(values["MENU_BAR_DISPLAY"])) {
                settings.displayMode = mode
            }
            if let siteName = clean(values["MENU_BAR_SITE"]) {
                settings.siteName = siteName
            }
        }

        return settings
    }

    private static func loadEnvValues() -> [String: String]? {
        let bundlePath = Bundle.main.bundleURL.deletingLastPathComponent().path
        let candidates = [
            bundlePath + "/账号配置.env",
            bundlePath + "/../账号配置.env",
            FileManager.default.currentDirectoryPath + "/账号配置.env",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/ai 编程项目/小工具/GPT55StatusBarApp/账号配置.env").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/账号配置.env").path
        ]

        for path in candidates {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path),
                  let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            return parseEnvValues(content)
        }
        return nil
    }

    private static func parseEnvValues(_ content: String) -> [String: String] {
        var values: [String: String] = [:]
        for raw in content.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq].trimmingCharacters(in: .whitespacesAndNewlines))
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            values[key] = value
        }
        return values
    }

    private static func normalize(_ value: String?) -> String {
        clean(value)?
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_") ?? ""
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

@MainActor
final class StatusMonitor: ObservableObject {
    @Published private(set) var snapshot = DashboardSnapshot.loading
    var onChange: (() -> Void)?

    private var usageConfigs = UsageConfig.loadAll()

    func refresh(forceLeaderboard: Bool = false) async {
        usageConfigs = UsageConfig.loadAll()
        var loadingSnapshot = snapshot
        loadingSnapshot.isRefreshing = true
        if usageConfigs.isEmpty {
            loadingSnapshot.usages = [.notConfigured(accountName: snapshot.usages.first?.accountName ?? "Codex")]
        } else {
            loadingSnapshot.usages = usageConfigs.map { config in
                let previous = snapshot.usages.first { $0.accountName == config.name }
                return previous?.loading() ?? UsageSnapshot.notConfigured(accountName: config.name).loading()
            }
        }
        if shouldRefreshLeaderboard(force: forceLeaderboard, snapshot: snapshot.leaderboard) {
            loadingSnapshot.leaderboard = loadingSnapshot.leaderboard.loading()
        }
        snapshot = loadingSnapshot
        onChange?()

        var nextSnapshot: DashboardSnapshot
        do {
            nextSnapshot = try await loadStatusSnapshot(keepingUsages: snapshot.usages)
        } catch {
            nextSnapshot = failedRefreshSnapshot(from: snapshot, message: "刷新失败，显示上次数据")
        }

        if usageConfigs.isEmpty {
            nextSnapshot.usages = [.notConfigured(accountName: "Codex")]
        } else {
            var loadedUsages: [UsageSnapshot] = []
            for config in usageConfigs {
                let previous = nextSnapshot.usages.first { $0.accountName == config.name } ?? .notConfigured(accountName: config.name)
                do {
                    loadedUsages.append(try await loadUsageSnapshot(config: config, previous: previous))
                } catch {
                    loadedUsages.append(previous.failed(message: "用量读取失败"))
                }
            }
            nextSnapshot.usages = loadedUsages
        }

        if shouldRefreshLeaderboard(force: forceLeaderboard, snapshot: snapshot.leaderboard) {
            do {
                nextSnapshot.leaderboard = try await loadLeaderboardSnapshot(previous: nextSnapshot.leaderboard)
            } catch {
                nextSnapshot.leaderboard = snapshot.leaderboard.failed(message: "排行刷新失败")
            }
        } else {
            nextSnapshot.leaderboard = snapshot.leaderboard
        }

        nextSnapshot.isRefreshing = false
        nextSnapshot.refreshedAt = Date()
        snapshot = nextSnapshot
        onChange?()
    }

    private func shouldRefreshLeaderboard(force: Bool, snapshot: LeaderboardSnapshot) -> Bool {
        if force { return true }
        guard let refreshedAt = snapshot.refreshedAt else { return true }
        return Date().timeIntervalSince(refreshedAt) >= 3600
    }

    private func loadStatusSnapshot(keepingUsages usages: [UsageSnapshot]) async throws -> DashboardSnapshot {
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
            return DashboardSnapshot(
                mode: .error,
                uptimePct: nil,
                latencyMs: nil,
                lastCheck: Date(),
                generatedAt: date(from: payload.generated_at),
                refreshedAt: Date(),
                errorMessage: "未找到模型",
                isStale: false,
                isRefreshing: false,
                history: [],
                usages: usages
            )
        }

        let last = service.last
        let isHealthy = last?.ok == true
        return DashboardSnapshot(
            mode: isHealthy ? .healthy : .failing,
            uptimePct: service.uptime_pct,
            latencyMs: last?.latency_ms,
            lastCheck: date(from: last?.ts ?? payload.generated_at),
            generatedAt: date(from: payload.generated_at),
            refreshedAt: Date(),
            errorMessage: last?.error,
            isStale: false,
            isRefreshing: false,
            history: recentHistory(from: service.history),
            usages: usages
        )
    }

    private func loadUsageSnapshot(config: UsageConfig, previous: UsageSnapshot) async throws -> UsageSnapshot {
        var components = URLComponents(url: config.baseURL.appendingPathComponent("v1/usage"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "period", value: "today"),
            URLQueryItem(name: "timezone", value: TimeZone.current.identifier),
            URLQueryItem(name: "days", value: "30")
        ]
        guard let usageURL = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: usageURL, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("GPT55StatusBarApp", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }

        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let isValid = value.bool(at: [["is_active"], ["isValid"], ["valid"], ["subscription", "active"]]) ?? true
        let subscription = value.value(at: [["subscription"]])
        let currentKeyToday = value.double(at: [["usage", "today", "actual_cost"], ["usage", "today", "cost"]])
        let currentKeyTotal = value.double(at: [["usage", "total", "actual_cost"], ["usage", "total", "cost"]])
        return UsageSnapshot(
            mode: isValid ? .valid : .invalid,
            accountName: config.name,
            remaining: value.double(at: [["remaining"], ["quota", "remaining"], ["balance"], ["data", "remaining"]]),
            unit: value.string(at: [["unit"], ["quota", "unit"], ["currency"]]) ?? previous.unit,
            todayCost: subscription?.double(at: [["daily_usage_usd"]]) ?? currentKeyToday ?? value.double(at: [["today"], ["today_cost"], ["costs", "today"], ["daily"]]),
            todayLimit: subscription?.double(at: [["daily_limit_usd"]]),
            week: subscription?.double(at: [["weekly_usage_usd"]]) ?? value.double(at: [["week"], ["week_cost"], ["usage", "week"], ["costs", "week"], ["weekly"]]) ?? currentKeyTotal,
            weekLimit: subscription?.double(at: [["weekly_limit_usd"]]),
            month: subscription?.double(at: [["monthly_usage_usd"]]) ?? value.double(at: [["month"], ["month_cost"], ["usage", "month"], ["costs", "month"], ["monthly"]]) ?? currentKeyTotal,
            monthLimit: subscription?.double(at: [["monthly_limit_usd"]]),
            averageDurationMs: value.double(at: [["usage", "average_duration_ms"], ["average_duration_ms"]]),
            expiresAt: subscription?.date(at: [["expires_at"]]) ?? value.date(at: [["expires_at"], ["expire_at"], ["subscription", "expires_at"], ["plan", "expires_at"]]),
            lastSuccessAt: Date(),
            errorMessage: nil
        )
    }

    private func loadLeaderboardSnapshot(previous: LeaderboardSnapshot) async throws -> LeaderboardSnapshot {
        let payload = try await loadLeaderboardPayload(board: "total", includeMe: false)
        var entry = payload.entries.first { $0.userId == leaderboardUserID || $0.name == leaderboardHandle }
        if entry == nil {
            entry = try? await loadMyLeaderboardEntry()
        }

        guard let entry else {
            return LeaderboardSnapshot(
                rank: nil,
                score: nil,
                codexScore: nil,
                claudeCodeScore: nil,
                refreshedAt: Date(),
                errorMessage: "今日暂无排名",
                isRefreshing: false
            )
        }

        return LeaderboardSnapshot(
            rank: entry.rank,
            score: entry.score,
            codexScore: entry.byTool["codex"],
            claudeCodeScore: entry.byTool["claude-code"],
            refreshedAt: Date(),
            errorMessage: nil,
            isRefreshing: false
        )
    }

    private func loadLeaderboardPayload(board: String, includeMe: Bool) async throws -> LeaderboardResponse {
        var components = URLComponents(url: leaderboardURL, resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "board", value: "total"),
            URLQueryItem(name: "range", value: "today")
        ]
        queryItems[0] = URLQueryItem(name: "board", value: board)
        if includeMe {
            queryItems.append(URLQueryItem(name: "me", value: String(leaderboardUserID)))
            queryItems.append(URLQueryItem(name: "limit", value: "1"))
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GPT55StatusBarApp", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(LeaderboardResponse.self, from: data)
    }

    private func loadMyLeaderboardEntry() async throws -> LeaderboardEntry? {
        let payload = try await loadLeaderboardPayload(board: "total", includeMe: true)
        if let entry = payload.entries.first(where: { $0.userId == leaderboardUserID || $0.name == leaderboardHandle }) {
            return entry
        }
        guard let myRank = payload.myRank else { return nil }
        var byTool: [String: Int] = [:]
        byTool["codex"] = try? await loadMyToolScore(board: "codex")
        byTool["claude-code"] = try? await loadMyToolScore(board: "claude-code")
        return LeaderboardEntry(
            rank: myRank.rank,
            userId: leaderboardUserID,
            name: leaderboardHandle,
            score: myRank.score,
            byTool: myRank.byTool ?? byTool,
            cost: myRank.cost,
            anomaly: nil
        )
    }

    private func loadMyToolScore(board: String) async throws -> Int {
        let payload = try await loadLeaderboardPayload(board: board, includeMe: true)
        if let entry = payload.entries.first(where: { $0.userId == leaderboardUserID || $0.name == leaderboardHandle }) {
            return entry.score
        }
        return payload.myRank?.score ?? 0
    }

    private func date(from timestamp: Int?) -> Date? {
        guard let timestamp else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    private func recentHistory(from samples: [StatusSample]) -> [StatusPoint?] {
        let recent = samples.suffix(historyCount).map {
            Optional(StatusPoint(ok: $0.ok, latencyMs: $0.latency_ms))
        }
        let missing = max(0, historyCount - recent.count)
        return Array(repeating: nil, count: missing) + recent
    }

    private func failedRefreshSnapshot(from current: DashboardSnapshot, message: String) -> DashboardSnapshot {
        guard !current.history.isEmpty else {
            return DashboardSnapshot(
                mode: .error,
                uptimePct: nil,
                latencyMs: nil,
                lastCheck: Date(),
                generatedAt: current.generatedAt,
                refreshedAt: Date(),
                errorMessage: "请求失败",
                isStale: false,
                isRefreshing: false,
                history: [],
                usages: current.usages
            )
        }

        return DashboardSnapshot(
            mode: current.mode,
            uptimePct: current.uptimePct,
            latencyMs: current.latencyMs,
            lastCheck: current.lastCheck,
            generatedAt: current.generatedAt,
            refreshedAt: current.refreshedAt,
            errorMessage: message,
            isStale: true,
            isRefreshing: false,
            history: current.history,
            usages: current.usages
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

struct LeaderboardResponse: Decodable {
    let status: Int?
    let board: String?
    let range: String?
    let entries: [LeaderboardEntry]
    let myRank: LeaderboardRank?
}

struct LeaderboardRank: Decodable {
    let rank: Int
    let score: Int
    let cost: Double?
    let byTool: [String: Int]?
}

struct LeaderboardEntry: Decodable {
    let rank: Int
    let userId: Int?
    let name: String
    let score: Int
    let byTool: [String: Int]
    let cost: Double?
    let anomaly: Bool?
}

enum JSONValue: Decodable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            self = .null
        }
    }

    func value(at path: [String]) -> JSONValue? {
        guard let first = path.first else { return self }
        guard case .object(let object) = self, let next = object[first] else { return nil }
        return next.value(at: Array(path.dropFirst()))
    }

    func value(at paths: [[String]]) -> JSONValue? {
        for path in paths {
            if let value = value(at: path) {
                return value
            }
        }
        return nil
    }

    func double(at paths: [[String]]) -> Double? {
        value(at: paths)?.doubleValue
    }

    func int(at paths: [[String]]) -> Int? {
        value(at: paths)?.intValue
    }

    func string(at paths: [[String]]) -> String? {
        value(at: paths)?.stringValue
    }

    func bool(at paths: [[String]]) -> Bool? {
        value(at: paths)?.boolValue
    }

    func date(at paths: [[String]]) -> Date? {
        value(at: paths)?.dateValue
    }

    var doubleValue: Double? {
        switch self {
        case .number(let number): return number
        case .string(let string): return Double(string)
        default: return nil
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let string): return string
        case .number(let number): return String(number)
        case .bool(let bool): return bool ? "true" : "false"
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let bool): return bool
        case .number(let number): return number != 0
        case .string(let string):
            let lowercased = string.lowercased()
            if ["true", "valid", "active", "yes", "1"].contains(lowercased) { return true }
            if ["false", "invalid", "inactive", "no", "0"].contains(lowercased) { return false }
            return nil
        default:
            return nil
        }
    }

    var dateValue: Date? {
        switch self {
        case .number(let number):
            return Date(timeIntervalSince1970: number)
        case .string(let string):
            if let timestamp = Double(string) {
                return Date(timeIntervalSince1970: timestamp)
            }
            return ISO8601DateFormatter().date(from: string)
        default:
            return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let number): return Int(number)
        case .string(let string): return Int(string)
        default: return nil
        }
    }
}

struct DashboardPopoverView: View {
    @ObservedObject var monitor: StatusMonitor
    let onRefresh: () -> Void
    let onOpenStatusPage: () -> Void
    let onOpenConfig: () -> Void
    let onQuit: () -> Void

    var body: some View {
        let snapshot = monitor.snapshot

        VStack(alignment: .leading, spacing: 14) {
            header(snapshot: snapshot)
            serviceSection(snapshot: snapshot)
            UsageCardsView(usages: snapshot.usages, refreshedAt: snapshot.refreshedAt)
            LeaderboardView(leaderboard: snapshot.leaderboard)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 18)
        .frame(width: 332, height: 612, alignment: .top)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.10, blue: 0.13).opacity(0.70),
                    Color(red: 0.02, green: 0.03, blue: 0.05).opacity(0.58)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.34), radius: 18, x: 0, y: 10)
    }

    private func header(snapshot: DashboardSnapshot) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("用量监控")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.95))

                Text("1 个模型")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.48))

                Text(snapshot.isRefreshing ? "正在刷新" : refreshSummary(snapshot))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.44))
            }

            Spacer()

            HStack(spacing: 7) {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(IconGlassButtonStyle())

                Button(action: onOpenStatusPage) {
                    Image(systemName: "scope")
                }
                .buttonStyle(IconGlassButtonStyle())

                Button(action: onOpenConfig) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(IconGlassButtonStyle())

                Button(action: onQuit) {
                    Image(systemName: "power")
                }
                .buttonStyle(IconGlassButtonStyle())
            }
        }
    }

    private func serviceSection(snapshot: DashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("服务状态")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.92))
                Spacer()
                Text("1 model")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.44))
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(displayModelName)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.94))

                    Circle()
                        .fill(snapshot.statusColor.opacity(0.95))
                        .frame(width: 6, height: 6)

                    Text(snapshot.statusText)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(snapshot.statusColor)
                }

                HStack(spacing: 12) {
                    MetricPair(label: "可用率", value: uptimeText(snapshot.uptimePct), valueColor: uptimeColor(snapshot.uptimePct))
                    MetricPair(label: "样本", value: "\(snapshot.sampleCount)/\(historyCount)", valueColor: .white.opacity(0.92))
                    Spacer()
                    MetricPair(label: "延迟", value: latencyText(snapshot.latencyMs), valueColor: .white.opacity(0.92))
                }

                StatusTimelineView(samples: snapshot.history)
                    .frame(height: 20)

                HStack {
                    Text("-60m")
                    Spacer()
                    Text("-45m")
                    Spacer()
                    Text("-30m")
                    Spacer()
                    Text("-15m")
                    Spacer()
                    Text("现在")
                }
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.36))

                HStack(spacing: 14) {
                    Text("接口生成 \(timeText(snapshot.generatedAt))")
                    Text("状态刷新 \(timeText(snapshot.refreshedAt))")
                }
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.34))
                .padding(.top, 1)

                if let errorMessage = snapshot.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(snapshot.isStale ? Color.orange.opacity(0.92) : Color.red.opacity(0.92))
                        .lineLimit(1)
                }
            }
        }
    }

    private func refreshSummary(_ snapshot: DashboardSnapshot) -> String {
        if snapshot.isStale { return "显示上次数据" }
        guard let refreshedAt = snapshot.refreshedAt else { return "等待刷新" }
        return "已更新 \(timeText(refreshedAt))"
    }

    private func uptimeText(_ uptime: Double?) -> String {
        guard let uptime else { return "-" }
        return String(format: "%.2f%%", uptime)
    }

    private func uptimeColor(_ uptime: Double?) -> Color {
        guard let uptime else { return .white.opacity(0.92) }
        if uptime >= 99 { return .green }
        if uptime >= 95 { return .yellow }
        return .orange
    }

    private func latencyText(_ latency: Int?) -> String {
        guard let latency else { return "-" }
        return "\(latency)ms"
    }
}

struct MetricPair: View {
    let label: String
    let value: String
    let valueColor: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.38))
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(valueColor)
        }
    }
}

struct StatusTimelineView: View {
    let samples: [StatusPoint?]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<historyCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color(for: sample(at: index)))
                    .frame(height: 16)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func sample(at index: Int) -> StatusPoint? {
        guard index < samples.count else { return nil }
        return samples[index]
    }

    private func color(for sample: StatusPoint?) -> Color {
        guard let sample else { return Color.white.opacity(0.15) }
        guard sample.ok else { return .red }
        if let latency = sample.latencyMs, latency >= 8_000 {
            return .yellow
        }
        return .green
    }
}

struct UsageCardsView: View {
    let usages: [UsageSnapshot]
    let refreshedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("站点用量")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.90))
                Spacer()
                Text("\(usages.count) 个站点")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.40))
            }

            ForEach(Array(usages.enumerated()), id: \.offset) { index, usage in
                UsageCardView(usage: usage, index: index + 1, total: usages.count, refreshedAt: refreshedAt)
            }
        }
    }
}

struct UsageCardView: View {
    let usage: UsageSnapshot
    let index: Int
    let total: Int
    let refreshedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                HStack(spacing: 6) {
                    BadgeNumber(text: "\(index)")
                    Text(usage.accountName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.94))
                }
                Spacer()
                Text(total > 1 ? "\(index)/\(total)" : "当前站点")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.34))
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(usage.mode == .loading ? "正在刷新" : usageStatusLine(usage))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.40))

                Text("上次成功刷新 \(timeText(usage.lastSuccessAt ?? refreshedAt))")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.40))

                HStack {
                    Text("GPT-5.5 状态查询")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.94))
                    Spacer()
                    Text(usage.validityText)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(usage.validityColor)
                }
                .padding(.top, 2)

                Text("订阅")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.90))

                UsageLine(label: "今日", value: usageAmountText(usage.todayCost, limit: usage.todayLimit, unit: usage.unit), trailing: nil)
                UsageLine(label: "本周", value: usageAmountText(usage.week, limit: usage.weekLimit, unit: usage.unit), trailing: nil)
                UsageLine(label: "本月", value: usageAmountText(usage.month, limit: usage.monthLimit, unit: usage.unit), trailing: nil)
                UsageLine(label: "耗时", value: durationText(usage.averageDurationMs), trailing: nil)

                Text(expireText(usage.expiresAt))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.38))

                if let errorMessage = usage.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(usage.mode == .notConfigured ? Color.white.opacity(0.32) : Color.orange.opacity(0.90))
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func usageStatusLine(_ usage: UsageSnapshot) -> String {
        switch usage.mode {
        case .valid: return "用量数据已同步"
        case .invalid: return "Key 状态无效"
        case .notConfigured: return "未配置用量 Key"
        case .error: return "用量读取失败"
        case .loading: return "正在刷新"
        }
    }

    private func moneyText(_ value: Double?, unit: String) -> String {
        guard let value else { return "--" }
        return currencyText(value, unit: unit)
    }

    private func usageAmountText(_ value: Double?, limit: Double?, unit: String) -> String {
        let current = moneyText(value, unit: unit)
        guard let limit else { return "\(current) / ∞" }
        return "\(current) / \(currencyText(limit, unit: unit))"
    }

    private func expireText(_ date: Date?) -> String {
        guard let date else { return "有效期 --" }
        return dateText(date)
    }

    private func durationText(_ value: Double?) -> String {
        guard let value else { return "--" }
        if value >= 1_000 {
            return String(format: "%.1fs", value / 1_000)
        }
        return "\(Int(value))ms"
    }
}

struct UsageLine: View {
    let label: String
    let value: String
    let trailing: String?

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.38))
                .frame(width: 30, alignment: .leading)

            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.90))

            Spacer()

            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.38))
            }
        }
    }
}

struct LeaderboardView: View {
    let leaderboard: LeaderboardSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("今日排行")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.90))

                Spacer()

                Text(statusText)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusColor)
            }

            if leaderboard.hasData {
                HStack(spacing: 14) {
                    LeaderboardMetric(label: "总量", value: compactNumber(leaderboard.score))
                    LeaderboardMetric(label: "codex", value: compactNumber(leaderboard.codexScore))
                    LeaderboardMetric(label: "claude-code", value: compactNumber(leaderboard.claudeCodeScore))
                }
            } else {
                Text(leaderboard.errorMessage ?? "等待刷新")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.34))
            }
        }
        .padding(.top, 2)
    }

    private var statusText: String {
        if leaderboard.isRefreshing { return "刷新中" }
        if let rank = leaderboard.rank { return "#\(rank)" }
        return "--"
    }

    private var statusColor: Color {
        if leaderboard.isRefreshing { return .orange }
        if leaderboard.rank != nil { return .green }
        return .white.opacity(0.42)
    }
}

struct LeaderboardMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.36))
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.90))
                .lineLimit(1)
                .minimumScaleFactor(0.80)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BadgeNumber: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(Color(red: 0.08, green: 0.10, blue: 0.13))
            .frame(width: 16, height: 16)
            .background(Color.white.opacity(0.96))
            .clipShape(Circle())
    }
}

struct IconGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.62 : 0.90))
            .frame(width: 30, height: 28)
            .background(Color.white.opacity(configuration.isPressed ? 0.18 : 0.10))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct ArrowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.50 : 0.62))
            .frame(width: 28, height: 28)
            .background(Color.white.opacity(configuration.isPressed ? 0.11 : 0.07))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private func timeText(_ date: Date?) -> String {
    guard let date else { return "--:--:--" }
    return Formatters.time.string(from: date)
}

private func dateText(_ date: Date?) -> String {
    guard let date else { return "--" }
    return Formatters.date.string(from: date)
}

private func currencyText(_ value: Double, unit: String) -> String {
    let symbol = unit.uppercased() == "USD" ? "$" : "\(unit) "
    return "\(symbol)\(String(format: "%.2f", value))"
}

private func compactNumber(_ value: Int?) -> String {
    guard let value else { return "--" }
    if value >= 100_000_000 {
        return String(format: "%.2f亿", Double(value) / 100_000_000)
    }
    if value >= 10_000 {
        return String(format: "%.1f万", Double(value) / 10_000)
    }
    return Formatters.integer.string(from: NSNumber(value: value)) ?? "\(value)"
}

private enum Formatters {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()

    static let leaderboardDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let integer: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}

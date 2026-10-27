import AppKit
import SwiftUI
import UserNotifications
import CStatusCore

@MainActor
final class AppModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var errors: [String] = []
    @Published var liveMessage = "正在检查状态来源…"
    @Published var connected = false
    @Published var expanded = false
    @Published var pinned = false
    @Published var dragging = false
    @Published var filter = "当前"
    @Published var search = ""
    @Published var actionMessage = ""
    @Published var lastRefresh: Date?
    @Published var hooksObserved = 0
    @Published var side: EdgeSide { didSet { defaults.set(side.rawValue, forKey: "side"); onLayout?() } }
    @Published var screenID: String { didSet { defaults.set(screenID, forKey: "screenID"); onLayout?() } }
    @Published var anchorY: Double { didSet { defaults.set(anchorY, forKey: "anchorY") } }
    @Published var sound: Bool { didSet { defaults.set(sound, forKey: "sound") } }
    @Published var systemNotifications: Bool { didSet { defaults.set(systemNotifications, forKey: "systemNotifications") } }
    @Published var roots: [String] { didSet { defaults.set(roots, forKey: "roots") } }
    @Published var cliPath: String { didSet { defaults.set(cliPath, forKey: "cliPath") } }
    @Published var socketPath: String { didSet { defaults.set(socketPath, forKey: "socketPath") } }
    var onReminder: ((Session) -> Void)?
    var onSettings: (() -> Void)?
    var onLayout: (() -> Void)?
    var onCount: ((Int) -> Void)?
    private let defaults: UserDefaults
    private var engine = StateEngine()
    private var gate: ReminderGate
    private let worker = MonitorWorker()
    private var liveMonitors: [LiveMonitor] = []
    private var loop: Task<Void, Never>?
    private var initialIDs: Set<String> = []
    private var hidden: Set<String>
    private var acknowledged: Set<String>
    private var remindersDirty = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
        side = EdgeSide(rawValue: d.string(forKey: "side") ?? "right") ?? .right
        screenID = d.string(forKey: "screenID") ?? ""
        anchorY = d.object(forKey: "anchorY") as? Double ?? 240
        sound = d.bool(forKey: "sound"); systemNotifications = d.bool(forKey: "systemNotifications")
        let root = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        roots = (d.stringArray(forKey: "roots") ?? [root]).map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        cliPath = d.string(forKey: "cliPath") ?? ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path].first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
        socketPath = d.string(forKey: "socketPath") ?? ""
        hidden = Set(d.stringArray(forKey: "hidden") ?? [])
        acknowledged = Set(d.stringArray(forKey: "acknowledged") ?? [])
        gate = ReminderGate(seen: Set(d.stringArray(forKey: "reminders") ?? []))
    }
    var activeCount: Int { sessions.filter { $0.isMainTask && $0.isActive }.count }
    var attentionCount: Int { sessions.filter { $0.isMainTask && $0.status.needsAttention && !isAcknowledged($0) && Date().timeIntervalSince($0.updatedAt) < 86400 }.count }
    var visible: [Session] {
        sessions.filter { session in
            guard session.isMainTask, !hidden.contains(session.id) || session.isActive else { return false }
            if filter == "待处理" && (!session.status.needsAttention || isAcknowledged(session)) { return false }
            if filter == "当前", !session.isActive, Date().timeIntervalSince(session.updatedAt) > 86400 { return false }
            if !search.isEmpty && !(session.title + session.cwd + session.origin.label).localizedCaseInsensitiveContains(search) { return false }
            return true
        }
    }
    func isAcknowledged(_ s: Session) -> Bool { acknowledged.contains(ackKey(s)) }
    private func ackKey(_ s: Session) -> String { s.id + ":" + (s.turnID ?? "") + ":" + s.status.rawValue }

    func start() {
        restartConnections()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let rootURLs = roots.map { URL(fileURLWithPath: $0).standardizedFileURL }
                let batch = await worker.poll(roots: rootURLs, hookDirectory: HookBridge.defaultDirectory)
                if Task.isCancelled { return }
                receive(batch)
                try? await Task.sleep(for: .milliseconds(750))
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil; liveMonitors.forEach { $0.stop() } }
    func restartConnections() {
        engine.reconcileRoots(Set(roots)); publish()
        connected = false; liveMessage = "正在检查状态来源…"
        liveMonitors.forEach { $0.stop() }; liveMonitors = []
        for (index, root) in roots.enumerated() {
            let live = LiveMonitor()
            live.onEvent = { [weak self] observed in self?.consume(observed); self?.publish() }
            live.onMetadata = { [weak self] session in self?.engine.discover(session) }
            live.onConnection = { [weak self] ok, message in
                guard let self else { return }
                if index == 0 { connected = ok; liveMessage = message }
            }
            live.start(root: root, executable: cliPath, socket: index == 0 ? socketPath : "")
            liveMonitors.append(live)
        }
    }
    func receive(_ batch: MonitorBatch) {
        let configured = Set(roots)
        for session in batch.sessions where configured.contains(session.namespace) { engine.discover(session) }
        for observed in batch.events where configured.contains(observed.event.namespace) { consume(observed) }
        // Historical inProgress only proves that no terminal record was found.
        let candidates = Set(batch.sessions.map(\.id) + batch.events.filter(\.isInitial).map { $0.event.sessionID })
        let newIDs = candidates.subtracting(initialIDs)
        engine.markHistoricalUnconfirmed(newIDs)
        initialIDs.formUnion(newIDs)
        errors = Array(Set(batch.errors)).sorted(); lastRefresh = Date(); publish()
    }
    func consume(_ observed: ObservedEvent) {
        var event = observed.event
        guard roots.contains(event.namespace) else { return }
        if event.turnID == nil { event.turnID = engine.sessions[event.sessionID]?.turnID }
        let previous = engine.sessions[event.sessionID]
        let changed = engine.apply(event)
        guard let session = engine.sessions[event.sessionID], changed || session.lastEventAt == event.timestamp else { return }
        if event.evidence == .hook { hooksObserved += 1 }
        let isRequest: Bool
        if case .requested = event.kind { isRequest = true } else { isRequest = false }
        let beforeCount = gate.seen.count
        let accepted = gate.accept(event, isInitial: observed.isInitial)
        remindersDirty = remindersDirty || gate.seen.count != beforeCount
        if accepted && (changed || isRequest), session.isMainTask,
           !(previous?.status == session.status && !isRequest) {
            hidden.remove(session.id)
            onReminder?(session)
            if sound { NSSound(named: "Glass")?.play() }
            if systemNotifications { sendSystemNotification(session) }
        }
    }
    private func publish() {
        if remindersDirty {
            defaults.set(Array(gate.seen.sorted().suffix(2000)), forKey: "reminders"); remindersDirty = false
        }
        sessions = engine.sessions.values.filter(\.isMainTask).sorted {
            if $0.status.priority != $1.status.priority { return $0.status.priority < $1.status.priority }
            return $0.updatedAt > $1.updatedAt
        }
        onCount?(activeCount)
    }
    func acknowledge(_ session: Session) {
        acknowledged.insert(ackKey(session)); defaults.set(Array(acknowledged.suffix(1000)), forKey: "acknowledged"); publish()
    }
    func hide(_ session: Session) { hidden.insert(session.id); defaults.set(Array(hidden), forKey: "hidden"); publish() }
    func showHidden() { hidden = []; defaults.removeObject(forKey: "hidden"); publish() }
    func copyID(_ session: Session) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.threadID, forType: .string) }
    func locate(_ session: Session) {
        copyID(session)
        switch session.origin {
        case .vscode:
            if !session.cwd.isEmpty, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
                NSWorkspace.shared.open([URL(fileURLWithPath: session.cwd)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                actionMessage = "已打开 VS Code 项目，并复制线程 ID；请在 Codex 历史中定位会话。"
            } else { activate(bundle: "com.microsoft.VSCode", label: "VS Code") }
        case .desktop: activate(bundle: "com.openai.codex", label: "Codex")
        case .cli:
            activate(bundle: "com.apple.Terminal", label: "终端")
            actionMessage = "已打开终端并复制线程 ID；可运行 codex resume <线程 ID>。"
        default:
            if !session.cwd.isEmpty { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd) }
            actionMessage = "已复制线程 ID；此来源暂无精确跳转接口。"
        }
        acknowledge(session)
    }
    private func activate(bundle: String, label: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            actionMessage = "未找到 \(label)；线程 ID 已复制。"; return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        actionMessage = "已激活 \(label)，线程 ID 已复制；未自动切换具体会话。"
    }
    func addRoot() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "选择 Codex 数据目录（通常是 ~/.codex）"
        if panel.runModal() == .OK, let path = panel.url?.standardizedFileURL.path, !roots.contains(path) {
            roots.append(path); restartConnections()
        }
    }
    func selectCLI() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.message = "选择 Codex CLI 可执行文件"
        if panel.runModal() == .OK, let url = panel.url { cliPath = url.path; restartConnections() }
    }
    func configureHooks(enable: Bool) {
        guard let root = roots.first, let executable = Bundle.main.executableURL?.path else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent("hooks.json")
        do {
            let data = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            let existing: [String: Any]
            if let data {
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw NSError(domain: "cStatus", code: 1, userInfo: [NSLocalizedDescriptionKey: "hooks.json 顶层格式不正确，未修改"])
                }
                existing = object
            } else { existing = [:] }
            let updated = enable ? try HookBridge.configuration(executable: executable, existing: existing) : HookBridge.removingOwned(from: existing)
            if let data { try data.write(to: url.appendingPathExtension("cstatus-\(Int(Date().timeIntervalSince1970)).bak"), options: .atomic) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            actionMessage = enable ? "已合并钩子并备份原配置。请在 Codex 中用 /hooks 审阅并信任，重新打开会话。配置写入不代表事件已接入。" : "已移除 cStatus 钩子，保留其他钩子。请重新打开 Codex 会话。"
        } catch { actionMessage = "钩子配置失败：\(error.localizedDescription)" }
    }
    func enableNotifications(_ value: Bool) {
        guard value else { systemNotifications = false; return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] allowed, _ in
            Task { @MainActor in self?.systemNotifications = allowed; if !allowed { self?.actionMessage = "系统通知未获授权；应用冒泡仍可使用。" } }
        }
    }
    private func sendSystemNotification(_ s: Session) {
        let content = UNMutableNotificationContent(); content.title = "\(s.project) · \(s.status.label)"; content.body = String(s.title.prefix(150))
        let request = UNNotificationRequest(identifier: s.id + ":" + (s.turnID ?? "") + ":" + s.status.rawValue, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    func demonstrate() {
        var demo = Session(namespace: "demo", threadID: UUID().uuidString, title: "提醒预览 · 任务需要你回答", cwd: "/示例项目", origin: .vscode)
        demo.status = .waitingInput
        onReminder?(demo)
    }
}

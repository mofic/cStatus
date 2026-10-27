import Foundation

public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case unknown, idle, running, waitingInput, waitingApproval, completed, interrupted, failed, disconnected
    public var label: String {
        switch self {
        case .unknown: return "状态未知"
        case .idle: return "空闲"
        case .running: return "运行中"
        case .waitingInput: return "等待回答"
        case .waitingApproval: return "等待授权"
        case .completed: return "已完成"
        case .interrupted: return "已中断"
        case .failed: return "失败"
        case .disconnected: return "连接丢失"
        }
    }
    public var needsAttention: Bool { [.waitingInput, .waitingApproval, .failed, .interrupted, .disconnected].contains(self) }
    public var terminal: Bool { [.completed, .interrupted, .failed].contains(self) }
    public var priority: Int {
        switch self {
        case .waitingInput, .waitingApproval: return 0
        case .failed, .interrupted, .disconnected: return 1
        case .running: return 2
        case .completed: return 3
        case .idle, .unknown: return 4
        }
    }
}

public enum ClientOrigin: String, Codable, CaseIterable, Sendable {
    case cli, vscode, desktop, subagent, unknown
    public var label: String {
        switch self {
        case .cli: return "CLI"
        case .vscode: return "VS Code"
        case .desktop: return "Codex App"
        case .subagent: return "子任务"
        case .unknown: return "未知来源"
        }
    }
    public static func detect(source: String, originator: String = "") -> ClientOrigin {
        let text = (source + " " + originator).lowercased()
        if text.contains("subagent") { return .subagent }
        if text.contains("vscode") || text.contains("vs_code") { return .vscode }
        if text.contains("desktop") || text.contains("codex_app") || text.contains("codex-app") { return .desktop }
        if source == "cli" || source == "exec" || text.contains("codex-tui") { return .cli }
        return .unknown
    }
}

public enum Evidence: String, Codable, Sendable { case history, transcript, live, hook, process }
public enum RequestKind: String, Codable, Sendable { case input, approval }

public struct Session: Identifiable, Codable, Equatable, Sendable {
    public var id: String { namespace + "::" + threadID }
    public var namespace: String
    public var threadID: String
    public var title: String
    public var cwd: String
    public var origin: ClientOrigin
    public var version: String
    public var parentID: String?
    public var rolloutPath: String
    public var turnID: String?
    public var status: TaskStatus = .unknown
    public var activity: String = ""
    public var requests: [String: RequestKind] = [:]
    public var updatedAt: Date
    public var evidence: Evidence = .history
    public var liveConnected = false
    public var lastEventAt: Date = .distantPast
    public var turnStartedAt: Date = .distantPast
    public var runtimeFlags: [RequestKind] = []
    public var retiredTurnIDs: Set<String> = []
    public var classificationKnown = true
    public var recordedTaskOpen = false
    public var writerActive = false
    public var isMainTask: Bool {
        classificationKnown && origin != .subagent && parentID == nil &&
        !(cwd == namespace + "/memories" || cwd.hasPrefix(namespace + "/memories/"))
    }
    public var isActive: Bool { [.running, .waitingInput, .waitingApproval].contains(status) }

    public init(namespace: String, threadID: String, title: String = "Codex 任务", cwd: String = "",
                origin: ClientOrigin = .unknown, version: String = "", parentID: String? = nil,
                rolloutPath: String = "", updatedAt: Date = Date()) {
        self.namespace = namespace; self.threadID = threadID; self.title = title; self.cwd = cwd
        self.origin = origin; self.version = version; self.parentID = parentID
        self.rolloutPath = rolloutPath; self.updatedAt = updatedAt
    }
    public var project: String { cwd.isEmpty ? "未提供项目" : URL(fileURLWithPath: cwd).lastPathComponent }
    public var coverageLabel: String {
        if liveConnected { return "实时连接" }
        if writerActive { return "运行进程已确认 · 本地事件" }
        if evidence == .hook { return "钩子事件 · 连接未确认" }
        return "本地记录 · 等待状态覆盖有限"
    }
}

public enum EventKind: Equatable, Sendable {
    case started, ended(TaskStatus), requested(String, RequestKind), resolved(String)
    case runtime(TaskStatus, [RequestKind]), activity(String), disconnected, writerObserved(Bool)
}

public struct StatusEvent: Sendable {
    public var namespace: String
    public var threadID: String
    public var turnID: String?
    public var timestamp: Date
    public var kind: EventKind
    public var evidence: Evidence
    public var sessionID: String { namespace + "::" + threadID }
    public init(namespace: String, threadID: String, turnID: String? = nil, timestamp: Date = Date(), kind: EventKind, evidence: Evidence) {
        self.namespace = namespace; self.threadID = threadID; self.turnID = turnID
        self.timestamp = timestamp; self.kind = kind; self.evidence = evidence
    }
}

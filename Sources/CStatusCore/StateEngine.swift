import Foundation

public struct StateEngine {
    public private(set) var sessions: [String: Session] = [:]
    public init() {}

    public mutating func markHistoricalUnconfirmed(_ ids: Set<String>) {
        for id in ids {
            guard var s = sessions[id], !s.liveConnected, !s.writerActive, [.running, .waitingInput, .waitingApproval].contains(s.status) else { continue }
            let last = s.status.label
            s.status = .unknown; s.activity = "上次记录：\(last)，当前状态未确认"
            sessions[id] = s
        }
    }

    public mutating func reconcileRoots(_ roots: Set<String>) {
        sessions = sessions.filter { roots.contains($0.value.namespace) }
        for (id, var session) in sessions where session.liveConnected {
            session.liveConnected = false
            if !session.status.terminal { session.status = .disconnected }
            sessions[id] = session
        }
    }

    public mutating func discover(_ metadata: Session) {
        guard var old = sessions[metadata.id] else { sessions[metadata.id] = metadata; return }
        old.title = metadata.title; old.cwd = metadata.cwd
        if metadata.origin != .unknown { old.origin = metadata.origin }
        old.classificationKnown = old.classificationKnown || metadata.classificationKnown
        old.version = metadata.version; old.parentID = metadata.parentID ?? old.parentID; old.rolloutPath = metadata.rolloutPath
        sessions[old.id] = old
    }

    @discardableResult public mutating func apply(_ e: StatusEvent) -> Bool {
        var s: Session
        if let known = sessions[e.sessionID] { s = known }
        else { s = Session(namespace: e.namespace, threadID: e.threadID); s.classificationKnown = false }
        if case .writerObserved(let active) = e.kind {
            let previous = s.status
            s.writerActive = active && s.recordedTaskOpen
            if s.recordedTaskOpen && !s.liveConnected {
                if active && [.unknown, .disconnected].contains(s.status) { s.status = requestStatus(s) ?? .running }
                if !active && s.isActive { s.status = .unknown; s.activity = "未确认到运行进程，保留上次任务记录" }
            }
            // Runtime observations must not advance the persisted event clock.
            sessions[s.id] = s
            return previous != s.status
        }
        var isNewTurn = false
        if let incoming = e.turnID, let current = s.turnID, incoming != current {
            guard case .started = e.kind, e.timestamp >= s.turnStartedAt, !s.retiredTurnIDs.contains(incoming) else { return false }
            s.retiredTurnIDs.insert(current)
            isNewTurn = true
        }
        let confirmsIdleResult: Bool
        if case .ended = e.kind {
            confirmsIdleResult = e.turnID != nil && e.turnID == s.turnID && [.idle, .disconnected].contains(s.status) && e.timestamp >= s.turnStartedAt
        } else { confirmsIdleResult = false }
        guard e.timestamp >= s.lastEventAt || confirmsIdleResult || isNewTurn else { return false }
        if isNewTurn { s.lastEventAt = e.timestamp }
        // Disk projections can lag behind a live request in the same turn.
        if (e.evidence == .history || e.evidence == .transcript), s.liveConnected {
            switch e.kind { case .started, .activity: return false; default: break }
        }
        let previous = s.status
        switch e.kind {
        case .started:
            s.recordedTaskOpen = true
            if s.turnID != e.turnID || s.status.terminal {
                s.requests = [:]; s.runtimeFlags = []; s.activity = ""
                s.turnStartedAt = e.timestamp
            }
            s.turnID = e.turnID ?? s.turnID; s.status = .running
        case .ended(let status):
            s.recordedTaskOpen = false; s.writerActive = false
            s.turnID = e.turnID ?? s.turnID; s.status = status; s.requests = [:]; s.runtimeFlags = []; s.activity = ""
        case .requested(let id, let kind):
            if s.status.terminal { return false }
            s.turnID = e.turnID ?? s.turnID; s.requests[id] = kind
            s.status = requestStatus(s) ?? .running
        case .resolved(let id):
            guard s.requests.removeValue(forKey: id) != nil else { return false }
            s.status = requestStatus(s) ?? .running
        case .runtime(let status, let flags):
            s.liveConnected = status != .disconnected && status != .unknown
            s.runtimeFlags = flags
            s.requests = s.requests.filter { flags.contains($0.value) }
            if status == .running { s.status = requestStatus(s) ?? .running }
            else if status == .idle, s.status.terminal { break }
            else { s.status = status }
        case .activity(let activity):
            if s.status.terminal { return false }
            s.activity = activity
            if s.recordedTaskOpen, [.unknown, .idle, .disconnected].contains(s.status), !activity.hasPrefix("本轮输出结束") { s.status = .running }
        case .disconnected:
            s.liveConnected = false
            if !s.status.terminal { s.status = .disconnected }
        case .writerObserved: break // Handled before event ordering.
        }
        if e.evidence == .live {
            if case .runtime(let status, _) = e.kind { s.liveConnected = status != .unknown && status != .disconnected }
            else { s.liveConnected = true }
        }
        if case .disconnected = e.kind { s.liveConnected = false }
        s.evidence = e.evidence; s.lastEventAt = max(s.lastEventAt, e.timestamp)
        if previous != s.status || !s.activity.isEmpty { s.updatedAt = e.timestamp }
        sessions[s.id] = s
        return previous != s.status
    }

    private func requestStatus(_ s: Session) -> TaskStatus? {
        let kinds = Array(s.requests.values) + s.runtimeFlags
        if kinds.contains(.input) { return .waitingInput }
        if kinds.contains(.approval) { return .waitingApproval }
        return nil
    }
}

public struct ReminderGate {
    public var seen: Set<String>
    public init(seen: Set<String> = []) { self.seen = seen }
    public mutating func accept(_ event: StatusEvent, isInitial: Bool) -> Bool {
        let token: String
        switch event.kind {
        case .requested(let id, let kind):
            token = "request:\(id):\(kind.rawValue)" + (event.evidence == .hook && id.hasPrefix("hook:") ? ":\(event.timestamp.timeIntervalSince1970)" : "")
        case .ended(let status): token = status.rawValue
        case .runtime(let status, let flags):
            guard flags.count > 0 || status == .failed else {
                let prefix = event.sessionID + ":" + (event.turnID ?? "runtime") + ":runtime:"
                seen = seen.filter { !$0.hasPrefix(prefix) }
                return false
            }
            token = "runtime:" + status.rawValue + flags.map(\.rawValue).sorted().joined(separator: ",")
        case .disconnected: token = "disconnected"
        default: return false
        }
        let key = event.sessionID + ":" + (event.turnID ?? "runtime") + ":" + token
        let inserted = seen.insert(key).inserted
        return inserted && !isInitial
    }
}

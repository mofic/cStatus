import Foundation
import CStatusCore

/// Observes an existing daemon only. Never starts/resumes turns or answers requests.
@MainActor
final class LiveMonitor {
    var onEvent: ((ObservedEvent) -> Void)?
    var onMetadata: ((Session) -> Void)?
    var onConnection: ((Bool, String) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var buffer = Data()
    private var timer: Timer?
    private var root = ""
    private var executable = ""
    private var socket = ""
    private var nextID = 10
    private var requests: [Int: String] = [:]
    private var loaded: [String] = []
    private var loadingPages: [String] = []
    private var pageCursors: Set<String> = []
    private var pollQueue: [String] = []
    private var baselines: Set<String> = []
    private var turnBaselines: Set<String> = []
    private var connected = false
    private var startedAt = Date()
    private var lastResponseAt = Date()
    private var retryAt = Date.distantPast

    func start(root: String, executable: String, socket: String) {
        stop(); self.root = root; self.executable = executable; self.socket = socket
        connect()
        timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    func stop() { timer?.invalidate(); timer = nil; disconnect(report: false) }
    private func connect() {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            onConnection?(false, "未找到 Codex CLI；可在设置中选择可执行文件")
            retryAt = Date().addingTimeInterval(10); return
        }
        let path = socket.isEmpty ? root + "/app-server-control/app-server-control.sock" : socket
        guard FileManager.default.fileExists(atPath: path) else {
            onConnection?(false, "未发现共享服务 socket；当前使用本地记录，等待状态覆盖有限")
            retryAt = Date().addingTimeInterval(10); return
        }
        let p = Process(); let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["app-server", "proxy", "--sock", path]
        var environment = ProcessInfo.processInfo.environment; environment["CODEX_HOME"] = root; p.environment = environment
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; errors = stderr.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data, from: p) }
        }
        errors?.readabilityHandler = { handle in _ = handle.availableData }
        p.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard self?.process === process else { return }
                self?.disconnect(report: true)
            }
        }
        do {
            try p.run(); process = p; buffer = Data(); requests = [:]; baselines = []; turnBaselines = []; loaded = []; pollQueue = []
            startedAt = Date(); lastResponseAt = Date()
            onConnection?(false, "观察代理已启动，等待现有服务握手")
            send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "cstatus", "title": "cStatus", "version": "0.1.0"], "capabilities": ["experimentalApi": true]]])
        } catch { disconnect(report: true) }
    }
    private func tick() {
        guard process != nil else { if Date() >= retryAt { connect() }; return }
        if !connected {
            if Date().timeIntervalSince(startedAt) > 6 { disconnect(report: true) }
            return
        }
        if Date().timeIntervalSince(lastResponseAt) > 10 { disconnect(report: true); return }
        if !requests.values.contains(where: { $0.hasPrefix("loaded") }) {
            loadingPages = []; pageCursors = []
            request("thread/loaded/list", params: ["limit": 200], tag: "loaded")
        }
        if pollQueue.isEmpty { pollQueue = loaded }
        pumpPolls()
    }
    private func pumpPolls() {
        while !pollQueue.isEmpty && requests.values.filter({ !$0.hasPrefix("loaded") }).count < 32 {
            let id = pollQueue.removeFirst()
            guard loaded.contains(id) else { continue }
            request("thread/read", params: ["threadId": id, "includeTurns": false], tag: id)
            request("thread/turns/list", params: ["threadId": id, "limit": 1, "sortDirection": "desc"], tag: "turn:" + id)
        }
    }
    private func loadedPage(_ result: [String: Any]) {
        loadingPages += result["data"] as? [String] ?? []
        if let cursor = result["nextCursor"] as? String, !cursor.isEmpty {
            guard pageCursors.insert(cursor).inserted else {
                onConnection?(true, "服务返回重复分页游标；加载列表不完整，保留上次状态")
                return
            }
            request("thread/loaded/list", params: ["limit": 200, "cursor": cursor], tag: "loaded:" + cursor)
        } else {
            let unique = Array(Set(loadingPages)).sorted()
            for id in Set(loaded).subtracting(unique) {
                onEvent?(ObservedEvent(event: StatusEvent(namespace: root, threadID: id, kind: .disconnected, evidence: .live), isInitial: false))
            }
            loaded = unique
            pollQueue = loaded; pumpPolls()
        }
    }
    private func request(_ method: String, params: [String: Any], tag: String) {
        guard !requests.values.contains(tag) else { return }
        nextID += 1; requests[nextID] = tag
        send(["id": nextID, "method": method, "params": params])
    }
    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        do { try input?.write(contentsOf: data + Data([10])) } catch { disconnect(report: true) }
    }
    private func receive(_ data: Data, from sender: Process) {
        guard process === sender, !data.isEmpty else { return }
        buffer.append(data)
        if buffer.count > 8 * 1024 * 1024 { disconnect(report: true); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            lastResponseAt = Date()
            if let id = d["id"] as? Int, d["method"] == nil {
                if id == 1 {
                    guard d["result"] != nil else { disconnect(report: true); return }
                    connected = true; onConnection?(true, "已连接现有 App Server；仅代表该服务中的任务")
                    send(["method": "initialized", "params": [:]])
                    loadingPages = []; pageCursors = []
                    request("thread/loaded/list", params: ["limit": 200], tag: "loaded")
                } else if let tag = requests.removeValue(forKey: id) {
                    if d["error"] != nil { onConnection?(true, "服务已连接，但部分只读接口不兼容；请检查版本"); continue }
                    let result = d["result"] as? [String: Any] ?? [:]
                    if tag.hasPrefix("loaded") { loadedPage(result) }
                    else if tag.hasPrefix("turn:"), let turn = (result["data"] as? [[String: Any]])?.first {
                        turnSnapshot(turn, threadID: String(tag.dropFirst(5)))
                    }
                    else if let thread = result["thread"] as? [String: Any] { snapshot(thread, threadID: tag) }
                    pumpPolls()
                }
            } else {
                for event in EventParser.parse(line, namespace: root, threadID: nil) { onEvent?(ObservedEvent(event: event, isInitial: false)) }
            }
        }
    }
    private func turnSnapshot(_ turn: [String: Any], threadID: String) {
        guard let id = turn["id"] as? String else { return }
        let initial = turnBaselines.insert(threadID).inserted
        // Actual start time distinguishes a newly observed turn from an old delayed start.
        let started = EventParser.date(turn["startedAt"]) ?? Date()
        onEvent?(ObservedEvent(event: StatusEvent(namespace: root, threadID: threadID, turnID: id, timestamp: started, kind: .started, evidence: .live), isInitial: initial))
        if let terminal = EventParser.terminal(turn["status"] as? String) {
            onEvent?(ObservedEvent(event: StatusEvent(namespace: root, threadID: threadID, turnID: id, kind: .ended(terminal), evidence: .live), isInitial: initial))
        }
    }
    func snapshot(_ thread: [String: Any], threadID: String) {
        let source: String
        if let text = thread["source"] as? String { source = text }
        else if let value = thread["source"], JSONSerialization.isValidJSONObject(value),
                let data = try? JSONSerialization.data(withJSONObject: value) { source = String(decoding: data, as: UTF8.self) }
        else { source = "" }
        let origin = ClientOrigin.detect(source: source, originator: thread["originator"] as? String ?? "")
        let subagent = (thread["source"] as? [String: Any])?["subagent"] as? [String: Any]
        let spawn = subagent?["thread_spawn"] as? [String: Any]
        var session = Session(namespace: root, threadID: threadID, title: thread["name"] as? String ?? thread["preview"] as? String ?? "Codex 任务",
                              cwd: thread["cwd"] as? String ?? "", origin: origin,
                              version: thread["cliVersion"] as? String ?? "", parentID: thread["parentThreadId"] as? String ?? spawn?["parent_thread_id"] as? String,
                              rolloutPath: thread["path"] as? String ?? "")
        session.classificationKnown = origin != .unknown || session.parentID != nil
        onMetadata?(session)
        guard let status = thread["status"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: ["method": "thread/status/changed", "params": ["threadId": threadID, "status": status]]) else { return }
        let initial = baselines.insert(threadID).inserted
        for event in EventParser.parse(data, namespace: root, threadID: threadID) { onEvent?(ObservedEvent(event: event, isInitial: initial)) }
    }
    private func disconnect(report: Bool) {
        let wasConnected = connected
        output?.readabilityHandler = nil; errors?.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        try? input?.close(); try? output?.close(); try? errors?.close()
        process = nil; input = nil; output = nil; errors = nil; connected = false
        if report {
            onConnection?(false, "实时连接不可用；保留本地记录，不推断任务结果")
        }
        if wasConnected {
            for id in Set(loaded).union(baselines) { onEvent?(ObservedEvent(event: StatusEvent(namespace: root, threadID: id, kind: .disconnected, evidence: .live), isInitial: !report)) }
        }
        loaded = []; pollQueue = []; retryAt = Date().addingTimeInterval(10)
    }
}

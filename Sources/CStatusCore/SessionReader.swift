import Foundation
import CSQLite

public struct ScanResult {
    public var sessions: [Session] = []
    public var events: [StatusEvent] = []
    public var errors: [String] = []
    public init() {}
}

private final class ReadDatabase {
    var db: OpaquePointer?
    init(_ url: URL) throws {
        let code = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK else {
            let error = db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            sqlite3_close(db); db = nil
            throw NSError(domain: "cStatus.SQLite", code: Int(code), userInfo: [NSLocalizedDescriptionKey: error])
        }
        sqlite3_busy_timeout(db, 100)
    }
    deinit { sqlite3_close(db) }
    func rows(_ sql: String, bind: String? = nil) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "cStatus.SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        defer { sqlite3_finalize(statement) }
        if let bind { _ = bind.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } }
        var output: [[String: String]] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                if let bytes = sqlite3_column_text(statement, index) {
                    row[String(cString: sqlite3_column_name(statement, index))] = String(cString: bytes)
                }
            }
            output.append(row); result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw NSError(domain: "cStatus.SQLite", code: Int(result), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        return output
    }
}

public enum SessionReader {
    public static func scan(root: URL) -> ScanResult {
        var result = ScanResult()
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            let indexes = contents.filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            guard let index = indexes.first else {
                result.errors.append("\(root.lastPathComponent)：未发现 Codex 会话索引（state_*.sqlite）")
                return result
            }
            let db = try ReadDatabase(index)
            let columns = Set(try db.rows("PRAGMA table_info(threads)").compactMap { $0["name"] })
            guard columns.contains("id"), columns.contains("updated_at") else {
                result.errors.append("不支持的会话数据库结构：\(index.lastPathComponent)"); return result
            }
            let optional = ["title", "name", "cwd", "source", "originator", "rollout_path", "cli_version", "archived"]
            let fields = ["id", "updated_at"] + optional.filter { columns.contains($0) }
            var conditions: [String] = []
            if columns.contains("archived") { conditions.append("archived = 0") }
            if columns.contains("source") { conditions.append("(source IS NULL OR source NOT LIKE '%subagent%')") }
            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            var rows = try db.rows("SELECT \(fields.joined(separator: ",")) FROM threads \(whereClause) ORDER BY updated_at DESC LIMIT 300")
            let historyURL = contents.filter { $0.lastPathComponent.hasPrefix("thread_history_") && $0.pathExtension == "sqlite" }
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }.first
            var history: ReadDatabase?
            do {
                history = try historyURL.map { try ReadDatabase($0) }
                if let history {
                    // Include unresolved latest turns even if child activity pushed them outside the recent window.
                    let unresolved = try history.rows("SELECT DISTINCT thread_id FROM thread_turns t WHERE status='inProgress' AND NOT EXISTS (SELECT 1 FROM thread_turns n WHERE n.thread_id=t.thread_id AND n.rollout_ordinal>t.rollout_ordinal)")
                    var ids = Set(rows.compactMap { $0["id"] })
                    for row in unresolved {
                        if let id = row["thread_id"], ids.insert(id).inserted {
                            rows += try db.rows("SELECT \(fields.joined(separator: ",")) FROM threads WHERE id = ?" + (conditions.isEmpty ? "" : " AND " + conditions.joined(separator: " AND ")), bind: id)
                        }
                    }
                }
            } catch {
                result.errors.append("历史投影不可用，继续读取会话索引与日志：\(error.localizedDescription)")
                history = nil
            }
            for row in rows {
                guard let id = row["id"] else { continue }
                let source = row["source"] ?? ""
                var parent: String?
                if let bytes = source.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                   let sub = object["subagent"] as? [String: Any], let spawn = sub["thread_spawn"] as? [String: Any] {
                    parent = spawn["parent_thread_id"] as? String
                }
                let updated = EventParser.date(Double(row["updated_at"] ?? "0")) ?? .distantPast
                let title = row["name"].flatMap { $0.isEmpty ? nil : $0 } ?? row["title"] ?? "Codex 任务"
                let session = Session(namespace: root.standardizedFileURL.path, threadID: id, title: title, cwd: row["cwd"] ?? "",
                                      origin: ClientOrigin.detect(source: source, originator: row["originator"] ?? ""),
                                      version: row["cli_version"] ?? "", parentID: parent,
                                      rolloutPath: row["rollout_path"] ?? "", updatedAt: updated)
                result.sessions.append(session)
                let historyTurn: [String: String]?
                do {
                    historyTurn = try history?.rows("SELECT turn_id,status,started_at,completed_at FROM thread_turns WHERE thread_id = ? ORDER BY rollout_ordinal DESC LIMIT 1", bind: id).first
                } catch {
                    result.errors.append("历史回合结构不兼容，继续读取日志：\(error.localizedDescription)")
                    history = nil; historyTurn = nil
                }
                if let turn = historyTurn {
                    let started = EventParser.date(Double(turn["started_at"] ?? "0")) ?? updated
                    let ended = EventParser.date(Double(turn["completed_at"] ?? "0")) ?? updated
                    result.events.append(StatusEvent(namespace: session.namespace, threadID: id, turnID: turn["turn_id"], timestamp: started, kind: .started, evidence: .history))
                    if let terminal = EventParser.terminal(turn["status"]) {
                        result.events.append(StatusEvent(namespace: session.namespace, threadID: id, turnID: turn["turn_id"], timestamp: ended, kind: .ended(terminal), evidence: .history))
                    }
                }
            }
        } catch { result.errors.append("读取 \(root.lastPathComponent) 失败：\(error.localizedDescription)") }
        return result
    }
}

public struct ObservedEvent: Sendable {
    public var event: StatusEvent
    public var isInitial: Bool
    public init(event: StatusEvent, isInitial: Bool) { self.event = event; self.isInitial = isInitial }
}
public struct MonitorBatch: Sendable {
    public var sessions: [Session] = []
    public var events: [ObservedEvent] = []
    public var errors: [String] = []
}

public actor MonitorWorker {
    private var tails: [String: LineTail] = [:]
    private var known: Set<String> = []
    private var hookFiles: Set<String> = []
    private var initializedHooks = false
    private var historyFingerprints: [String: String] = [:]
    private var observations = StateEngine()
    private var lastWriterProbe = Date.distantPast
    private let writerProbe: @Sendable (Set<String>) -> Set<String>
    public init(writerProbe: @escaping @Sendable (Set<String>) -> Set<String> = { RuntimeWriterProbe.paths($0) }) { self.writerProbe = writerProbe }

    public func poll(roots: [URL], hookDirectory: URL) -> MonitorBatch {
        var batch = MonitorBatch()
        for root in roots {
            let scan = SessionReader.scan(root: root)
            scan.sessions.forEach { observations.discover($0) }
            let newPaths = Set(scan.sessions.filter { $0.isMainTask && !known.contains($0.id) }.map(\.rolloutPath).filter { !$0.isEmpty })
            let bootstrapWriters = newPaths.isEmpty ? [] : writerProbe(newPaths)
            batch.sessions += scan.sessions; batch.errors += scan.errors
            for e in scan.events {
                let key = e.sessionID + ":" + String(describing: e.kind)
                let fingerprint = (e.turnID ?? "") + ":" + String(e.timestamp.timeIntervalSince1970)
                if historyFingerprints[key] != fingerprint {
                    batch.events.append(ObservedEvent(event: e, isInitial: !known.contains(e.sessionID)))
                    historyFingerprints[key] = fingerprint
                }
            }
            for session in scan.sessions {
                let recent = Date().timeIntervalSince(session.updatedAt) < 86400
                if !session.rolloutPath.isEmpty && (recent || tails[session.id] != nil || bootstrapWriters.contains(session.rolloutPath) || observations.sessions[session.id]?.writerActive == true) {
                    do {
                        var reader = tails[session.id] ?? LineTail()
                        let tail = try reader.read(url: URL(fileURLWithPath: session.rolloutPath))
                        tails[session.id] = reader
                        let tailEvents = tail.lines.flatMap { EventParser.parse($0, namespace: session.namespace, threadID: session.threadID) }
                        let baseline = batch.events.map(\.event).filter { $0.sessionID == session.id }.max { $0.timestamp < $1.timestamp }?.turnID ?? observations.sessions[session.id]?.turnID
                        if let boundary = tail.historyBoundary,
                           let event = try LifecycleRecovery.missingLifecycle(tailEvents: tailEvents, baselineTurnID: baseline, url: URL(fileURLWithPath: session.rolloutPath), before: boundary, suffix: tail.historySuffix, namespace: session.namespace, threadID: session.threadID) {
                            batch.events.append(ObservedEvent(event: event, isInitial: true))
                        }
                        batch.events += tailEvents.map { ObservedEvent(event: $0, isInitial: tail.isInitial) }
                    } catch {
                        if known.contains(session.id) { batch.errors.append("会话记录不可读：\(session.threadID.prefix(8))") }
                    }
                }
                known.insert(session.id)
            }
        }
        if let files = try? FileManager.default.contentsOfDirectory(at: hookDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let json = files.filter { $0.pathExtension == "json" }
            for file in json where !hookFiles.contains(file.lastPathComponent) {
                if let data = try? Data(contentsOf: file) {
                    batch.events += EventParser.parse(data, namespace: roots.first?.path ?? "", threadID: nil)
                        .map { ObservedEvent(event: $0, isInitial: !initializedHooks) }
                }
            }
            hookFiles = Set(json.map(\.lastPathComponent))
        }
        initializedHooks = true
        batch.events.sort { $0.event.timestamp < $1.event.timestamp }
        batch.events.forEach { observations.apply($0.event) }
        if Date().timeIntervalSince(lastWriterProbe) >= 3 {
            let open = observations.sessions.values.filter { $0.isMainTask && $0.recordedTaskOpen && !$0.rolloutPath.isEmpty }
            let writers = writerProbe(Set(open.map(\.rolloutPath)))
            for session in open {
                let event = StatusEvent(namespace: session.namespace, threadID: session.threadID, turnID: session.turnID,
                                        kind: .writerObserved(writers.contains(session.rolloutPath)), evidence: .process)
                observations.apply(event)
                batch.events.append(ObservedEvent(event: event, isInitial: true))
            }
            lastWriterProbe = Date()
        }
        return batch
    }
}

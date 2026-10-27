import XCTest
import CSQLite
@testable import CStatusCore

final class ReaderTests: XCTestCase {
    func directory() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }
    func database(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }
    func testPartialLineIsNotConsumedUntilCompleted() throws {
        let url = try directory().appendingPathComponent("rollout.jsonl")
        try Data("{\"first\":1}\n{\"second\":".utf8).write(to: url)
        var tail = LineTail()
        XCTAssertEqual(try tail.read(url: url).lines.map { String(decoding: $0, as: UTF8.self) }, ["{\"first\":1}"])
        let h = try FileHandle(forWritingTo: url); try h.seekToEnd(); try h.write(contentsOf: Data("2}\n".utf8)); try h.close()
        XCTAssertEqual(try tail.read(url: url).lines.map { String(decoding: $0, as: UTF8.self) }, ["{\"second\":2}"])
    }
    func testRotationResetsCursorAndIsBaseline() throws {
        let url = try directory().appendingPathComponent("rollout.jsonl")
        try Data("old\n".utf8).write(to: url)
        var tail = LineTail(); _ = try tail.read(url: url)
        try FileManager.default.removeItem(at: url)
        try Data("new\n".utf8).write(to: url)
        let result = try tail.read(url: url)
        XCTAssertTrue(result.isInitial)
        XCTAssertEqual(result.lines.map { String(decoding: $0, as: UTF8.self) }, ["new"])
    }
    func testSchemaAwareDiscoveryReadsPaginatedTerminalStateWithoutWriting() throws {
        let root = try directory()
        try database(root.appendingPathComponent("state_5.sqlite"), """
        CREATE TABLE threads(id TEXT, title TEXT, cwd TEXT, source TEXT, originator TEXT, rollout_path TEXT, updated_at INTEGER, archived INTEGER, cli_version TEXT);
        INSERT INTO threads VALUES('t','A task','/project','vscode','codex_vscode','',1780000000,0,'0.162');
        """)
        try database(root.appendingPathComponent("thread_history_1.sqlite"), """
        CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,started_at INTEGER,completed_at INTEGER,rollout_ordinal INTEGER);
        INSERT INTO thread_turns VALUES('t','old','completed',1000,1200,1);
        INSERT INTO thread_turns VALUES('t','new','interrupted',2000,2300,2);
        """)
        let before = try Data(contentsOf: root.appendingPathComponent("state_5.sqlite"))
        let result = SessionReader.scan(root: root)
        XCTAssertTrue(result.errors.isEmpty, result.errors.joined())
        XCTAssertEqual(result.sessions.first?.origin, .vscode)
        XCTAssertEqual(result.events.last?.kind, .ended(.interrupted))
        XCTAssertEqual(result.events.last?.turnID, "new")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("state_5.sqlite")), before)
    }
    func testUnknownOriginIsNotMislabelledAsDesktop() {
        XCTAssertEqual(ClientOrigin.detect(source: "other", originator: "new-client"), .unknown)
        XCTAssertEqual(ClientOrigin.detect(source: "app-server", originator: "codex_desktop"), .desktop)
    }
    func testMissingRootReturnsDiagnostic() throws {
        let missing = try directory().appendingPathComponent("missing")
        XCTAssertFalse(SessionReader.scan(root: missing).errors.isEmpty)
    }

    func testMonitorDoesNotReemitUnchangedHistoryOnEveryPoll() async throws {
        let root = try directory()
        try database(root.appendingPathComponent("state_5.sqlite"), """
        CREATE TABLE threads(id TEXT, updated_at INTEGER);
        INSERT INTO threads VALUES('t',2000);
        """)
        try database(root.appendingPathComponent("thread_history_1.sqlite"), """
        CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,started_at INTEGER,completed_at INTEGER,rollout_ordinal INTEGER);
        INSERT INTO thread_turns VALUES('t','a','inProgress',2000,NULL,1);
        """)
        let worker = MonitorWorker()
        let first = await worker.poll(roots: [root], hookDirectory: root.appendingPathComponent("events"))
        let second = await worker.poll(roots: [root], hookDirectory: root.appendingPathComponent("events"))
        XCTAssertEqual(first.events.count, 1)
        XCTAssertEqual(first.events.first?.isInitial, true)
        XCTAssertTrue(second.events.isEmpty)
    }

    func testIncompatibleHistoryDoesNotPreventSessionDiscovery() throws {
        let root = try directory()
        try database(root.appendingPathComponent("state_5.sqlite"), """
        CREATE TABLE threads(id TEXT, updated_at INTEGER);
        INSERT INTO threads VALUES('a',2000),('b',2001),('c',2002);
        """)
        try database(root.appendingPathComponent("thread_history_1.sqlite"), "CREATE TABLE unsupported(id TEXT);")
        let result = SessionReader.scan(root: root)
        XCTAssertEqual(result.sessions.count, 3)
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testActiveThreadOutsideRecentLimitIsStillDiscovered() throws {
        let root = try directory()
        try database(root.appendingPathComponent("state_5.sqlite"), """
        CREATE TABLE threads(id TEXT, updated_at INTEGER);
        WITH RECURSIVE x(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM x WHERE i<301)
        INSERT INTO threads SELECT 't'||i, i FROM x;
        """)
        try database(root.appendingPathComponent("thread_history_1.sqlite"), """
        CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,started_at INTEGER,completed_at INTEGER,rollout_ordinal INTEGER);
        INSERT INTO thread_turns VALUES('t1','a','inProgress',1000,NULL,1);
        """)
        XCTAssertTrue(SessionReader.scan(root: root).sessions.contains { $0.threadID == "t1" })
    }

    func testLongLegacyTurnStartOutsideTailIsRestoredForBothTasks() async throws {
        let root = try directory()
        for id in ["main-a", "main-b"] {
            let url = root.appendingPathComponent(id + ".jsonl")
            let start = #"{"type":"event_msg","timestamp":"2026-10-15T01:00:00Z","payload":{"type":"task_started","turn_id":"turn-"# + id + #""}}"#
            var bytes = Data((start + "\n").utf8)
            let filler = Data((#"{"type":"response_item","payload":{"type":"message","content":""# + String(repeating: "x", count: 4096) + #""}}"# + "\n").utf8)
            for _ in 0..<800 { bytes.append(filler) }
            try bytes.write(to: url)
        }
        try database(root.appendingPathComponent("state_5.sqlite"), """
        CREATE TABLE threads(id TEXT,updated_at INTEGER,source TEXT,rollout_path TEXT);
        INSERT INTO threads VALUES('main-a',1792026000,'vscode','\(root.path)/main-a.jsonl'),('main-b',1792026000,'vscode','\(root.path)/main-b.jsonl');
        """)
        let batch = await MonitorWorker(writerProbe: { $0 }).poll(roots: [root], hookDirectory: root.appendingPathComponent("events"))
        var engine = StateEngine(); batch.sessions.forEach { engine.discover($0) }
        batch.events.forEach { engine.apply($0.event) }
        XCTAssertEqual(engine.sessions.values.filter { $0.status == .running }.count, 2)
        XCTAssertTrue(batch.events.allSatisfy(\.isInitial))
    }

    func testOlderTaskIsRecoveredAfterInitiallyMissingDatabase() async throws {
        let root = try directory()
        let worker = MonitorWorker(writerProbe: { $0 })
        _ = await worker.poll(roots: [root], hookDirectory: root)
        let path = root.appendingPathComponent("old.jsonl")
        try Data((#"{"type":"event_msg","timestamp":"2020-01-01T01:00:00Z","payload":{"type":"task_started","turn_id":"a"}}"# + "\n").utf8).write(to: path)
        try database(root.appendingPathComponent("state_5.sqlite"), """
        CREATE TABLE threads(id TEXT,updated_at INTEGER,source TEXT,rollout_path TEXT);
        INSERT INTO threads VALUES('old',10,'vscode','\(path.path)');
        """)
        let batch = await worker.poll(roots: [root], hookDirectory: root)
        XCTAssertTrue(batch.events.contains { $0.event.kind == .started })
    }

    func testGuardianWithoutParentIDIsNotReturnedAsMainTask() throws {
        let root = try directory()
        try database(root.appendingPathComponent("state_5.sqlite"), """
        CREATE TABLE threads(id TEXT,updated_at INTEGER,source TEXT);
        INSERT INTO threads VALUES('main',10,'vscode'),('guardian',11,'{"subagent":{"other":"guardian"}}');
        """)
        XCTAssertEqual(SessionReader.scan(root: root).sessions.map(\.threadID), ["main"])
    }

    func testTailTerminalWithLaggingHistoryRecoversNewTurnStart() async throws {
        let root = try directory(); let path = root.appendingPathComponent("new.jsonl")
        let start = #"{"type":"event_msg","timestamp":"2026-10-15T01:00:00Z","payload":{"type":"task_started","turn_id":"b"}}"#
        let end = #"{"type":"event_msg","timestamp":"2026-10-15T02:00:00Z","payload":{"type":"task_complete","turn_id":"b"}}"#
        var bytes = Data((start + "\n").utf8)
        for _ in 0..<800 { bytes.append(Data((String(repeating: "x", count: 4096) + "\n").utf8)) }
        bytes.append(Data((end + "\n").utf8)); try bytes.write(to: path)
        try database(root.appendingPathComponent("state_5.sqlite"), """
        CREATE TABLE threads(id TEXT,updated_at INTEGER,source TEXT,rollout_path TEXT);
        INSERT INTO threads VALUES('t',1792026000,'vscode','\(path.path)');
        """)
        try database(root.appendingPathComponent("thread_history_1.sqlite"), """
        CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,started_at INTEGER,completed_at INTEGER,rollout_ordinal INTEGER);
        INSERT INTO thread_turns VALUES('t','a','inProgress',1000,NULL,1);
        """)
        let batch = await MonitorWorker(writerProbe: { $0 }).poll(roots: [root], hookDirectory: root)
        var engine = StateEngine(); batch.sessions.forEach { engine.discover($0) }
        batch.events.forEach { engine.apply($0.event) }
        XCTAssertEqual(engine.sessions[root.path + "::t"]?.status, .completed)
        XCTAssertEqual(engine.sessions[root.path + "::t"]?.turnID, "b")
    }

    func testTerminalInTailPreventsAnyPrefixRead() throws {
        let terminal = StatusEvent(namespace: "/codex", threadID: "t", kind: .ended(.completed), evidence: .transcript)
        // An inaccessible multi-GB prefix must never be opened when the tail is decisive.
        let result = try LifecycleRecovery.missingLifecycle(tailEvents: [terminal], url: URL(fileURLWithPath: "/does-not-exist"), before: 5_000_000_000, suffix: Data(), namespace: "/codex", threadID: "t")
        XCTAssertNil(result)
    }

    func testLifecycleAcrossTailBoundaryIsRecovered() throws {
        let url = try directory().appendingPathComponent("rollout.jsonl")
        let line = #"{"type":"event_msg","timestamp":"2026-10-15T01:00:00Z","payload":{"type":"task_started","turn_id":"a"}}"#
        let bytes = Data(line.utf8); try bytes.write(to: url)
        let split = bytes.count / 2
        let result = try LifecycleRecovery.latest(url: url, before: UInt64(split), suffix: Data(bytes.dropFirst(split)), namespace: "/codex", threadID: "t")
        XCTAssertEqual(result?.kind, .started)
    }
}

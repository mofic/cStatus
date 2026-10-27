import XCTest
@testable import CStatus
import CStatusCore

final class LiveMonitorTests: XCTestCase {
    @MainActor func testStructuredLiveChildrenAndUnknownSourcesCannotBecomeMainTasks() {
        let monitor = LiveMonitor()
        var sessions: [Session] = []
        monitor.onMetadata = { sessions.append($0) }
        monitor.snapshot(["source": ["subagent": ["other": "guardian"]]], threadID: "guardian")
        monitor.snapshot(["source": ["subagent": ["thread_spawn": ["parent_thread_id": "root"]]]], threadID: "child")
        monitor.snapshot(["source": ["unrecognized": "value"]], threadID: "unknown")
        monitor.snapshot(["source": "vscode"], threadID: "main")
        XCTAssertEqual(sessions.filter(\.isMainTask).map(\.threadID), ["main"])
        XCTAssertEqual(sessions[1].parentID, "root")
    }

    @MainActor func testAllPagesAreObservedAndUnloadedThreadsLoseCoverage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("fake-codex")
        let socket = root.appendingPathComponent("socket")
        try Data().write(to: socket)
        let script = #"""
        #!/usr/bin/python3
        import json,sys
        from pathlib import Path
        trace=Path(__file__).with_suffix('.trace')
        trace.write_text('started\n')
        scans=0
        for line in sys.stdin:
            d=json.loads(line); method=d.get('method'); p=d.get('params',{})
            with trace.open('a') as f: f.write(str(method)+'\n')
            if 'id' not in d: continue
            result={}
            if method=='thread/loaded/list':
                if not p.get('cursor'): scans+=1
                if scans>1: result={'data':[]}
                elif p.get('cursor')=='page2': result={'data':['t'+str(i) for i in range(100,150)]}
                else: result={'data':['t'+str(i) for i in range(100)],'nextCursor':'page2'}
            elif method=='thread/read':
                result={'thread':{'id':p['threadId'],'source':'cli','status':{'type':'active','activeFlags':[]}}}
            elif method=='thread/turns/list': result={'data':[]}
            print(json.dumps({'id':d['id'],'result':result}),flush=True)
        """#
        try Data(script.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let all = expectation(description: "all 150 paginated loaded threads observed")
        let unloaded = expectation(description: "unloaded threads lose coverage")
        var observed: Set<String> = []; var lost: Set<String> = []
        var messages: [String] = []
        let monitor = LiveMonitor()
        defer { monitor.stop() }
        monitor.onConnection = { _, message in messages.append(message) }
        monitor.onEvent = { result in
            if case .runtime = result.event.kind {
                if observed.insert(result.event.threadID).inserted && observed.count == 150 { all.fulfill() }
            }
            if case .disconnected = result.event.kind {
                if lost.insert(result.event.threadID).inserted && lost.count == 150 { unloaded.fulfill() }
            }
        }
        monitor.start(root: root.path, executable: cli.path, socket: socket.path)
        await fulfillment(of: [all, unloaded], timeout: 8)
        let trace = (try? String(contentsOf: root.appendingPathComponent("fake-codex.trace"))) ?? "no child trace"
        XCTAssertEqual(observed.count, 150, messages.joined(separator: "; ") + " trace: " + trace)
        XCTAssertEqual(lost.count, 150)
    }
}

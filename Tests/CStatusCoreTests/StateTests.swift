import XCTest
@testable import CStatusCore

final class StateTests: XCTestCase {
    func event(_ kind: EventKind, turn: String = "a", time: Double = 10) -> StatusEvent {
        StatusEvent(namespace: "/codex", threadID: "thread", turnID: turn,
                    timestamp: Date(timeIntervalSince1970: time), kind: kind, evidence: .live)
    }

    func testTerminalStatesAreDistinct() {
        for state in [TaskStatus.completed, .interrupted, .failed] {
            var engine = StateEngine()
            engine.apply(event(.started))
            engine.apply(event(.ended(state), time: 12))
            XCTAssertEqual(engine.sessions.values.first?.status, state)
        }
    }

    func testOldTurnCannotReplaceNewTurn() {
        var engine = StateEngine()
        engine.apply(event(.started))
        engine.apply(event(.started, turn: "b", time: 20))
        engine.apply(event(.ended(.completed), time: 30))
        XCTAssertEqual(engine.sessions.values.first?.status, .running)
        XCTAssertEqual(engine.sessions.values.first?.turnID, "b")
    }

    func testConcurrentRequestsRemainUntilEachIsResolved() {
        var engine = StateEngine()
        engine.apply(event(.started))
        engine.apply(event(.requested("q1", .input), time: 11))
        engine.apply(event(.requested("q2", .input), time: 12))
        engine.apply(event(.requested("p1", .approval), time: 13))
        engine.apply(event(.resolved("q1"), time: 14))
        XCTAssertEqual(engine.sessions.values.first?.requests.count, 2)
        engine.apply(event(.resolved("p1"), time: 15))
        XCTAssertEqual(engine.sessions.values.first?.status, .waitingInput)
        engine.apply(event(.resolved("q2"), time: 16))
        XCTAssertEqual(engine.sessions.values.first?.status, .running)
    }

    func testRetryErrorDoesNotEndTurn() throws {
        let data = Data(#"{"method":"error","params":{"threadId":"t","turnId":"a","willRetry":true,"error":{"message":"retry"}}}"#.utf8)
        let events = EventParser.parse(data, namespace: "/codex", threadID: nil)
        XCTAssertFalse(events.contains { if case .ended = $0.kind { return true }; return false })
    }

    func testRuntimeFlagsRecognizeUserInput() {
        let data = Data(#"{"method":"thread/status/changed","params":{"threadId":"t","status":{"type":"active","activeFlags":["waitingOnUserInput","waitingOnApproval"]}}}"#.utf8)
        let events = EventParser.parse(data, namespace: "/codex", threadID: nil)
        var engine = StateEngine()
        events.forEach { engine.apply($0) }
        XCTAssertEqual(engine.sessions.values.first?.status, .waitingInput)
    }

    func testInitialAndDuplicateRemindersAreSuppressed() {
        var gate = ReminderGate()
        let e = event(.requested("q1", .input))
        XCTAssertFalse(gate.accept(e, isInitial: true))
        XCTAssertFalse(gate.accept(e, isInitial: false))
        XCTAssertTrue(gate.accept(event(.requested("q2", .input), time: 12), isInitial: false))
        XCTAssertFalse(gate.accept(event(.requested("q2", .input), time: 13), isInitial: false))
    }

    func testAsyncAcknowledgementDoesNotResolveQuestion() {
        let data = Data(#"{"type":"response_item","timestamp":"2026-10-15T00:00:00Z","payload":{"type":"function_call_output","call_id":"q","output":"{\"request_id\":\"q\",\"status\":\"pending\"}"}}"#.utf8)
        let events = EventParser.parse(data, namespace: "/codex", threadID: "t")
        XCTAssertFalse(events.contains { if case .resolved = $0.kind { return true }; return false })
    }

    func testAuthoritativeRuntimeClearsRequestsAfterMissedResolution() {
        var engine = StateEngine()
        engine.apply(event(.started))
        engine.apply(event(.requested("q", .input), time: 11))
        engine.apply(event(.runtime(.running, []), time: 12))
        XCTAssertEqual(engine.sessions.values.first?.status, .running)
        XCTAssertTrue(engine.sessions.values.first?.requests.isEmpty == true)
    }

    func testLateHistoryConfirmsCompletionAfterRuntimeBecomesIdle() {
        var engine = StateEngine()
        engine.apply(event(.started))
        engine.apply(event(.runtime(.idle, []), time: 20))
        var terminal = event(.ended(.completed), time: 19); terminal.evidence = .history
        engine.apply(terminal)
        XCTAssertEqual(engine.sessions.values.first?.status, .completed)
    }

    func testHistoryCannotEndNewerLiveActivity() {
        var engine = StateEngine()
        engine.apply(event(.started))
        engine.apply(event(.runtime(.running, []), time: 20))
        var terminal = event(.ended(.completed), time: 19); terminal.evidence = .history
        engine.apply(terminal)
        XCTAssertEqual(engine.sessions.values.first?.status, .running)
    }

    func testNonLoadedThreadDoesNotClaimLiveCoverage() {
        var engine = StateEngine()
        engine.apply(event(.runtime(.unknown, [])))
        XCTAssertEqual(engine.sessions.values.first?.liveConnected, false)
    }

    func testHistoricalRunningIsUnknownUntilNewEvidence() {
        var engine = StateEngine()
        var start = event(.started); start.evidence = .history
        engine.apply(start)
        engine.markHistoricalUnconfirmed(Set(engine.sessions.keys))
        XCTAssertEqual(engine.sessions.values.first?.status, .unknown)
        engine.apply(event(.runtime(.running, []), time: 11))
        XCTAssertEqual(engine.sessions.values.first?.status, .running)
    }

    func testNewTurnStartObservedAfterRuntimeSnapshotIsAccepted() {
        var engine = StateEngine()
        engine.apply(event(.started))
        engine.apply(event(.runtime(.running, []), time: 30))
        engine.apply(event(.started, turn: "b", time: 20))
        XCTAssertEqual(engine.sessions.values.first?.turnID, "b")
    }

    func testRetiredTurnCannotBeReopenedByDelayedStartNotification() {
        var engine = StateEngine()
        engine.apply(event(.started))
        engine.apply(event(.started, turn: "b", time: 20))
        engine.apply(event(.requested("b-question", .input), turn: "b", time: 21))
        engine.apply(event(.started, time: 30))
        XCTAssertEqual(engine.sessions.values.first?.turnID, "b")
        XCTAssertEqual(engine.sessions.values.first?.status, .waitingInput)
    }

    func testInitialPendingAndHookActivityCannotClaimCurrentState() {
        for kind in [EventKind.requested("q", .input), .requested("p", .approval), .started] {
            var engine = StateEngine()
            var e = event(kind); e.evidence = .hook
            engine.apply(e)
            engine.markHistoricalUnconfirmed(Set(engine.sessions.keys))
            XCTAssertEqual(engine.sessions.values.first?.status, .unknown)
        }
    }

    func testConnectionLossAndRemovedRootClearLiveClaims() {
        var engine = StateEngine()
        engine.apply(event(.started))
        engine.reconcileRoots(["/codex"])
        XCTAssertEqual(engine.sessions.values.first?.liveConnected, false)
        XCTAssertEqual(engine.sessions.values.first?.status, .disconnected)
        engine.reconcileRoots(["/other"])
        XCTAssertTrue(engine.sessions.isEmpty)
    }

    func testProtocolStartUsesAuthoritativeStartTime() {
        let data = Data(#"{"method":"turn/started","params":{"threadId":"t","turn":{"id":"a","startedAt":20}}}"#.utf8)
        XCTAssertEqual(EventParser.parse(data, namespace: "/codex", threadID: nil).first?.timestamp, Date(timeIntervalSince1970: 20))
    }

    func testFreshToolActivityConfirmsHistoricalUnknownTaskIsRunning() {
        var engine = StateEngine()
        var start = event(.started); start.evidence = .history
        engine.apply(start); engine.markHistoricalUnconfirmed(Set(engine.sessions.keys))
        var tool = event(.activity("执行命令"), time: 12); tool.evidence = .hook
        engine.apply(tool)
        XCTAssertEqual(engine.sessions.values.first?.status, .running)
        XCTAssertEqual(engine.sessions.values.first?.liveConnected, false)
    }

    func testLaterWaitingTransitionInSameTurnCanNotifyAgain() {
        var gate = ReminderGate()
        XCTAssertTrue(gate.accept(event(.runtime(.running, [.input])), isInitial: false))
        XCTAssertFalse(gate.accept(event(.runtime(.running, [.input]), time: 11), isInitial: false))
        XCTAssertFalse(gate.accept(event(.runtime(.running, []), time: 12), isInitial: false))
        XCTAssertTrue(gate.accept(event(.runtime(.running, [.input]), time: 13), isInitial: false))
        var firstHook = event(.requested("hook:Bash", .approval), time: 20); firstHook.evidence = .hook
        var secondHook = firstHook; secondHook.timestamp = Date(timeIntervalSince1970: 22)
        XCTAssertTrue(gate.accept(firstHook, isInitial: false))
        XCTAssertFalse(gate.accept(firstHook, isInitial: false))
        XCTAssertTrue(gate.accept(secondHook, isInitial: false))
    }

    func testChildTurnCompletionCannotCompleteParentTurn() {
        let bytes = Data(#"{"type":"event_msg","timestamp":"2026-10-15T01:00:00Z","payload":{"type":"task_complete","turn_id":"child","root_turn_id":"parent"}}"#.utf8)
        XCTAssertTrue(EventParser.parse(bytes, namespace: "/codex", threadID: "t").isEmpty)
    }
}

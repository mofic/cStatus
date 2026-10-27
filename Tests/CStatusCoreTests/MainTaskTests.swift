import XCTest
@testable import CStatus
@testable import CStatusCore

final class MainTaskTests: XCTestCase {
    @MainActor func model() -> AppModel {
        let name = "cStatus.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return AppModel(defaults: defaults)
    }
    @MainActor func testOnlyMainTasksAppearAndCountRegardlessOfParentMetadata() {
        let model = model()
        var a = Session(namespace: "/codex", threadID: "main-a", origin: .vscode); a.status = .running
        var b = Session(namespace: "/codex", threadID: "main-b", origin: .cli); b.status = .running
        var review = Session(namespace: "/codex", threadID: "review", origin: .subagent); review.status = .waitingApproval
        var orphan = Session(namespace: "/codex", threadID: "orphan", origin: .subagent, parentID: "missing"); orphan.status = .running
        model.sessions = [a, b, review, orphan]
        XCTAssertEqual(model.activeCount, 2)
        XCTAssertEqual(model.attentionCount, 0)
        XCTAssertEqual(Set(model.visible.map(\.threadID)), ["main-a", "main-b"])
    }

    @MainActor func testActiveMainTaskIsNotHiddenByOldTimestampOrUserHide() {
        let model = model()
        var s = Session(namespace: "/codex", threadID: UUID().uuidString, origin: .vscode, updatedAt: Date().addingTimeInterval(-172800))
        s.status = .running; model.sessions = [s]
        XCTAssertEqual(model.visible.count, 1)
    }

    @MainActor func testChildAndUnclassifiedHooksNeverNotifyAndMenuCountsAllMainTasks() {
        let model = model(); model.roots = ["/codex"]
        var alerts: [String] = []; var count = 0
        model.onReminder = { alerts.append($0.threadID) }; model.onCount = { count = $0 }
        var batch = MonitorBatch()
        batch.sessions = [Session(namespace: "/codex", threadID: "a", origin: .vscode), Session(namespace: "/codex", threadID: "b", origin: .cli), Session(namespace: "/codex", threadID: "guardian", origin: .subagent)]
        let now = Date()
        for id in ["a", "b", "guardian"] {
            batch.events.append(ObservedEvent(event: StatusEvent(namespace: "/codex", threadID: id, turnID: "turn", timestamp: now, kind: .started, evidence: .live), isInitial: false))
        }
        batch.events.append(ObservedEvent(event: StatusEvent(namespace: "/codex", threadID: "a", turnID: "turn", timestamp: now.addingTimeInterval(1), kind: .requested("q", .input), evidence: .live), isInitial: false))
        batch.events.append(ObservedEvent(event: StatusEvent(namespace: "/codex", threadID: "guardian", turnID: "turn", timestamp: now.addingTimeInterval(1), kind: .ended(.completed), evidence: .live), isInitial: false))
        batch.events.append(ObservedEvent(event: StatusEvent(namespace: "/codex", threadID: "unknown-child", timestamp: now.addingTimeInterval(1), kind: .requested("p", .approval), evidence: .hook), isInitial: false))
        model.receive(batch)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(alerts, ["a"])
        XCTAssertEqual(model.sessions.count, 2)
    }
}

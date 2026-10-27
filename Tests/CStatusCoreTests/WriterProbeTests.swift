import XCTest
@testable import CStatusCore

final class WriterProbeTests: XCTestCase {
    func testOnlyCodexWritableHandlesConfirmTaskOwnership() {
        let text = "p1\nccodex\nf5\naw\nn/a\np2\nccStatus\nf8\naw\nn/b\np3\nccodex\nf9\nar\nn/c\np4\nccodex\nf10\nau\nn/d\n"
        XCTAssertEqual(RuntimeWriterProbe.parse(Data(text.utf8), requested: ["/a", "/b", "/c", "/d"]), ["/a", "/d"])
    }

    func testWriterCanConfirmOpenTurnButCannotReviveCompletedTurn() {
        var engine = StateEngine()
        let id = Session(namespace: "/codex", threadID: "t", origin: .vscode)
        engine.discover(id)
        engine.apply(StatusEvent(namespace: "/codex", threadID: "t", turnID: "a", timestamp: Date(timeIntervalSince1970: 10), kind: .started, evidence: .transcript))
        engine.markHistoricalUnconfirmed([id.id])
        engine.apply(StatusEvent(namespace: "/codex", threadID: "t", kind: .writerObserved(true), evidence: .process))
        XCTAssertEqual(engine.sessions[id.id]?.status, .running)
        engine.apply(StatusEvent(namespace: "/codex", threadID: "t", turnID: "a", timestamp: Date(timeIntervalSince1970: 11), kind: .ended(.completed), evidence: .transcript))
        engine.apply(StatusEvent(namespace: "/codex", threadID: "t", kind: .writerObserved(true), evidence: .process))
        XCTAssertEqual(engine.sessions[id.id]?.status, .completed)
        XCTAssertEqual(engine.sessions[id.id]?.writerActive, false)
    }
}

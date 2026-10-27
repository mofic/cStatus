import XCTest
@testable import CStatusCore

final class HookTests: XCTestCase {
    func testSanitizedHookCannotStorePromptOrToolArguments() throws {
        let raw: [String: Any] = ["session_id":"t", "turn_id":"a", "hook_event_name":"PostToolUse", "cwd":"/repo",
            "tool_name":"request_user_input", "tool_use_id":"q", "prompt":"private", "tool_input":["secret":"value"],
            "tool_response":["answers":["q":"private answer"]]]
        let result = try XCTUnwrap(HookBridge.sanitize(raw, codexHome: "/codex"))
        XCTAssertNil(result["prompt"]); XCTAssertNil(result["tool_input"]); XCTAssertNil(result["tool_response"])
        XCTAssertEqual(result["has_answers"] as? Bool, true)
        let bytes = try JSONSerialization.data(withJSONObject: result)
        XCTAssertTrue(EventParser.parse(bytes, namespace: "/codex", threadID: nil).contains { $0.kind == .resolved("q") })
    }
    func testConfigurationMergeAndRemovalPreserveUserHooks() throws {
        let existing: [String: Any] = ["description":"mine", "hooks":["Stop":[["hooks":[["type":"command","command":"my-script"]]]]]]
        let merged = try HookBridge.configuration(executable: "/a path/it's/cStatus", existing: existing)
        let again = try HookBridge.configuration(executable: "/a path/it's/cStatus", existing: merged)
        let hooks = try XCTUnwrap(again["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2)
        let removed = HookBridge.removingOwned(from: again)
        let removedHooks = try XCTUnwrap(removed["hooks"] as? [String: Any])
        XCTAssertEqual((removedHooks["Stop"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(removed["description"] as? String, "mine")
    }
    func testHookFilesAreAtomicAndContainOnlyMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = Data(#"{"session_id":"t","hook_event_name":"PermissionRequest","turn_id":"a","tool_name":"Bash","tool_input":{"command":"secret"}}"#.utf8)
        try HookBridge.record(input: input, directory: root, codexHome: "/codex")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let bytes = try Data(contentsOf: files[0])
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("secret"))
        XCTAssertEqual(EventParser.parse(bytes, namespace: "/codex", threadID: nil).first?.kind, .requested("hook:Bash", .approval))
    }

    func testSuccessfulToolClearsItsApprovalWithoutClearingOtherRequests() throws {
        let request = Data(#"{"cstatus_hook":true,"session_id":"t","turn_id":"a","hook_event_name":"PermissionRequest","tool_name":"Bash","timestamp":10}"#.utf8)
        let answer = Data(#"{"cstatus_hook":true,"session_id":"t","turn_id":"a","hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"call1","timestamp":12}"#.utf8)
        var engine = StateEngine()
        EventParser.parse(request, namespace: "/codex", threadID: nil).forEach { engine.apply($0) }
        engine.apply(StatusEvent(namespace: "/codex", threadID: "t", turnID: "a", timestamp: Date(timeIntervalSince1970: 11), kind: .requested("other", .input), evidence: .hook))
        EventParser.parse(answer, namespace: "/codex", threadID: nil).forEach { engine.apply($0) }
        XCTAssertEqual(engine.sessions.values.first?.requests.count, 1)
        XCTAssertEqual(engine.sessions.values.first?.status, .waitingInput)
    }

    func testAsyncHookAcknowledgementWithoutCallIDDoesNotResolveInput() {
        let request = Data(#"{"cstatus_hook":true,"session_id":"t","turn_id":"a","hook_event_name":"PreToolUse","tool_name":"request_user_input_async","timestamp":10}"#.utf8)
        let ack = Data(#"{"cstatus_hook":true,"session_id":"t","turn_id":"a","hook_event_name":"PostToolUse","tool_name":"request_user_input_async","has_answers":false,"timestamp":12}"#.utf8)
        var engine = StateEngine()
        for data in [request, ack] { EventParser.parse(data, namespace: "/codex", threadID: nil).forEach { engine.apply($0) } }
        XCTAssertEqual(engine.sessions.values.first?.status, .waitingInput)
    }
}

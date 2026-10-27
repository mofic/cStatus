import Foundation

public enum HookBridge {
    private static let marker = " --hook --bridge-id cstatus-v1"
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/cStatus/events")
    }
    public static func sanitize(_ raw: [String: Any], codexHome: String) -> [String: Any]? {
        guard let id = raw["session_id"] as? String, !id.isEmpty,
              let event = raw["hook_event_name"] as? String else { return nil }
        var output: [String: Any] = ["cstatus_hook": true, "session_id": id, "hook_event_name": event,
                                   "codex_home": codexHome, "timestamp": Date().timeIntervalSince1970]
        for key in ["turn_id", "cwd", "tool_name", "tool_use_id"] {
            if let value = raw[key] as? String { output[key] = String(value.prefix(4096)) }
        }
        if let response = raw["tool_response"] as? [String: Any] { output["has_answers"] = response["answers"] != nil }
        else if let text = raw["tool_response"] as? String, let data = text.data(using: .utf8),
                let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { output["has_answers"] = response["answers"] != nil }
        return output
    }
    public static func record(input: Data, directory: URL, codexHome: String) throws {
        guard let raw = (try JSONSerialization.jsonObject(with: input)) as? [String: Any],
              let clean = sanitize(raw, codexHome: codexHome) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys])
        let file = directory.appendingPathComponent(UUID().uuidString + ".json")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        // Bounded retention; directory holds only redacted metadata. Avoid a scan on every tool call.
        if Int.random(in: 0..<100) == 0, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for f in files where f.pathExtension == "json" {
                if let date = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   date < Date().addingTimeInterval(-86400 * 7) { try? FileManager.default.removeItem(at: f) }
            }
        }
    }
    public static func configuration(executable: String, existing: [String: Any]) throws -> [String: Any] {
        if let hooks = existing["hooks"], !(hooks is [String: Any]) {
            throw NSError(domain: "cStatus.Hooks", code: 1, userInfo: [NSLocalizedDescriptionKey: "现有 hooks 配置格式无法安全合并"])
        }
        var result = removingOwned(from: existing)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        let command = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'" + marker
        for event in ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "Interrupt", "PreCompact", "PostCompact"] {
            if let value = hooks[event], !(value is [[String: Any]]) {
                throw NSError(domain: "cStatus.Hooks", code: 2, userInfo: [NSLocalizedDescriptionKey: "现有 \(event) 钩子格式无法安全合并"])
            }
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [["type": "command", "command": command, "timeout": 2, "statusMessage": "cStatus 状态同步"]]])
            hooks[event] = groups
        }
        result["hooks"] = hooks; return result
    }
    public static func removingOwned(from existing: [String: Any]) -> [String: Any] {
        var result = existing
        guard var hooks = existing["hooks"] as? [String: Any] else { return result }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let cleaned = groups.compactMap { group -> [String: Any]? in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                let remaining = handlers.filter { !(($0["command"] as? String)?.hasSuffix(marker) == true && $0["statusMessage"] as? String == "cStatus 状态同步") }
                if remaining.isEmpty { return nil }
                var copy = group; copy["hooks"] = remaining; return copy
            }
            if cleaned.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = cleaned }
        }
        result["hooks"] = hooks; return result
    }
}

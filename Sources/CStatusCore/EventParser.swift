import Foundation

public enum EventParser {
    public static func date(_ value: Any?) -> Date? {
        if let number = value as? Double { return Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number) }
        guard let string = value as? String else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    public static func parse(_ data: Data, namespace: String, threadID fallback: String?, now: Date = Date()) -> [StatusEvent] {
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        if d["cstatus_hook"] as? Bool == true { return parseHook(d, namespace: namespace, now: now) }
        let wire = d["method"] as? String
        let p = (d[wire == nil ? "payload" : "params"] as? [String: Any]) ?? [:]
        guard let thread = p["threadId"] as? String ?? p["thread_id"] as? String ?? fallback else { return [] }
        let turn = p["turn"] as? [String: Any] ?? [:]
        let turnID = p["turnId"] as? String ?? p["turn_id"] as? String ?? turn["id"] as? String
        let evidence: Evidence = wire == nil ? .transcript : .live
        func event(_ kind: EventKind) -> [StatusEvent] {
            let timestamp = date(d["timestamp"]) ?? (wire == "turn/started" ? date(turn["startedAt"]) : nil) ?? now
            return [StatusEvent(namespace: namespace, threadID: thread, turnID: turnID, timestamp: timestamp, kind: kind, evidence: evidence)]
        }
        if let method = wire {
            switch method {
            case "turn/started": return event(.started)
            case "turn/completed":
                guard let status = terminal(turn["status"] as? String) else { return [] }
                return event(.ended(status))
            case "thread/status/changed":
                let status = p["status"] as? [String: Any] ?? [:]
                let flags = (status["activeFlags"] as? [String] ?? []).compactMap { value -> RequestKind? in
                    value == "waitingOnUserInput" ? .input : (value == "waitingOnApproval" ? .approval : nil)
                }
                let state: TaskStatus
                switch status["type"] as? String {
                case "active": state = .running
                case "idle": state = .idle
                case "systemError": state = .failed
                case "notLoaded": state = .unknown
                default: return []
                }
                return event(.runtime(state, flags))
            case "item/tool/requestUserInput", "mcpServer/elicitation/request":
                return event(.requested(requestID(d["id"]) ?? p["itemId"] as? String ?? "input", .input))
            case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval":
                return event(.requested(requestID(d["id"]) ?? p["itemId"] as? String ?? "approval", .approval))
            case "serverRequest/resolved":
                guard let id = requestID(p["requestId"]) else { return [] }; return event(.resolved(id))
            case "error":
                return p["willRetry"] as? Bool == false ? event(.ended(.failed)) : event(.activity("正在重试"))
            case "item/started":
                let item = p["item"] as? [String: Any] ?? [:]
                return event(.activity(activity(item["type"] as? String ?? "")))
            case "thread/closed": return event(.disconnected)
            default: return []
            }
        }
        if d["type"] as? String == "event_msg" {
            if let root = p["root_turn_id"] as? String, let id = turnID, root != id { return [] }
            switch p["type"] as? String {
            case "task_started", "turn_started": return event(.started)
            case "task_complete", "task_completed": return event(.ended(.completed))
            case "turn_aborted": return event(.ended(.interrupted))
            case "request_user_input": return event(.requested(p["call_id"] as? String ?? "input", .input))
            case "exec_approval_request", "apply_patch_approval_request": return event(.requested(p["call_id"] as? String ?? "approval", .approval))
            case "exec_command_begin": return event(.activity("执行命令"))
            case "web_search_begin": return event(.activity("搜索资料"))
            case "context_compacted": return event(.activity("上下文已压缩"))
            case "token_count": return event(.activity("处理中"))
            case "agent_message": return event(.activity("生成回复"))
            case "agent_reasoning": return event(.activity("思考中"))
            case "item_started", "item_completed":
                let item = p["item"] as? [String: Any] ?? [:]
                return event(.activity(activity(item["type"] as? String ?? "")))
            case "patch_apply_end": return event(.activity("修改文件"))
            case "web_search_end": return event(.activity("搜索资料"))
            case "mcp_tool_call_start", "mcp_tool_call_end": return event(.activity("调用工具"))
            default: return []
            }
        }
        if d["type"] as? String == "response_item" {
            let name = p["name"] as? String ?? ""
            let id = p["call_id"] as? String ?? ""
            if p["type"] as? String == "function_call", name.hasSuffix("request_user_input") || name.hasSuffix("request_user_input_async") {
                return id.isEmpty ? [] : event(.requested(id, .input))
            }
            if p["type"] as? String == "function_call_output", let output = p["output"] as? String,
               let data = output.data(using: .utf8), let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               result["answers"] != nil { return event(.resolved(id)) }
            switch p["type"] as? String {
            case "reasoning": return event(.activity("思考中"))
            case "message": return event(.activity("生成回复"))
            case "function_call", "custom_tool_call": return event(.activity(activity(name)))
            case "function_call_output", "custom_tool_call_output": return event(.activity("处理中"))
            default: break
            }
        }
        return []
    }

    private static func parseHook(_ d: [String: Any], namespace: String, now: Date) -> [StatusEvent] {
        guard let thread = d["session_id"] as? String else { return [] }
        let name = d["hook_event_name"] as? String ?? ""
        let tool = d["tool_name"] as? String ?? ""
        let id = d["tool_use_id"] as? String ?? "hook:\(tool)"
        let kind: EventKind
        switch name {
        case "UserPromptSubmit": kind = .started
        case "Interrupt": kind = .ended(.interrupted)
        case "PermissionRequest": kind = .requested(id, .approval)
        case "PreToolUse":
            kind = tool.contains("request_user_input") ? .requested(id, .input) : .activity(activity(tool))
        case "PostToolUse":
            var kinds: [EventKind] = []
            // A successful tool result proves its approval is no longer pending.
            // For input tools, an async acknowledgement does not prove an answer.
            if !tool.contains("request_user_input") || d["has_answers"] as? Bool == true {
                kinds.append(.resolved(id)); kinds.append(.resolved("hook:\(tool)"))
            }
            kinds.append(.activity("继续执行"))
            return kinds.map { StatusEvent(namespace: d["codex_home"] as? String ?? namespace, threadID: thread, turnID: d["turn_id"] as? String,
                                           timestamp: date(d["timestamp"]) ?? now, kind: $0, evidence: .hook) }
        case "Stop": kind = .activity("本轮输出结束 · 等待结果确认")
        case "SessionEnd": kind = .disconnected
        case "PreCompact": kind = .activity("压缩上下文")
        case "PostCompact": kind = .activity("上下文已压缩")
        default: return []
        }
        return [StatusEvent(namespace: d["codex_home"] as? String ?? namespace, threadID: thread,
                            turnID: d["turn_id"] as? String, timestamp: date(d["timestamp"]) ?? now, kind: kind, evidence: .hook)]
    }

    public static func terminal(_ string: String?) -> TaskStatus? {
        switch string { case "completed": return .completed; case "interrupted": return .interrupted; case "failed": return .failed; default: return nil }
    }
    public static func activity(_ type: String) -> String {
        switch type {
        case "reasoning": return "思考中"
        case "commandExecution", "Bash", "exec_command": return "执行命令"
        case "fileChange", "apply_patch": return "修改文件"
        case "webSearch": return "搜索资料"
        case "contextCompaction": return "压缩上下文"
        case "mcpToolCall": return "调用工具"
        case "agentMessage": return "生成回复"
        default: return type.isEmpty ? "处理中" : String(type.prefix(80))
        }
    }
    private static func requestID(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }
}

import Foundation

/// Searches backwards past a bounded display tail, keeping at most one partial line.
/// Only lifecycle records are decoded; transcript text is neither retained nor displayed.
enum LifecycleRecovery {
    static func missingLifecycle(tailEvents: [StatusEvent], baselineTurnID: String? = nil, url: URL, before boundary: UInt64, suffix: Data, namespace: String, threadID: String) throws -> StatusEvent? {
        if tailEvents.contains(where: {
            switch $0.kind {
            case .started: return true
            case .ended: return baselineTurnID == nil || $0.turnID == baselineTurnID
            default: return false
            }
        }) { return nil }
        return try latest(url: url, before: boundary, suffix: suffix, namespace: namespace, threadID: threadID)
    }

    static func latest(url: URL, before boundary: UInt64, suffix: Data, namespace: String, threadID: String) throws -> StatusEvent? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var position = boundary
        var carry = suffix
        let markers = ["task_started", "task_complete", "task_completed", "turn_started", "turn_aborted"].map { Data($0.utf8) }
        while position > 0 {
            let length = Int(min(position, 256 * 1024))
            position -= UInt64(length); try handle.seek(toOffset: position)
            let chunk = try handle.read(upToCount: length) ?? Data()
            let combined = chunk + carry
            let pieces = combined.split(separator: 10, omittingEmptySubsequences: false)
            for line in pieces.dropFirst().reversed() where markers.contains(where: { line.range(of: $0) != nil }) {
                if let event = EventParser.parse(Data(line), namespace: namespace, threadID: threadID).first(where: {
                    switch $0.kind { case .started, .ended: return true; default: return false }
                }) { return event }
            }
            carry = pieces.first.map { Data($0) } ?? Data()
            if carry.count > 8 * 1024 * 1024 { carry = Data() }
        }
        return EventParser.parse(carry, namespace: namespace, threadID: threadID).first {
            switch $0.kind { case .started, .ended: return true; default: return false }
        }
    }
}

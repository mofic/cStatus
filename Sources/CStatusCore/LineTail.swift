import Foundation

public struct TailBatch {
    public var lines: [Data]
    public var isInitial: Bool
    public var historyBoundary: UInt64?
    public var historySuffix = Data()
}

/// Incremental JSONL reader. Keeps an unfinished final line for the next read.
public struct LineTail {
    private var offset: UInt64 = 0
    private var inode: UInt64?
    private var modified: Date?
    private var pending = Data()
    public init() {}

    public mutating func read(url: URL) throws -> TailBatch {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (a[.size] as? NSNumber)?.uint64Value ?? 0
        let identity = (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let mtime = a[.modificationDate] as? Date
        let reset = inode != identity || size < offset || (size == offset && modified != nil && modified != mtime)
        let limit: UInt64 = 2 * 1024 * 1024
        if reset { offset = size > limit ? size - limit : 0; pending = Data() }
        let boundary = reset && offset > 0 ? offset : nil
        let skipFirst = reset && offset > 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let bytes = try handle.read(upToCount: Int(min(size - offset, limit))) ?? Data()
        offset += UInt64(bytes.count); inode = identity; modified = mtime
        pending.append(bytes)
        var lines: [Data] = []
        var start = pending.startIndex
        for newline in pending.indices where pending[newline] == 10 {
            lines.append(Data(pending[start..<newline])); start = pending.index(after: newline)
        }
        pending = Data(pending[start...])
        let suffix = skipFirst && !lines.isEmpty ? lines.removeFirst() : Data()
        // A malformed oversized line must not grow memory without bound.
        if pending.count > Int(limit) { pending.removeAll() }
        return TailBatch(lines: lines, isInitial: reset, historyBoundary: boundary, historySuffix: suffix)
    }
}

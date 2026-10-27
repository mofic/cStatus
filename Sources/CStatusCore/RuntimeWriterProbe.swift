import Foundation

/// Confirms ownership of a specific journal, rather than treating any running Codex as proof.
public enum RuntimeWriterProbe {
    public static func parse(_ data: Data, requested: Set<String>) -> Set<String> {
        var result: Set<String> = []
        var codex = false
        var writable = false
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p": codex = false; writable = false
            case "c": codex = value.lowercased().hasPrefix("codex")
            case "f": writable = false
            case "a": writable = value == "w" || value == "u"
            case "n": if codex && writable && requested.contains(value) { result.insert(value) }
            default: break
            }
        }
        return result
    }
    public static func paths(_ paths: Set<String>) -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-Fpcfan", "--"] + paths.sorted()
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if process.isRunning { process.terminate() } }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return parse(data, requested: paths)
        } catch { return [] }
    }
}

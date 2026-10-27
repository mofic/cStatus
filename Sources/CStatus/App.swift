import AppKit
import SwiftUI
import CStatusCore

@main
struct CStatusMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--hook") {
            let directory = ProcessInfo.processInfo.environment["CSTATUS_EVENTS_DIR"].map { URL(fileURLWithPath: $0) } ?? HookBridge.defaultDirectory
            let root = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
            let input = FileHandle.standardInput.readDataToEndOfFile()
            if input.count <= 2 * 1024 * 1024 { try? HookBridge.record(input: input, directory: directory, codexHome: root) }
            print("{}")
            return
        }
        if args.contains("--diagnose") {
            let index = args.firstIndex(of: "--root")
            let root = index.flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
                ?? ProcessInfo.processInfo.environment["CODEX_HOME"]
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
            if args.contains("--activity") {
                Task.detached {
                    let started = Date()
                    let batch = await MonitorWorker().poll(roots: [URL(fileURLWithPath: root)], hookDirectory: HookBridge.defaultDirectory)
                    var engine = StateEngine(); batch.sessions.forEach { engine.discover($0) }
                    batch.events.forEach { engine.apply($0.event) }
                    engine.markHistoricalUnconfirmed(Set(engine.sessions.keys))
                    let mains = engine.sessions.values.filter(\.isMainTask)
                    let active = mains.filter(\.isActive).sorted { $0.threadID < $1.threadID }
                    let output: [String: Any] = ["mainTasks": mains.count, "activeMainTasks": active.count,
                        "active": active.map { ["thread": String($0.threadID.prefix(8)), "status": $0.status.rawValue, "writerConfirmed": $0.writerActive] as [String: Any] },
                        "errors": batch.errors, "elapsedSeconds": Date().timeIntervalSince(started)]
                    if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted]) { print(String(decoding: data, as: UTF8.self)) }
                    exit(0)
                }
                dispatchMain()
            }
            let scan = SessionReader.scan(root: URL(fileURLWithPath: root))
            var engine = StateEngine(); scan.sessions.forEach { engine.discover($0) }
            scan.events.sorted { $0.timestamp < $1.timestamp }.forEach { engine.apply($0) }
            let sources = Dictionary(grouping: scan.sessions, by: { $0.origin.rawValue }).mapValues(\.count)
            let states = Dictionary(grouping: Array(engine.sessions.values), by: { $0.status.rawValue }).mapValues(\.count)
            let output: [String: Any] = ["sessions": scan.sessions.count, "sources": sources, "recordedStates": states,
                "errors": scan.errors, "liveSocketPresent": FileManager.default.fileExists(atPath: root + "/app-server-control/app-server-control.sock"),
                "coverage": "本地记录已读取；等待状态和独立客户端仍需逐入口实时联调"]
            if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var panels: PanelController!
    private var item: NSStatusItem!
    private var settingsWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel(); panels = PanelController(model: model)
        model.onReminder = { [weak self] session in self?.panels.notify(session: session) }
        model.onSettings = { [weak self] in self?.showSettings() }
        model.onLayout = { [weak self] in self?.panels.reposition() }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "cStatus")
        item.button?.toolTip = "cStatus · Codex 任务监控"
        let menu = NSMenu()
        add(menu, "展开任务栏", #selector(expand), "s")
        add(menu, "设置与接入诊断…", #selector(showSettings), ",")
        menu.addItem(.separator()); add(menu, "退出 cStatus", #selector(quit), "q")
        item.menu = menu
        model.onCount = { [weak self] count in self?.item.button?.title = count > 0 ? " \(count)" : "" }
        panels.show()
        if CommandLine.arguments.contains("--smoke-test") {
            model.demonstrate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                let args = CommandLine.arguments
                if let i = args.firstIndex(of: "--report"), args.indices.contains(i + 1) {
                    panels.smokeReport(to: URL(fileURLWithPath: args[i + 1]))
                }
                NSApplication.shared.terminate(nil)
            }
        } else { model.start() }
    }
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key); entry.target = self; menu.addItem(entry)
    }
    @objc private func expand() { panels.expandForKeyboard() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 650), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "cStatus · 设置与接入诊断"
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.isReleasedWhenClosed = false; window.center(); settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) { model?.stop() }
}

import AppKit
import SwiftUI
import CStatusCore

final class EdgePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController {
    private let model: AppModel
    private let panel: EdgePanel
    private let bubble: NSPanel
    private var timer: Timer?
    private var insideSince: Date?
    private var outsideSince: Date?
    private var keyboardUntil = Date.distantPast
    private var bubbleUntil = Date.distantPast
    private var pending: [Session] = []
    private var bubbleScheduled = false
    private var observer: NSObjectProtocol?
    private var keyMonitor: Any?

    init(model: AppModel) {
        self.model = model
        panel = EdgePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        bubble = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        for window in [panel, bubble] {
            window.level = .floating; window.isOpaque = false; window.backgroundColor = .clear
            window.hasShadow = true; window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
        }
        panel.contentView = NSHostingView(rootView: EdgeRootView(model: model))
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in self?.model.pinned = false; self?.keyboardUntil = .distantPast; self?.setExpanded(false) }
                return nil
            }
            return event
        }
    }
    private var screen: NSScreen? {
        NSScreen.screens.first { String(describing: $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "") == model.screenID } ?? NSScreen.main ?? NSScreen.screens.first
    }
    func show() {
        reposition(); panel.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    func expandForKeyboard() {
        keyboardUntil = Date().addingTimeInterval(30); setExpanded(true)
        panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func reposition() {
        guard let screen else { return }
        let frame = PanelGeometry.frame(screen: screen.visibleFrame, side: model.side, expanded: model.expanded, height: model.expanded ? 680 : 160, y: model.anchorY)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            panel.animator().setFrame(frame, display: true)
        }
        if bubble.isVisible { placeBubble() }
    }
    private func setExpanded(_ value: Bool) {
        guard model.expanded != value else { return }
        model.expanded = value; reposition()
    }
    private func tick() {
        let now = Date(); let mouse = NSEvent.mouseLocation
        let inside = panel.frame.contains(mouse) || (bubble.isVisible && bubble.frame.contains(mouse))
        if model.dragging { insideSince = nil; outsideSince = nil }
        else if model.pinned { setExpanded(true) }
        else if inside {
            outsideSince = nil
            if insideSince == nil { insideSince = now }
            if now.timeIntervalSince(insideSince!) >= 0.15 { setExpanded(true) }
        } else {
            insideSince = nil
            if outsideSince == nil { outsideSince = now }
            if now >= keyboardUntil, now.timeIntervalSince(outsideSince!) >= 0.5 { setExpanded(false) }
        }
        if bubble.isVisible {
            if bubble.frame.contains(mouse) { bubbleUntil = now.addingTimeInterval(6) }
            else if now >= bubbleUntil { dismissBubble() }
        }
    }
    func notify(session: Session) {
        if let index = pending.firstIndex(where: { $0.id == session.id }) { pending[index] = session }
        else { pending.append(session); pending = Array(pending.suffix(5)) }
        guard !bubbleScheduled else { return }
        bubbleScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.presentBubble() }
    }
    private func presentBubble() {
        bubbleScheduled = false
        guard !pending.isEmpty else { return }
        bubble.contentView = NSHostingView(rootView: BubbleView(sessions: pending, open: { [weak self] session in
            self?.model.locate(session); self?.dismissBubble()
        }, dismiss: { [weak self] in self?.dismissBubble() }))
        placeBubble(); bubble.orderFrontRegardless(); bubbleUntil = Date().addingTimeInterval(6)
    }
    private func placeBubble() {
        guard let screen else { return }
        let area = screen.visibleFrame; let width = min(320.0, area.width - 24)
        let x = model.side == .right ? area.maxX - width - 24 : area.minX + 24
        let y = min(max(panel.frame.midY - 55, area.minY + 12), area.maxY - 122)
        bubble.setFrame(NSRect(x: x, y: y, width: width, height: 110), display: true)
    }
    private func dismissBubble() { bubble.orderOut(nil); pending = [] }

    func smokeReport(to url: URL) {
        let collapsed = panel.isVisible && panel.frame.width == 12
        model.expanded = true
        if let screen {
            panel.setFrame(PanelGeometry.frame(screen: screen.visibleFrame, side: model.side, expanded: true, height: 680, y: model.anchorY), display: true)
        }
        let expanded = panel.isVisible && panel.frame.width == 340
        let checks: [String: Any] = ["collapsedPanelVisible": collapsed, "expandedPanelVisible": expanded,
                                    "bubbleVisible": bubble.isVisible, "screenCount": NSScreen.screens.count,
                                    "panelDoesNotActivateOnHover": panel.styleMask.contains(.nonactivatingPanel)]
        if let bytes = try? JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys, .prettyPrinted]) { try? bytes.write(to: url) }
    }
}

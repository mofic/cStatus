import SwiftUI
import AppKit
import CStatusCore

extension TaskStatus {
    var color: Color {
        switch self {
        case .running: return .cyan
        case .waitingInput, .waitingApproval: return .orange
        case .completed: return .green
        case .failed, .interrupted: return .red
        case .unknown, .idle, .disconnected: return .secondary
        }
    }
    var symbol: String {
        switch self {
        case .running: return "waveform.path"
        case .waitingInput: return "questionmark.bubble.fill"
        case .waitingApproval: return "hand.raised.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .interrupted: return "stop.circle.fill"
        case .disconnected: return "wifi.slash"
        case .idle: return "moon"
        case .unknown: return "ellipsis.circle"
        }
    }
}

struct EdgeRootView: View {
    @ObservedObject var model: AppModel
    @State private var dragStartY: Double?
    var body: some View {
        Group {
            if model.expanded { TaskPanelView(model: model) }
            else {
                VStack(spacing: 10) {
                    Capsule().fill(model.attentionCount > 0 ? Color.orange : Color.cyan).frame(width: 3, height: 28)
                    Text("\(model.activeCount)").font(.system(size: 9, weight: .bold, design: .rounded))
                    if model.attentionCount > 0 { Circle().fill(.orange).frame(width: 5, height: 5) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { model.pinned = true }
                .gesture(DragGesture().onChanged { value in
                    model.dragging = true
                    if dragStartY == nil { dragStartY = model.anchorY }
                    model.anchorY = (dragStartY ?? model.anchorY) - value.translation.height
                    model.onLayout?()
                }.onEnded { _ in dragStartY = nil; model.dragging = false })
                .accessibilityLabel("Codex 任务栏，\(model.activeCount) 个活动任务，\(model.attentionCount) 个待处理")
                .help("鼠标停留展开 · 拖动调整位置")
            }
        }
    }
}

struct TaskPanelView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 8) {
                stat("进行中", value: model.activeCount, color: .cyan)
                stat("待处理", value: model.attentionCount, color: .orange)
                Spacer()
                Circle().fill(model.connected ? Color.green : Color.orange).frame(width: 5, height: 5)
                Text(model.connected ? "实时 + 本地" : "本地记录").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.bottom, 14)
            Divider()
            VStack(spacing: 10) {
                Picker("任务筛选", selection: $model.filter) { ForEach(["当前", "待处理", "全部"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("搜索任务或项目", text: $model.search).textFieldStyle(.plain)
                }.font(.system(size: 12)).padding(8).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
            }.padding(14)
            if model.visible.isEmpty {
                Spacer()
                Image(systemName: "waveform.path").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                Text(model.filter == "待处理" ? "暂时没有待处理任务" : "等待 Codex 活动").font(.headline).padding(.top, 8)
                Text("启动 CLI、VS Code 或 Codex 客户端后，\n本地会话会在这里出现。").font(.system(size: 11)).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.top, 4)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(model.visible) { session in TaskCard(session: session, model: model) }
                    }.padding(.horizontal, 12).padding(.bottom, 12)
                }
            }
            Divider()
            Button { model.onSettings?() } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: model.connected ? "checkmark.shield" : "info.circle").foregroundStyle(model.connected ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.connected ? "查看各入口状态覆盖" : "等待状态需要实时接入").font(.system(size: 11, weight: .medium))
                        Text(model.errors.first ?? "设置与接入诊断 →").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }.padding(14).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12), lineWidth: 1))
        .padding(.vertical, 2)
    }
    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "waveform.path").font(.system(size: 19, weight: .semibold)).foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text("cStatus").font(.system(size: 18, weight: .bold, design: .rounded))
                Text("CODEX ACTIVITY").font(.system(size: 8, weight: .medium)).tracking(1.8).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.pinned.toggle() } label: { Image(systemName: model.pinned ? "pin.fill" : "pin") }.help(model.pinned ? "取消固定" : "固定展开")
            Button { model.onSettings?() } label: { Image(systemName: "gearshape") }.help("设置与接入诊断")
        }.buttonStyle(.plain).padding(18)
    }
    private func stat(_ label: String, value: Int, color: Color) -> some View {
        HStack(spacing: 4) { Text("\(value)").font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundStyle(color); Text(label).font(.system(size: 11)).foregroundStyle(.secondary) }
    }
}

struct TaskCard: View {
    let session: Session
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: session.status.symbol).foregroundStyle(session.status.color)
                Text(session.status.label).fontWeight(.medium).foregroundStyle(session.status.color)
                if model.isAcknowledged(session) { Text("已查看").foregroundStyle(.tertiary) }
                Spacer()
                Text(session.origin.label).font(.system(size: 9, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 3).background(.quaternary, in: Capsule())
            }.font(.system(size: 10))
            Button { model.locate(session) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title).font(.system(size: 12, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    Label(session.project, systemImage: "folder").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help("打开来源项目并复制线程 ID")
            if !session.activity.isEmpty { Text(session.activity).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
            HStack {
                Text(session.coverageLabel).lineLimit(1)
                Spacer(minLength: 4)
                Text(session.updatedAt, style: .relative).monospacedDigit()
            }.font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(12).background(session.status.needsAttention && !model.isAcknowledged(session) ? session.status.color.opacity(0.07) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(session.status.needsAttention && !model.isAcknowledged(session) ? session.status.color.opacity(0.22) : Color.primary.opacity(0.04), lineWidth: 1))
        .contextMenu {
            Button("打开来源 / 复制线程 ID") { model.locate(session) }
            Button("仅复制线程 ID") { model.copyID(session) }
            Button("标记已查看") { model.acknowledge(session) }
            Button("隐藏任务") { model.hide(session) }
        }
        .accessibilityElement(children: .contain)
    }
}

struct BubbleView: View {
    let sessions: [Session]
    let open: (Session) -> Void
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let session = sessions.last {
                Image(systemName: session.status.symbol).font(.system(size: 23)).foregroundStyle(session.status.color).padding(.top, 3)
                Button { open(session) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(sessions.count > 1 ? "\(sessions.count) 个任务状态变化" : session.status.label).font(.system(size: 12, weight: .semibold))
                        Text(session.title).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.leading)
                        Text("\(session.project) · \(session.origin.label)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("关闭提醒")
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .padding(2)
    }
}

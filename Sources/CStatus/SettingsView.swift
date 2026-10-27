import SwiftUI
import AppKit
import CStatusCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var tab = "外观与提醒"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Image(systemName: "waveform.path").foregroundStyle(.cyan); Text("cStatus").font(.title2.bold()); Spacer(); Text("本机 Codex 状态监控").foregroundStyle(.secondary).font(.caption) }
            Picker("设置页", selection: $tab) { ForEach(["外观与提醒", "状态接入", "诊断"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if tab == "外观与提醒" { appearance }
                    else if tab == "状态接入" { connections }
                    else { diagnostics }
                    if !model.actionMessage.isEmpty {
                        Text(model.actionMessage).font(.callout).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(2)
            }
        }.padding(24).frame(width: 620, height: 650)
    }
    private var appearance: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("贴边栏") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("贴边方向", selection: $model.side) { Text("左侧").tag(EdgeSide.left); Text("右侧").tag(EdgeSide.right) }.pickerStyle(.segmented)
                    Picker("所在屏幕", selection: $model.screenID) {
                        Text("主屏幕").tag("")
                        ForEach(NSScreen.screens, id: \.localizedName) { screen in
                            Text(screen.localizedName).tag(String(describing: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? ""))
                        }
                    }
                    Toggle("固定展开", isOn: $model.pinned)
                    Text("鼠标停留边缘约 0.15 秒展开，移出约 0.5 秒收起。拖动收起的把手可调整高度；Esc 收起。").font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            }
            GroupBox("状态提醒") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("提示音", isOn: $model.sound)
                    Toggle("macOS 系统通知", isOn: Binding(get: { model.systemNotifications }, set: { model.enableNotifications($0) }))
                    Text("完成、中断、失败、等待回答或授权时冒泡。冒泡约 6 秒后消失，悬停暂停消失；待处理任务保留在列表中。").font(.caption).foregroundStyle(.secondary)
                    HStack { Button("预览冒泡提醒") { model.demonstrate() }; Button("恢复隐藏的任务") { model.showHidden() } }
                }.padding(10)
            }
        }
    }
    private var connections: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Codex 数据目录") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.roots, id: \.self) { root in
                        HStack {
                            Text(root).font(.caption.monospaced()).textSelection(.enabled)
                            Spacer()
                            if model.roots.count > 1 { Button("移除") { model.roots.removeAll { $0 == root }; model.restartConnections() } }
                        }
                    }
                    Button("添加数据目录…") { model.addRoot() }
                    Text("自动发现最多 300 个近期非归档会话；同一会话按数据目录和线程 ID 合并。支持另设 CODEX_HOME 的本地实例。").font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            }
            GroupBox("连接现有 App Server") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(model.cliPath.isEmpty ? "未找到 CLI" : model.cliPath).font(.caption.monospaced()).lineLimit(2); Spacer(); Button("选择 CLI…") { model.selectCLI() } }
                    TextField("自定义控制 socket（留空自动检测）", text: $model.socketPath).textFieldStyle(.roundedBorder)
                    Button("重新连接") { model.restartConnections() }
                    Text(model.liveMessage).font(.caption).foregroundStyle(.secondary)
                    Text("只读取现有服务的线程和运行状态，不启动新服务、不恢复任务、不代替你回答或授权。不同客户端的私有服务未必共享此入口。").font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            }
            GroupBox("官方生命周期钩子（补充等待事件）") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("为第一个数据目录合并 hooks.json，备份并保留现有钩子。仅记录状态元数据，不保存提示词、工具参数或回答。移动应用后需要重新配置。").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("配置 cStatus 钩子") { model.configureHooks(enable: true) }
                        Button("移除 cStatus 钩子") { model.configureHooks(enable: false) }
                    }
                    Text("配置后请在 Codex 的 /hooks 中审阅并信任，再重新打开会话。不同客户端／版本需验证是否实际发出这些事件；未收到事件前不会显示完整接入。").font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            }
        }
    }
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(model.liveMessage, systemImage: model.connected ? "checkmark.circle" : "info.circle").font(.callout)
            Text("已发现 \(model.sessions.count) 个会话 · 本次收到 \(model.hooksObserved) 个钩子事件").font(.caption).foregroundStyle(.secondary)
            ForEach([ClientOrigin.cli, .vscode, .desktop, .unknown], id: \.self) { origin in
                let sessions = model.sessions.filter { $0.origin == origin }
                GroupBox(origin.label) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(sessions.isEmpty ? "未检测到此来源的会话" : "发现 \(sessions.count) 个会话；\(sessions.filter(\.liveConnected).count) 个有实时连接").font(.callout)
                        let versions = Set(sessions.map(\.version).filter { !$0.isEmpty }).sorted()
                        if !versions.isEmpty { Text("会话版本：" + versions.joined(separator: ", ")).font(.caption).textSelection(.enabled) }
                        Text("完成／中断／失败：读取明确记录。等待回答／授权：需可用实时事件或钩子；历史日志只覆盖实际记录的请求。").font(.caption).foregroundStyle(.secondary)
                        Text("兼容性：尚未完成此入口的全部真实状态联调。").font(.caption).foregroundStyle(.orange)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
            Text("来源标签反映会话元数据中的创建来源；同一会话在另一个客户端打开时，标签不一定代表当前活跃窗口。").font(.caption).foregroundStyle(.secondary)
            if let date = model.lastRefresh { Text("最近读取：\(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
            ForEach(model.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }
}

# cStatus

macOS 原生 Codex 任务侧栏，使用 SwiftUI + AppKit。监控本机 CLI、VS Code 和 Codex 独立客户端的会话数据；实时状态的覆盖取决于客户端实际暴露的服务或钩子。

## 运行

打开 `dist/cStatus.app`。应用默认收起在主屏右侧，菜单栏显示波形图标。

- 鼠标停留贴边把手展开，移出后收起；点击图钉固定，Esc 收起。
- 完成、中断、失败、需要回答／授权时弹出冒泡，悬停可延长显示。
- 只展示和提醒主任务；子代理与审核任务不计数、不弹提醒。菜单栏数字始终为进行中的主任务数量。
- 右键任务可标记已查看、隐藏已结束任务或复制线程 ID。点击任务打开来源应用或项目，同时复制线程 ID。
- 设置中可切换左右边缘、屏幕，添加其他 Codex 数据目录，开启声音与系统通知。

建议先将 `.app` 放到固定位置，再配置钩子。当前包为本机 Apple Silicon 构建及临时签名，最低 macOS 14；未做 Developer ID 签名、公证或 Intel 构建验证。

## 状态接入

应用自动只读扫描 Codex 数据目录（默认 `~/.codex`），兼容本机已发现的 legacy 日志及 paginated 历史投影。近期历史默认限制 300 个主任务；历史索引中仍未结束的主回合另外加入发现范围。创建来源不等于当前打开会话的客户端，因此来源标签可能保留创建时的入口。

完成、中断、失败必须有明确事件或历史记录。启动时恢复长日志的回合开始／结束记录，并以对应 Codex 可写文件句柄确认仍未结束的任务。没有可靠运行证据时显示状态未确认；不会用文件长时间未更新猜测任务已结束。历史读取不重放完成通知。

获取等待回答／授权等实时状态有两条路径：

1. **已有共享 App Server**：设置中选择 CLI，应用尝试通过 `codex app-server proxy` 连接已有控制 socket。可指定其他控制 socket。仅监控该服务实际暴露的线程，不会另起服务冒充监控其他客户端，也不会调用 `thread/resume` 或批准／回答请求。
2. **官方生命周期钩子**：在“状态接入”中点击“配置 cStatus 钩子”，向第一个数据目录的 `hooks.json` 合并观察钩子并备份原文件。随后在 Codex `/hooks` 中审阅并信任，再重新打开会话。此操作不会绕过 Codex 的钩子信任机制。不同客户端和版本需要实际验证是否发出这些事件。

钩子只记录会话／回合／工具标识、事件类型、时间及回答是否存在，不保存提示词、回答或工具参数。元数据保存在 `~/Library/Application Support/cStatus/events`，自动清理超过七天的记录。移除钩子使用应用设置中的按钮；其他钩子保持原样。移动或重新构建应用后需重新配置并由 Codex 重新信任。

**当前不能承诺零配置、所有版本、所有入口的全部实时状态。** 本机未发现可连接的共享控制 socket，也未检测到独立客户端安装。程序提供接入机制和明确的能力提示；完整覆盖仍需在每个真实客户端中验证。详情见 [兼容性与验证记录](docs/compatibility.md)。

## 构建和验证

需要 Xcode / Swift 5.9 或更高版本，无第三方包依赖。

```sh
bash scripts/test.sh
bash scripts/build-app.sh
open dist/cStatus.app
```

使用 Xcode 可直接打开 `Package.swift`。构建脚本把模块缓存放在项目 `.build` 中，并在 release 包中关闭调试符号生成，以适应本工作区的沙箱限制。

只读诊断（仅输出数量和覆盖信息，不输出任务文本）：

```sh
dist/cStatus.app/Contents/MacOS/cStatus --diagnose
dist/cStatus.app/Contents/MacOS/cStatus --diagnose --root /path/to/codex-home
dist/cStatus.app/Contents/MacOS/cStatus --diagnose --activity
```

运行测试包的原生窗口冒烟检查：

```sh
bash scripts/smoke-test.sh
```

冒烟测试只创建预览窗口，不修改 Codex 配置、不启动 Codex 任务。测试输出保存于 `.build/ui-smoke.json`；真正的鼠标操作、Space、睡眠唤醒和所有客户端状态联调另行记录。

## 工程结构

- `Sources/CStatusCore`：状态归一化、回合隔离、提醒去重、只读数据库、增量日志、钩子桥接与窗口几何。
- `Sources/CStatus`：原生窗口、菜单栏、任务列表、设置、已有服务观察连接。
- `Tests/CStatusCoreTests`：真实临时 SQLite／日志、协议及状态回归、已有服务连接分页测试。
- `docs/superpowers`：设计和实施计划；`docs/implementation-progress.md` 保存实施记录。

协议与钩子参考：[App Server](https://learn.chatgpt.com/docs/app-server)、[Hooks](https://learn.chatgpt.com/docs/hooks)。Codex 的本地数据库和日志格式可能变化；不支持的结构会显示诊断，不会静默当成完整接入。

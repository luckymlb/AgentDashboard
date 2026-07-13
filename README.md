# AgentDashboard
macOS 中的 **agent cli 管理工具**

在 macOS 菜单栏集中查看 Claude Code 和 Codex CLI：谁正在工作、谁在等待确认、谁已经完成。

<img width="356" height="340" alt="image" src="https://github.com/user-attachments/assets/add6171f-a901-48f2-a391-05d117d91e07" />

<img width="362" height="338" alt="image" src="https://github.com/user-attachments/assets/0d6b6154-464b-46d7-97f3-1e8b1c60e91a" />

<img width="358" height="42" alt="image" src="https://github.com/user-attachments/assets/d37affbc-67e7-43f0-95e8-244a3814dadd" />

<img width="357" height="45" alt="image" src="https://github.com/user-attachments/assets/272c89da-a093-4dec-9e68-f57d45cffea9" />

<img width="359" height="46" alt="image" src="https://github.com/user-attachments/assets/10ebe397-66db-4f57-be81-69e1bd220f28" />

<img width="358" height="43" alt="image" src="https://github.com/user-attachments/assets/61fcbd94-820e-4948-af6e-cbe34b34a4bb" />


AgentDashboard 在本机读取终端进程和会话状态，不主动上传会话内容。它可以同时监控多个项目，支持中文目录，并可点击直接跳转到对应的 iTerm2 或 Terminal.app 会话。

## 核心功能

- **统一监控 Claude 与 Codex**：自动发现正在终端中运行的交互式 Agent
- **细粒度状态**：显示 Thinking、Running、Reading、Editing、Confirming 等状态
- **授权提醒**：出现 Yes / No 权限确认时，菜单栏图标和对应 Agent 会变为橙色
- **Token 统计**：显示 Claude 和 Codex 的累计 Token，悬停可查看分项
- **任务通知**：等待授权或较长任务完成时发送 macOS 通知
- **一键跳转**：点击 Agent 或系统通知，直接切换到对应终端标签页
- **完成未读**：Claude 任务完成后显示蓝色圆点，点击 Agent 后清除
- **多实例支持**：区分不同目录、不同终端以及同一目录中的多个 Codex 会话

## 系统要求

- macOS 13 或更高版本
- Swift 5.9 或更高版本
- iTerm2 或 Terminal.app
- Xcode，或版本匹配的 Xcode Command Line Tools

## 安装

目前需要从源码构建：

```bash
git clone https://github.com/luckymlb/AgentDashboard.git
cd AgentDashboard
./build.sh
```

`./build.sh` 会构建应用、打包到 `build/AgentDashboard.app`，然后自动关闭旧实例并启动新版本。

只构建、不启动：

```bash
./build.sh --no-run
```

以后重新启动不需要再次构建：

```bash
open build/AgentDashboard.app
```

也可以把 `AgentDashboard.app` 添加到 macOS「登录项」，让它在登录时自动启动。

## 首次使用

启动后，菜单栏会出现爪印图标。首次使用部分功能时，macOS 可能请求以下权限：

- **通知**：用于显示等待授权和任务完成提醒
- **自动化**：用于控制 iTerm2 或 Terminal.app，并切换到对应标签页

如果之前拒绝过权限，可以在「系统设置 → 隐私与安全性」中重新开启。

Codex 无需额外配置。Claude Code 建议配置 Hooks，以获得更及时、更准确的状态。

## 配置 Claude Code Hooks

不配置 Hooks 也能发现 Claude 进程，但状态更新会更慢，部分状态只能通过本地会话文件和进程活动推断。

将以下配置合并到 `~/.claude/settings.json`：

<details>
<summary>展开完整 Hooks 配置</summary>

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "curl -s -X POST -H 'Content-Type: application/json' -d @- 'http://127.0.0.1:8765/hook?type=PreToolUse' --max-time 1 2>/dev/null || true"}]
      }
    ],
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "curl -s -X POST -H 'Content-Type: application/json' -d @- 'http://127.0.0.1:8765/hook?type=PermissionRequest' --max-time 1 2>/dev/null || true"}]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "curl -s -X POST -H 'Content-Type: application/json' -d @- 'http://127.0.0.1:8765/hook?type=PostToolUse' --max-time 1 2>/dev/null || true"}]
      }
    ],
    "PostToolUseFailure": [
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "curl -s -X POST -H 'Content-Type: application/json' -d @- 'http://127.0.0.1:8765/hook?type=PostToolUseFailure' --max-time 1 2>/dev/null || true"}]
      }
    ],
    "Stop": [
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "curl -s -X POST -H 'Content-Type: application/json' -d @- 'http://127.0.0.1:8765/hook?type=Stop' --max-time 1 2>/dev/null || true"}]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "curl -s -X POST -H 'Content-Type: application/json' -d @- 'http://127.0.0.1:8765/hook?type=UserPromptSubmit' --max-time 1 2>/dev/null || true"}]
      }
    ],
    "Notification": [
      {
        "matcher": "permission_prompt",
        "hooks": [{"type": "command", "command": "curl -s -X POST -H 'Content-Type: application/json' -d @- 'http://127.0.0.1:8765/hook?type=Notification' --max-time 1 2>/dev/null || true"}]
      }
    ]
  }
}
```

</details>

如果已经配置了其他 Hooks，请把 AgentDashboard 的命令作为独立的 matcher 条目添加。不要让多个命令共享同一个 stdin 管道，否则可能发生阻塞。

## Claude 与 Codex

| 能力 | Claude Code | Codex CLI |
|---|---|---|
| 自动发现终端实例 | 支持 | 支持 |
| 状态更新 | 推荐使用 Hooks | 自动读取本地会话 |
| Yes / No 授权提醒 | 支持 | 支持 |
| 当前任务计时 | 支持 | 支持 |
| Token 统计 | 支持 | 支持 |
| 中文目录 | 支持 | 支持 |
| 额外配置 | 推荐配置 Hooks | 无需配置 |

Claude 配置 Hooks 后，状态通常会立即更新。Codex 状态来自本地 session rollout，会随 Dashboard 的轮询周期更新：面板打开时约每 2 秒一次，后台约每 10 秒一次。

## 使用方法

点击菜单栏爪印即可打开 Agent 列表。

| 界面元素 | 含义 |
|---|---|
| 爪印旁的数字 | 当前活跃 Agent 数量 |
| 橙色爪印 | 至少有一个 Agent 正在等待权限确认 |
| Active | 正在处理任务或等待确认的 Agent |
| Idle | 已完成或正在等待新输入的 Agent |
| 蓝色圆点 | Claude 任务已完成，但还没有查看 |
| `tok` | 当前会话累计 Token；悬停可查看分项 |

点击任意 Agent 行会清除未读标记，并跳转到它所在的 iTerm2 或 Terminal.app 标签页。

## 状态说明

| 状态 | 颜色 | 含义 |
|---|---|---|
| Confirming | 橙色 | 等待 Yes / No 权限确认 |
| Thinking | 紫色 | 模型正在推理 |
| Crafting | 蓝色 | 正在生成文本回复 |
| Running | 绿色 | 正在执行命令 |
| Reading | 青色 | 正在读取文件 |
| Editing / Writing | 橙色 | 正在修改或创建文件 |
| Searching | 黄色 | 正在搜索代码或网页 |
| Processing | 薄荷色 | 正在执行 Agent、Workflow 等子任务 |
| Busy | 绿色 | 正在工作，但无法进一步识别具体类型 |
| Waiting / Idle | 灰色 | 等待输入或任务已结束 |

## Token 统计

Agent 行右侧会显示当前会话的累计 Token。将鼠标悬停在 Token 和时间区域，可以查看 Input、Cache creation、Cache read、Output 和 Total。

不同模型提供的 Cache 字段可能不同；AgentDashboard 只展示会话文件中实际可用的数据。

## 系统通知

AgentDashboard 会在以下情况发送通知：

- Claude 或 Codex 正在等待权限确认
- 较长任务从 Active 变为 Idle

点击通知会尝试跳转到对应终端。通知声音和横幅可以在 macOS「系统设置 → 通知 → AgentDashboard」中调整。

## 常见问题

### 没有显示正在运行的 Agent

- 确认 Claude Code 或 Codex 运行在带 TTY 的交互式终端中
- 点击面板右上角的刷新按钮
- 重新启动 AgentDashboard
- Codex 刚启动时可能需要短暂等待本地 session 文件生成

### Claude 状态更新不及时

- 检查 `~/.claude/settings.json` 中的 Hooks 配置
- 确认本机端口 `8765` 没有被其他程序占用
- 修改配置后重新启动 Claude Code 和 AgentDashboard

### 点击 Agent 后没有跳转

- 当前仅支持 iTerm2 和 Terminal.app
- 在「系统设置 → 隐私与安全性 → 自动化」中允许 AgentDashboard 控制终端
- 确认原终端标签页仍然存在

### 没有收到系统通知

- 在「系统设置 → 通知」中允许 AgentDashboard 发送通知
- 短任务不会发送完成通知，以避免频繁打扰

### 构建时提示 Swift、SDK 或 XCTest 错误

确认 Xcode 或 Command Line Tools 与当前 Swift 工具链版本匹配：

```bash
xcode-select -p
swift --version
```

## 当前限制

- 仅支持 macOS 13 及以上版本
- 仅支持 iTerm2 和 Terminal.app 的标签页跳转
- 仅监控带 TTY 的交互式 Claude Code / Codex CLI 进程
- Codex 状态依赖其本地 session 格式；Codex CLI 大版本更新后可能需要适配
- 未配置 Claude Hooks 时，状态精度和更新速度会降低

## 开发

```bash
swift build
swift test
```

GitHub Actions 会在 push 到 `main` 和 Pull Request 时运行测试。

## License

MIT

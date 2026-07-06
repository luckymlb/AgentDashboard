# AgentDashboard

macOS 菜单栏应用，实时监控所有运行中的 Claude Code / Codex 终端实例。精确显示每个 Agent 的工作状态，支持一键跳转 iTerm2 / Terminal.app。

## 特性

- **Hook 实时状态** — 通过 Claude Code hooks 实时接收状态变更，无延迟
- **细粒度状态** — 区分 Thinking / Reading / Editing / Writing / Running / Searching 等 10 种状态
- **Active 计时** — 显示当前 turn 已运行时长，与 Claude Code 终端一致
- **未读指示** — Agent 完成任务后显示蓝色圆点，点击后消失
- **一键跳转** — 点击任意行直接激活对应 iTerm2 / Terminal.app 会话，自动识别终端归属
- **Idle 排序** — 按最近活跃时间排序，未读优先置顶
- **菜单栏常驻** — 轻量运行，不占用 Dock

## 安装

### 从源码构建

```bash
git clone https://github.com/luckymlb/AgentDashboard.git
cd AgentDashboard
./build.sh
```

`./build.sh` 会自动杀掉旧实例并启动新版;加 `--no-run` 则只构建不启动。

要求：macOS 13+、Swift 5.7+

### 配置 Hooks（推荐）

在 `~/.claude/settings.json` 中添加 hook 配置，启用实时状态推送：

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "curl -s -X POST -H 'Content-Type: application/json' -d @- 'http://127.0.0.1:8765/hook?type=PreToolUse' --max-time 1 2>/dev/null || true"}]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "curl -s -X POST -H 'Content-Type: application/json' -d @- 'http://127.0.0.1:8765/hook?type=PostToolUse' --max-time 1 2>/dev/null || true"}]
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
        "matcher": "*",
        "hooks": [{"type": "command", "command": "curl -s -X POST -H 'Content-Type: application/json' -d @- 'http://127.0.0.1:8765/hook?type=Notification' --max-time 1 2>/dev/null || true"}]
      }
    ]
  }
}
```

> **注意**：如果你已有其他 hooks，将上述条目作为独立的 matcher 条目添加（不要合并到同一个 hooks 数组），以避免 stdin 管道共享导致阻塞。

不配置 hooks 也能工作（回退到 transcript 文件轮询），但状态更新会有数秒延迟。

## 状态检测原理

采用四层混合检测策略（优先级从高到低）：

| 层级 | 来源 | 延迟 | 说明 |
|------|------|------|------|
| 1 | Hook HTTP 事件 | 实时 | PreToolUse/Stop 等事件推送到本地 HTTP server |
| 2 | Session JSON | ~2s | `~/.claude/sessions/{pid}.json` 的 busy/idle 状态 |
| 3 | Transcript JSONL | ~2s | 读取对话文件尾部推断具体工具调用 |
| 4 | CPU fallback | ~10s | `ps` 命令的 CPU 使用率兜底 |

## 状态颜色

| 状态 | 颜色 | 含义 |
|------|------|------|
| Thinking | 🟣 紫色 | 模型推理中 |
| Crafting | 🔵 蓝色 | 生成文本回复 |
| Running | 🟢 绿色 | 执行 Bash 命令 |
| Reading | 🩵 青色 | 读取文件 |
| Editing / Writing | 🟠 橙色 | 修改/创建文件 |
| Searching | 🟡 黄色 | 搜索代码/网页 |
| Processing | 💚 薄荷 | Agent/Workflow 子任务 |
| Idle / Waiting | ⚪ 灰色 | 空闲等待输入 |

## 项目结构

```
AgentDashboard/Sources/
├── main.swift                       # 应用入口
├── AgentDashboardApp.swift          # AppDelegate + 菜单栏
├── Models/
│   ├── AgentInfo.swift              # 数据模型 + AgentStatus 枚举
│   └── HookEvent.swift              # Hook 事件数据模型
├── Services/
│   ├── ProcessScanner.swift         # 进程扫描 + 状态整合
│   ├── HookServer.swift             # NWListener HTTP server (port 8765)
│   ├── HookListener.swift           # Hook 事件 → 状态映射
│   ├── TranscriptTailReader.swift   # JSONL 尾部读取
│   ├── ITerm2Bridge.swift           # iTerm2 AppleScript 跳转
│   ├── TerminalAppBridge.swift      # Terminal.app AppleScript 跳转
│   └── TerminalBridge.swift         # 按终端类型派发跳转
└── Views/
    ├── MenuBarPopover.swift         # 主面板
    ├── AgentRowView.swift           # Agent 行视图
    └── StatusBadge.swift            # 状态指示灯
```

## 技术实现

- **纯 AppKit** — 不使用 SwiftUI App lifecycle，直接 NSApplication + NSStatusItem
- **Network.framework** — 零依赖 HTTP server 接收 hook 事件
- **Hook stdin 隔离** — 每个 hook 命令作为独立 matcher 条目，避免管道共享阻塞
- **状态防抖** — PostToolUse 保持上一状态，避免 thinking/running 快速闪烁
- **异步扫描** — `Task.detached` + `nonisolated static` 避免阻塞主线程
- **终端自动识别** — 沿父进程链上溯判定 iTerm2 / Terminal.app，按 pid 缓存避免重复 fork

## License

MIT

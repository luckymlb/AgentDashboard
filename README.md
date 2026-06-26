# AgentDashboard

macOS 菜单栏应用，实时监控所有运行中的 Claude Code 和 Codex 终端实例。

## 功能

- **实时状态监控** — 精确显示每个 Agent 的活动状态（Thinking / Crafting / Running / Reading / Editing / Writing / Searching / Processing / Waiting / Idle）
- **一键跳转** — 点击任意行直接跳转到对应的 iTerm2 tab
- **菜单栏常驻** — 轻量运行，不占用 Dock，随时点击查看
- **自动刷新** — 每 2 秒自动扫描更新状态

## 状态检测原理

采用三层混合检测策略：

1. **Session 文件** (`~/.claude/sessions/{pid}.json`) — 获取 busy/idle 基础状态、sessionId、cwd
2. **Transcript JSONL** (`~/.claude/projects/{project}/{sessionId}.jsonl`) — 读取文件尾部推断精确活动（thinking/tool_use/text）
3. **Job State** (`~/.claude/jobs/{jobId}/state.json`) — 检测 background job 的运行状态

状态优先级：session idle 覆盖一切 → session busy 时读 transcript → 有 busy 子 job 时读子 job 的 transcript → CPU fallback 兜底。

## 构建运行

```bash
# 构建
swift build

# 打包并运行
./build.sh
open build/AgentDashboard.app
```

要求：macOS 13+、Swift 5.7+

## 项目结构

```
AgentDashboard/Sources/
├── main.swift                          # 应用入口
├── AgentDashboardApp.swift             # AppDelegate + 菜单栏配置
├── Models/
│   └── AgentInfo.swift                 # 数据模型 + 状态枚举
├── Services/
│   ├── ProcessScanner.swift            # 进程扫描 + 状态解析
│   ├── TranscriptTailReader.swift      # JSONL 尾部读取推断活动
│   └── ITerm2Bridge.swift              # iTerm2 AppleScript 跳转
└── Views/
    ├── MenuBarPopover.swift            # 主面板
    ├── AgentRowView.swift              # Agent 行视图
    └── StatusBadge.swift               # 状态指示灯
```

## 状态颜色

| 状态 | 颜色 | 含义 |
|------|------|------|
| Thinking | 🟣 紫色 | 模型推理中 |
| Crafting | 🔵 蓝色 | 生成文本回复 |
| Running | 🟢 绿色 | 执行命令 |
| Reading | 🩵 青色 | 读取文件 |
| Editing / Writing | 🟠 橙色 | 修改文件 |
| Searching | 🟡 黄色 | 搜索代码/网页 |
| Processing | 💚 薄荷 | 等待工具结果 |
| Idle / Waiting | ⚪ 灰色 | 空闲 |

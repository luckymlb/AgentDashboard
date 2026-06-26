# AgentDashboard

## 项目概述

macOS 菜单栏应用，监控运行中的 Claude Code / Codex 终端实例，显示细粒度状态并支持一键跳转 iTerm2。

## 构建

```bash
swift build          # 编译
./build.sh           # 打包 .app 并输出到 build/
pkill -f AgentDashboard; open build/AgentDashboard.app  # 重启
```

## 技术要点

- 纯 AppKit 入口（main.swift），不使用 SwiftUI App lifecycle
- `@MainActor` 标注 ProcessScanner 和 AppDelegate；耗时扫描用 `Task.detached` + `nonisolated static` 方法
- Info.plist 唯一来源为 `AgentDashboard/Resources/Info.plist`，build.sh 直接复制
- 状态颜色集中在 `AgentStatus.color`，其他 View 直接引用

## 代码规范

- 日志使用 `os.Logger`，不要用 NSLog 或 print
- 新增状态需同时更新 `AgentStatus` 的 label / sortPriority / color
- tty 插入 AppleScript 前必须通过正则验证

## Git 提交

- 在完成一个完整功能或修复后进行 git 提交
- commit message 使用英文，简洁描述改动意图
- 不要提交 build/ 和 .build/ 目录

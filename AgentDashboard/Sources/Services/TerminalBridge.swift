import AppKit
import os

private let jumpLogger = Logger(subsystem: "com.lucky.AgentDashboard", category: "TerminalJump")

enum TerminalJumpResult: Sendable, Equatable {
    case success
    case failure(TerminalJumpFailure)
}

enum TerminalJumpFailure: Error, Sendable, Equatable {
    case targetRejected(NotificationTargetRejection)
    case invalidTTY
    case terminalUnknown
    case appNotRunning
    case sessionNotFound
    case permissionDenied
    case timedOut
    case scriptFailed

    var message: String {
        switch self {
        case .targetRejected(.terminalUnknown), .terminalUnknown:
            return "无法识别该会话所在的终端。目前支持 iTerm2 和 Terminal。"
        case .targetRejected(.ttyMissing):
            return "该会话没有可跳转的终端。桌面 Codex 会话暂不支持终端跳转。"
        case .targetRejected:
            return "原 Agent 进程已退出或发生变化。请刷新列表后重试。"
        case .invalidTTY:
            return "终端地址无效。请刷新列表后重试。"
        case .appNotRunning:
            return "目标终端已关闭。请刷新列表后重试。"
        case .sessionNotFound:
            return "找不到原终端标签页，它可能已关闭。请刷新列表后重试。"
        case .permissionDenied:
            return "请在系统设置 → 隐私与安全性 → 自动化中，允许 AgentDashboard 控制目标终端。"
        case .timedOut:
            return "终端响应超时。请关闭终端中的对话框后重试。"
        case .scriptFailed:
            return "无法切换到目标终端。请确认终端正常运行后重试。"
        }
    }
}

/// 列表和通知共用点击时验证。unknown 不能猜测为 iTerm2。
enum TerminalBridge {
    @MainActor static var onWillActivate: (() -> Void)?

    @MainActor
    static func activate(target: NotificationTarget) async -> TerminalJumpResult {
        let resolution = await Task.detached {
            NotificationTargetResolver.resolve(target)
        }.value
        switch resolution {
        case let .rejected(reason):
            jumpLogger.info("跳转目标无效 pid=\(target.pid) reason=\(reason.rawValue, privacy: .public)")
            return .failure(.targetRejected(reason))
        case let .destination(tty, app):
            let script: String?
            let bundleIdentifier: String
            switch app {
            case .terminal:
                script = TerminalAppBridge.activationScript(tty: tty)
                bundleIdentifier = "com.apple.Terminal"
            case .iTerm2:
                script = ITerm2Bridge.activationScript(tty: tty)
                bundleIdentifier = "com.googlecode.iterm2"
            case .unknown:
                return .failure(.terminalUnknown)
            }
            guard let script else { return .failure(.invalidTTY) }
            guard let terminal = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).first else { return .failure(.appNotRunning) }

            onWillActivate?()
            if #available(macOS 14.0, *) {
                NSApp.yieldActivation(to: terminal)
            } else {
                NSApp.deactivate()
            }
            return await Task.detached {
                TerminalScriptRunner.run(script: script)
            }.value
        }
    }

    @MainActor
    static func presentFailure(_ reason: TerminalJumpFailure) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "无法跳转到终端"
        alert.informativeText = reason.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

/// 只在后台调用，限制外部脚本等待时间，并把执行结果返回给调用者。
enum TerminalScriptRunner {
    static func run(script: String, timeout: TimeInterval = 5) -> TerminalJumpResult {
        let process = Process()
        let pipe = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            jumpLogger.error("跳转脚本启动失败: \(error.localizedDescription, privacy: .public)")
            return .failure(.scriptFailed)
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            jumpLogger.warning("跳转脚本超时")
            return .failure(.timedOut)
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let result = interpret(exitCode: process.terminationStatus, output: output)
        if result != .success {
            jumpLogger.error("跳转脚本失败 exit=\(process.terminationStatus) output=\(output, privacy: .public)")
        }
        return result
    }

    static func interpret(exitCode: Int32, output: String) -> TerminalJumpResult {
        if exitCode != 0 {
            return .failure(output.contains("(-1743)") ? .permissionDenied : .scriptFailed)
        }
        switch output {
        case "ok": return .success
        case "not_found": return .failure(.sessionNotFound)
        default: return .failure(.scriptFailed)
        }
    }
}

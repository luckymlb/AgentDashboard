import Foundation

/// 通知创建时保存的稳定目标身份。tty/terminalApp 只是发送时快照，点击时不可直接信任。
struct NotificationTarget: Sendable, Equatable {
    static let payloadVersion = 1

    let agentId: String
    let pid: Int
    let processStartedAt: Date
    let agentType: AgentType
    let sessionId: String?
    let originalTTY: String
    let originalTerminalApp: TerminalApp
    var codexSocketPath: String? = nil

    init(agent: AgentInfo) {
        agentId = agent.id
        pid = agent.pid
        processStartedAt = agent.processStartedAt
        agentType = agent.type
        sessionId = agent.sessionId
        originalTTY = agent.tty
        originalTerminalApp = agent.terminalApp
        codexSocketPath = agent.codexSocketPath
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let version = userInfo["targetVersion"] as? Int,
              version == Self.payloadVersion,
              let agentId = userInfo["agentId"] as? String,
              let pid = userInfo["pid"] as? Int,
              let startedAt = userInfo["processStartedAt"] as? Double,
              let typeRaw = userInfo["agentType"] as? String,
              let agentType = AgentType(rawValue: typeRaw),
              let tty = userInfo["tty"] as? String,
              let terminalRaw = userInfo["terminalApp"] as? String,
              let terminalApp = TerminalApp(rawValue: terminalRaw) else {
            return nil
        }

        self.agentId = agentId
        self.pid = pid
        processStartedAt = Date(timeIntervalSince1970: startedAt)
        self.agentType = agentType
        sessionId = userInfo["sessionId"] as? String
        originalTTY = tty
        originalTerminalApp = terminalApp
        codexSocketPath = userInfo["codexSocketPath"] as? String
    }

    var userInfo: [AnyHashable: Any] {
        var result: [AnyHashable: Any] = [
            "targetVersion": Self.payloadVersion,
            "agentId": agentId,
            "pid": pid,
            "processStartedAt": processStartedAt.timeIntervalSince1970,
            "agentType": agentType.rawValue,
            "tty": originalTTY,
            "terminalApp": originalTerminalApp.rawValue,
        ]
        if let codexSocketPath { result["codexSocketPath"] = codexSocketPath }
        if let sessionId { result["sessionId"] = sessionId }
        return result
    }
}

struct LiveAgentProcess: Sendable, Equatable {
    let pid: Int
    let processStartedAt: Date
    let agentType: AgentType
    let tty: String
    let terminalApp: TerminalApp
}

enum NotificationTargetRejection: String, Sendable, Equatable {
    case processMissing = "process_missing"
    case pidReused = "pid_reused"
    case agentTypeChanged = "agent_type_changed"
    case ttyMissing = "tty_missing"
    case terminalUnknown = "terminal_unknown"
}

enum NotificationTargetResolution: Sendable, Equatable {
    case destination(tty: String, terminalApp: TerminalApp)
    case rejected(NotificationTargetRejection)
}

/// 点击通知时重新读取进程，验证稳定身份后才返回实时跳转位置。
enum NotificationTargetResolver {
    /// ps 的 etime 只有秒级精度，扫描与点击各自反推启动时间会有少量误差。
    static let processStartTolerance: TimeInterval = 3

    static func resolve(_ target: NotificationTarget) -> NotificationTargetResolution {
        validate(target, liveProcess: readLiveProcess(pid: target.pid))
    }

    static func validate(
        _ target: NotificationTarget,
        liveProcess: LiveAgentProcess?
    ) -> NotificationTargetResolution {
        guard let liveProcess, liveProcess.pid == target.pid else {
            return .rejected(.processMissing)
        }
        guard abs(liveProcess.processStartedAt.timeIntervalSince(target.processStartedAt))
                <= processStartTolerance else {
            return .rejected(.pidReused)
        }
        guard liveProcess.agentType == target.agentType else {
            return .rejected(.agentTypeChanged)
        }
        guard !liveProcess.tty.isEmpty, liveProcess.tty != "??" else {
            return .rejected(.ttyMissing)
        }
        guard liveProcess.terminalApp != .unknown else {
            return .rejected(.terminalUnknown)
        }
        return .destination(tty: liveProcess.tty, terminalApp: liveProcess.terminalApp)
    }

    private static func readLiveProcess(pid: Int) -> LiveAgentProcess? {
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "pid=,tty=,etime=,command=", "-p", "\(pid)"]

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else { return nil }

        return parseProcessLine(
            output.trimmingCharacters(in: .whitespacesAndNewlines),
            now: Date(),
            terminalApp: ProcessScanner.detectTerminal(pid: pid)
        )
    }

    static func parseProcessLine(
        _ line: String,
        now: Date,
        terminalApp: TerminalApp
    ) -> LiveAgentProcess? {
        let parts = line.split(maxSplits: 3, whereSeparator: { $0.isWhitespace })
        guard parts.count == 4,
              let pid = Int(parts[0]) else { return nil }

        let tty = String(parts[1])
        let etime = String(parts[2])
        let command = String(parts[3])
        let syntheticLine = "\(pid) \(tty) S 0.0 \(etime) \(command)"

        let agentType: AgentType
        if ProcessScanner.isClaudeLine(syntheticLine) {
            agentType = .claude
        } else if ProcessScanner.isCodexLine(syntheticLine) {
            agentType = .codex
        } else {
            return nil
        }

        return LiveAgentProcess(
            pid: pid,
            processStartedAt: now.addingTimeInterval(
                -TimeInterval(ProcessScanner.parseEtimeSeconds(etime))
            ),
            agentType: agentType,
            tty: tty,
            terminalApp: terminalApp
        )
    }
}

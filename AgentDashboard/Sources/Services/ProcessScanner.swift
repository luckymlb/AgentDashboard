import Foundation
import Combine

class ProcessScanner: ObservableObject {
    @Published var agents: [AgentInfo] = []

    private let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions")
    private let jobsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/jobs")
    private let transcriptReader = TranscriptTailReader()

    func startScanning(interval: TimeInterval = 2.0) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let results = self.performScan()
            DispatchQueue.main.async { self.agents = results }
        }

        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let results = self.performScan()
                DispatchQueue.main.async { self.agents = results }
            }
        }
    }

    func scan() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let results = self.performScan()
            DispatchQueue.main.async { self.agents = results }
        }
    }

    // MARK: - Core scan logic

    private func performScan() -> [AgentInfo] {
        let terminalProcesses = getTerminalProcesses()

        // Collect all session files to find parent-child relationships
        let allSessions = loadAllSessions()

        var agents: [AgentInfo] = []

        for proc in terminalProcesses {
            let sessionData = allSessions[proc.pid]

            let sessionStatus = sessionData?["status"] as? String
            let sessionId = sessionData?["sessionId"] as? String
            let sessionCwd = sessionData?["cwd"] as? String ?? proc.cwd
            let sessionName = sessionData?["name"] as? String
            let kind = sessionData?["kind"] as? String

            // Skip non-interactive sessions
            if kind != nil && kind != "interactive" { continue }

            // Status resolution priority:
            // 1. session idle → check for active child jobs with same cwd
            // 2. session busy → read transcript for fine-grained status
            // 3. session stale/missing → CPU + child job fallback
            let status: AgentStatus

            if sessionStatus == "busy", let sid = sessionId {
                // Session explicitly busy → read transcript for detail
                status = inferDetailedStatus(sessionId: sid, cwd: sessionCwd)
            } else if sessionStatus == "idle" {
                // Session says idle, but check: is there a busy child with same cwd?
                if let childStatus = findActiveChildJobStatus(cwd: sessionCwd, allSessions: allSessions) {
                    status = childStatus
                } else if proc.cpu > 3 {
                    // CPU is active but session says idle → stale file, try transcript
                    if let sid = sessionId {
                        let inferred = inferDetailedStatus(sessionId: sid, cwd: sessionCwd)
                        status = inferred == .busy ? .busy : inferred
                    } else {
                        status = .busy
                    }
                } else {
                    status = .idle
                }
            } else if sessionStatus == nil {
                // No session file (e.g. Codex) - CPU-based fallback
                status = cpuFallbackStatus(cpu: proc.cpu, stat: proc.stat)
            } else {
                status = .busy
            }

            agents.append(AgentInfo(
                pid: proc.pid,
                type: proc.type,
                tty: proc.tty,
                workingDirectory: sessionCwd,
                elapsedTime: proc.etime,
                status: status,
                sessionName: sessionName,
                sessionId: sessionId
            ))
        }

        return agents.sorted { $0.status < $1.status }
    }

    // MARK: - Load all sessions for cross-referencing

    private func loadAllSessions() -> [Int: [String: Any]] {
        var result: [Int: [String: Any]] = [:]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil
        ) else { return result }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = json["pid"] as? Int else { continue }
            result[pid] = json
        }
        return result
    }

    // MARK: - Find active child job for a given cwd

    private func findActiveChildJobStatus(cwd: String, allSessions: [Int: [String: Any]]) -> AgentStatus? {
        // Look for bg sessions with same cwd that are busy
        for (_, session) in allSessions {
            guard let kind = session["kind"] as? String, kind == "bg",
                  let childCwd = session["cwd"] as? String, childCwd == cwd,
                  let childStatus = session["status"] as? String, childStatus == "busy",
                  let childSessionId = session["sessionId"] as? String else { continue }

            // Found a busy child → prefer transcript (more up-to-date than state.json)
            let transcriptStatus = inferDetailedStatus(sessionId: childSessionId, cwd: childCwd)
            if transcriptStatus != .busy {
                return transcriptStatus
            }

            // Fallback to job state.json
            if let jobId = session["jobId"] as? String,
               let jobStatus = readJobState(jobId: jobId) {
                return jobStatus
            }
            return .busy
        }
        return nil
    }

    // MARK: - Read job state file for fine-grained status

    private func readJobState(jobId: String) -> AgentStatus? {
        let stateFile = jobsDir.appendingPathComponent("\(jobId)/state.json")
        guard let data = try? Data(contentsOf: stateFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let state = json["state"] as? String
        let tempo = json["tempo"] as? String

        // Job state values: "running", "blocked", "completed", "failed"
        switch state {
        case "running":
            if tempo == "thinking" { return .thinking }
            if tempo == "active" { return .running }
            return .busy
        case "blocked":
            // Blocked = waiting for user input
            return .waiting
        case "completed", "failed":
            return .idle
        default:
            if tempo == "active" { return .busy }
            return nil
        }
    }

    // MARK: - Fine-grained status from transcript

    private func inferDetailedStatus(sessionId: String, cwd: String) -> AgentStatus {
        guard let transcriptPath = transcriptReader.findTranscriptPath(
            sessionId: sessionId, cwd: cwd
        ) else {
            return .busy
        }

        return transcriptReader.inferActivity(transcriptPath: transcriptPath) ?? .busy
    }

    // MARK: - CPU fallback for processes without session files

    private func cpuFallbackStatus(cpu: Double, stat: String) -> AgentStatus {
        if stat.contains("R") || cpu > 20 {
            return .running
        } else if cpu > 2 {
            return .busy
        } else {
            return .idle
        }
    }

    // MARK: - Process scanning

    private struct TerminalProcess {
        let pid: Int
        let tty: String
        let stat: String
        let cpu: Double
        let etime: String
        let type: AgentType
        let cwd: String
    }

    private func getTerminalProcesses() -> [TerminalProcess] {
        let process = Process()
        let pipe = Pipe()

        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "pid,tty,stat,%cpu,etime,command", "-ax"]

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let psOutput = String(data: data, encoding: .utf8) ?? ""
        let lines = psOutput.components(separatedBy: "\n")
        var results: [TerminalProcess] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let agentType: AgentType?
            if isClaudeLine(trimmed) {
                agentType = .claude
            } else if isCodexLine(trimmed) {
                agentType = .codex
            } else {
                continue
            }

            guard let type = agentType else { continue }

            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 6,
                  let pid = Int(parts[0]) else { continue }

            let tty = parts[1]
            if tty == "??" || tty.isEmpty { continue }

            let stat = parts[2]
            let cpu = Double(parts[3]) ?? 0.0
            let etime = parts[4]

            let cwd = getWorkingDirectory(pid: pid)

            results.append(TerminalProcess(
                pid: pid, tty: tty, stat: stat, cpu: cpu,
                etime: formatElapsedTime(etime), type: type,
                cwd: cwd.isEmpty ? "unknown" : cwd
            ))
        }

        return results
    }

    private func isClaudeLine(_ line: String) -> Bool {
        let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 6 else { return false }
        let command = parts[5...].joined(separator: " ")
        return (command == "claude" || command.hasPrefix("claude "))
            && !command.contains("--output-format stream-json")
            && !command.contains("bypassPermissions")
    }

    private func isCodexLine(_ line: String) -> Bool {
        let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 6 else { return false }
        let command = parts[5...].joined(separator: " ")
        return command.hasPrefix("node") && command.contains("/codex")
            && !command.contains("app-server") && !command.contains("node_repl")
            && !command.contains("ccb-agent-sidebar")
            && !command.contains("dangerously-bypass-hook-trust")
    }

    private func getWorkingDirectory(pid: Int) -> String {
        let process = Process()
        let pipe = Pipe()

        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]

        do {
            try process.run()
        } catch {
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("n/") {
                return String(line.dropFirst())
            }
        }
        return ""
    }

    // MARK: - Time formatting

    private func formatElapsedTime(_ etime: String) -> String {
        let parts = etime.split(separator: "-")
        if parts.count == 2 {
            return "\(parts[0])d \(formatHMS(String(parts[1])))"
        }
        return formatHMS(etime)
    }

    private func formatHMS(_ hms: String) -> String {
        let parts = hms.split(separator: ":")
        switch parts.count {
        case 3:
            return "\(parts[0])h \(parts[1])m"
        case 2:
            let min = Int(parts[0]) ?? 0
            if min >= 60 {
                return "\(min / 60)h \(min % 60)m"
            }
            return "\(parts[0])m \(parts[1])s"
        default:
            return hms
        }
    }
}

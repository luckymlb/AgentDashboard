import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.lucky.AgentDashboard", category: "ProcessScanner")

@MainActor
class ProcessScanner: ObservableObject {
    @Published var agents: [AgentInfo] = []

    private let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions")
    private let jobsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/jobs")
    private let transcriptReader = TranscriptTailReader()

    private let hookServer = HookServer()
    private let hookListener = HookListener()

    private var scanTimer: Timer?
    private var isScanning = false
    private var pollingInterval: TimeInterval = 10.0

    // cwd cache: pid -> (cwd, timestamp)
    private var cwdCache: [Int: (path: String, time: Date)] = [:]
    private let cwdCacheTTL: TimeInterval = 30

    enum PollingMode {
        case active      // popover visible, 2s
        case background  // popover hidden, 10s (hooks provide real-time updates)
    }

    func setPollingMode(_ mode: PollingMode) {
        let newInterval: TimeInterval = mode == .active ? 2.0 : 10.0
        guard newInterval != pollingInterval else { return }
        pollingInterval = newInterval
        startScanning(interval: newInterval)
    }

    func startScanning(interval: TimeInterval = 10.0) {
        scanTimer?.invalidate()
        pollingInterval = interval

        hookServer.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.hookListener.handleEvent(event)
                self?.scan()
            }
        }
        hookServer.start()

        scan()

        scanTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.hookListener.clearStaleEntries()
                self?.scan()
            }
        }
    }

    func stopScanning() {
        scanTimer?.invalidate()
        scanTimer = nil
        hookServer.stop()
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true

        let cachedCwd = cwdCache
        let cacheTTL = cwdCacheTTL
        let reader = transcriptReader
        let sessDir = sessionsDir
        let jDir = jobsDir
        let hookStatusSnapshot = hookListener.snapshot()

        Task.detached { [weak self] in
            let results = ProcessScanner.performScan(
                cwdCache: cachedCwd, cacheTTL: cacheTTL,
                transcriptReader: reader, sessionsDir: sessDir, jobsDir: jDir,
                hookStatuses: hookStatusSnapshot
            )
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.agents = results.agents
                self.cwdCache = results.updatedCwdCache
                self.isScanning = false
            }
        }
    }

    deinit {
        scanTimer?.invalidate()
    }

    // MARK: - Core scan logic (nonisolated, runs off main actor)

    private struct ScanResult: Sendable {
        let agents: [AgentInfo]
        let updatedCwdCache: [Int: (path: String, time: Date)]
    }

    private nonisolated static func performScan(
        cwdCache: [Int: (path: String, time: Date)],
        cacheTTL: TimeInterval,
        transcriptReader: TranscriptTailReader,
        sessionsDir: URL,
        jobsDir: URL,
        hookStatuses: [String: AgentStatus]
    ) -> ScanResult {
        let terminalProcesses = getTerminalProcesses(cwdCache: cwdCache, cacheTTL: cacheTTL)
        let allSessions = loadAllSessions(sessionsDir: sessionsDir)

        var agents: [AgentInfo] = []
        var newCwdCache = cwdCache

        for proc in terminalProcesses.processes {
            newCwdCache[proc.pid] = (proc.cwd, Date())

            let sessionData = allSessions[proc.pid]

            let sessionStatus = sessionData?["status"] as? String
            let sessionId = sessionData?["sessionId"] as? String
            let sessionCwd = sessionData?["cwd"] as? String ?? proc.cwd
            let sessionName = sessionData?["name"] as? String
            let kind = sessionData?["kind"] as? String
            let updatedAt = sessionData?["updatedAt"] as? Double ?? 0

            if kind != nil && kind != "interactive" { continue }

            let status: AgentStatus

            if let sid = sessionId, let hookStatus = hookStatuses[sid] {
                status = hookStatus
            } else if sessionStatus == "busy", let sid = sessionId {
                status = inferDetailedStatus(sessionId: sid, cwd: sessionCwd, transcriptReader: transcriptReader)
            } else if sessionStatus == "idle" {
                if let childStatus = findActiveChildJobStatus(
                    cwd: sessionCwd, parentPid: proc.pid, allSessions: allSessions,
                    transcriptReader: transcriptReader, jobsDir: jobsDir
                ) {
                    status = childStatus
                } else if proc.cpu > 3 {
                    if let sid = sessionId {
                        let inferred = inferDetailedStatus(sessionId: sid, cwd: sessionCwd, transcriptReader: transcriptReader)
                        status = inferred == .busy ? .busy : inferred
                    } else {
                        status = .busy
                    }
                } else {
                    status = .idle
                }
            } else if sessionStatus == nil {
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
                sessionId: sessionId,
                lastActiveAt: updatedAt
            ))
        }

        let now = Date()
        let livePids = Set(terminalProcesses.processes.map(\.pid))
        for (pid, entry) in newCwdCache {
            if !livePids.contains(pid) && now.timeIntervalSince(entry.time) > cacheTTL * 3 {
                newCwdCache.removeValue(forKey: pid)
            }
        }

        return ScanResult(
            agents: agents.sorted {
                if $0.status.sortPriority != $1.status.sortPriority {
                    return $0.status.sortPriority < $1.status.sortPriority
                }
                if !$0.status.isActive {
                    return $0.lastActiveAt > $1.lastActiveAt
                }
                return $0.elapsedSeconds < $1.elapsedSeconds
            },
            updatedCwdCache: newCwdCache
        )
    }

    // MARK: - Load all sessions for cross-referencing

    private nonisolated static func loadAllSessions(sessionsDir: URL) -> [Int: [String: Any]] {
        var result: [Int: [String: Any]] = [:]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            logger.warning("Cannot read sessions directory")
            return result
        }

        let now = Date()

        for file in files where file.pathExtension == "json" {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let mtime = attrs[.modificationDate] as? Date,
               now.timeIntervalSince(mtime) > 7 * 86400 {
                continue
            }

            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = json["pid"] as? Int else { continue }
            result[pid] = json
        }
        return result
    }

    // MARK: - Find active child job for a given cwd

    private nonisolated static func findActiveChildJobStatus(
        cwd: String, parentPid: Int, allSessions: [Int: [String: Any]],
        transcriptReader: TranscriptTailReader, jobsDir: URL
    ) -> AgentStatus? {
        for (childPid, session) in allSessions {
            guard childPid != parentPid,
                  let kind = session["kind"] as? String, kind == "bg",
                  let childCwd = session["cwd"] as? String, childCwd == cwd,
                  let childStatus = session["status"] as? String, childStatus == "busy",
                  let childSessionId = session["sessionId"] as? String else { continue }

            if let parentSessionId = session["parentSessionId"] as? String {
                let parentSession = allSessions[parentPid]
                let parentSid = parentSession?["sessionId"] as? String
                if parentSid != nil && parentSid != parentSessionId {
                    continue
                }
            }

            let transcriptStatus = inferDetailedStatus(sessionId: childSessionId, cwd: childCwd, transcriptReader: transcriptReader)
            if transcriptStatus != .busy {
                return transcriptStatus
            }

            if let jobId = session["jobId"] as? String,
               let jobStatus = readJobState(jobId: jobId, jobsDir: jobsDir) {
                return jobStatus
            }
            return .busy
        }
        return nil
    }

    // MARK: - Read job state file

    private nonisolated static func readJobState(jobId: String, jobsDir: URL) -> AgentStatus? {
        let stateFile = jobsDir.appendingPathComponent("\(jobId)/state.json")
        guard let data = try? Data(contentsOf: stateFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let state = json["state"] as? String
        let tempo = json["tempo"] as? String

        switch state {
        case "running":
            if tempo == "thinking" { return .thinking }
            if tempo == "active" { return .running }
            return .busy
        case "blocked":
            return .waiting
        case "completed", "failed":
            return .idle
        default:
            if tempo == "active" { return .busy }
            return nil
        }
    }

    // MARK: - Fine-grained status from transcript

    private nonisolated static func inferDetailedStatus(sessionId: String, cwd: String, transcriptReader: TranscriptTailReader) -> AgentStatus {
        guard let transcriptPath = transcriptReader.findTranscriptPath(
            sessionId: sessionId, cwd: cwd
        ) else {
            return .busy
        }

        return transcriptReader.inferActivity(transcriptPath: transcriptPath) ?? .busy
    }

    // MARK: - CPU fallback

    private nonisolated static func cpuFallbackStatus(cpu: Double, stat: String) -> AgentStatus {
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

    private struct ProcessScanOutput {
        let processes: [TerminalProcess]
    }

    private nonisolated static func getTerminalProcesses(cwdCache: [Int: (path: String, time: Date)], cacheTTL: TimeInterval) -> ProcessScanOutput {
        let process = Process()
        let pipe = Pipe()

        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "pid,tty,stat,%cpu,etime,command", "-ax"]

        do {
            try process.run()
        } catch {
            logger.error("Failed to run ps: \(error.localizedDescription)")
            return ProcessScanOutput(processes: [])
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let psOutput = String(data: data, encoding: .utf8) ?? ""
        let lines = psOutput.components(separatedBy: "\n")
        var results: [TerminalProcess] = []
        let now = Date()

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

            let cwd: String
            if let cached = cwdCache[pid], now.timeIntervalSince(cached.time) < cacheTTL {
                cwd = cached.path
            } else {
                cwd = getWorkingDirectory(pid: pid)
            }

            results.append(TerminalProcess(
                pid: pid, tty: tty, stat: stat, cpu: cpu,
                etime: formatElapsedTime(etime), type: type,
                cwd: cwd.isEmpty ? "unknown" : cwd
            ))
        }

        return ProcessScanOutput(processes: results)
    }

    private nonisolated static func isClaudeLine(_ line: String) -> Bool {
        let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 6 else { return false }
        let command = parts[5...].joined(separator: " ")
        return (command == "claude" || command.hasPrefix("claude "))
            && !command.contains("--output-format stream-json")
            && !command.contains("bypassPermissions")
    }

    private nonisolated static func isCodexLine(_ line: String) -> Bool {
        let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 6 else { return false }
        let command = parts[5...].joined(separator: " ")
        return command.hasPrefix("node") && command.contains("/codex")
            && !command.contains("app-server") && !command.contains("node_repl")
            && !command.contains("ccb-agent-sidebar")
            && !command.contains("dangerously-bypass-hook-trust")
    }

    private nonisolated static func getWorkingDirectory(pid: Int) -> String {
        let process = Process()
        let pipe = Pipe()

        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]

        do {
            try process.run()
        } catch {
            logger.debug("lsof failed for pid \(pid)")
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

    private nonisolated static func formatElapsedTime(_ etime: String) -> String {
        let parts = etime.split(separator: "-")
        if parts.count == 2 {
            let days = Int(parts[0]) ?? 0
            return "\(days)d \(formatHMS(String(parts[1])))"
        }
        return formatHMS(etime)
    }

    private nonisolated static func formatHMS(_ hms: String) -> String {
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

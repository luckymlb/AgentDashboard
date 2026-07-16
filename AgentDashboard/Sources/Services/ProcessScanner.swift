import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.lucky.AgentDashboard", category: "ProcessScanner")

@MainActor
class ProcessScanner: ObservableObject {
    @Published var agents: [AgentInfo] = []
    @Published private(set) var unreadSessionIds: Set<String> = []

    private let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions")
    private let jobsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/jobs")
    private let transcriptReader = TranscriptTailReader()
    private let tokenStatsReader = TokenStatsReader()
    private let codexReader = CodexTranscriptReader()

    private let hookServer = HookServer()
    private let hookListener = HookListener()
    private let notificationManager = NotificationManager()
    /// 上一轮 scan 的 explicit confirming session 集，用于检测 Claude 权限请求的进入。
    private var lastExplicitConfirming: Set<String> = []

    private var scanTimer: Timer?
    private var isScanning = false
    private var needsRescan = false
    private var scanRevisionGate = ScanRevisionGate()
    private var pollingInterval: TimeInterval = 10.0

    // cwd cache: pid -> (cwd, timestamp)
    private var cwdCache: [Int: (path: String, time: Date)] = [:]
    private let cwdCacheTTL: TimeInterval = 30

    // terminal app cache: pid -> host terminal. Stable for a pid's lifetime,
    // so no TTL — entries are dropped when the pid disappears from the scan.
    private var terminalAppCache: [Int: TerminalApp] = [:]

    // codex session rollout path cache: pid -> sessionPath. 进程存活期间 session 文件不变,
    // 所以无 TTL;pid 消失时在下轮扫描清理(同 terminalAppCache)。
    private var codexSessionCache: [Int: String] = [:]

    /// 启动系统通知(授权请求 + 注册点击回调)。AppDelegate 启动时调一次。
    func startNotifications() {
        notificationManager.start()
    }

    func markAsRead(sessionId: String?) {
        guard let sid = sessionId else { return }
        unreadSessionIds.remove(sid)
        if let idx = agents.firstIndex(where: { $0.sessionId == sid && $0.hasUnread }) {
            agents[idx] = agents[idx].withHasUnread(false)
        }
    }

    enum PollingMode {
        case active      // popover visible, 2s
        case background  // popover hidden, 10s (hooks provide real-time updates)
    }

    func setPollingMode(_ mode: PollingMode) {
        let newInterval: TimeInterval = mode == .active ? 2.0 : 10.0
        guard newInterval != pollingInterval else { return }
        pollingInterval = newInterval
        scan()
        scheduleScanTimer(interval: newInterval)
    }

    func startScanning(interval: TimeInterval = 10.0) {
        pollingInterval = interval

        hookServer.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hookListener.handleEvent(event)
                self.scan()
            }
        }
        hookServer.start()

        scan()

        scheduleScanTimer(interval: interval)
    }

    private func scheduleScanTimer(interval: TimeInterval) {
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hookListener.clearStaleEntries()
                self.scan()
            }
        }
    }

    func stopScanning() {
        scanTimer?.invalidate()
        scanTimer = nil
        hookServer.stop()
    }

    func scan() {
        scanRevisionGate.registerRequest()
        guard !isScanning else {
            needsRescan = true
            return
        }
        launchScan()
    }

    /// Starts one scan for the latest requested revision. New scan requests may arrive while
    /// detached work is running; their revision invalidates this result before any UI,
    /// unread, notification, or cache side effect is applied.
    private func launchScan() {
        guard !isScanning else { return }
        isScanning = true
        needsRescan = false
        let scanRevision = scanRevisionGate.current

        let cachedCwd = cwdCache
        let cacheTTL = cwdCacheTTL
        let cachedTerminalApp = terminalAppCache
        let cachedCodexSession = codexSessionCache
        let reader = transcriptReader
        let tokenStats = tokenStatsReader
        let codexRdr = codexReader
        let sessDir = sessionsDir
        let jDir = jobsDir
        let hookStatusSnapshot = hookListener.snapshot()
        let explicitConfirming = hookListener.explicitConfirmingSnapshot()
        let turnStarts = hookListener.turnStartSnapshot()
        let lastEvents = hookListener.lastEventSnapshot()

        Task.detached { [weak self] in
            let results = ProcessScanner.performScan(
                cwdCache: cachedCwd, cacheTTL: cacheTTL,
                terminalAppCache: cachedTerminalApp,
                transcriptReader: reader, sessionsDir: sessDir, jobsDir: jDir,
                hookStatuses: hookStatusSnapshot, turnStarts: turnStarts,
                lastHookEvents: lastEvents,
                tokenStatsReader: tokenStats,
                codexReader: codexRdr, codexSessionCache: cachedCodexSession
            )
            await MainActor.run { [weak self] in
                guard let self = self else { return }

                guard self.scanRevisionGate.accepts(scanRevision) else {
                    logger.debug("Discard stale scan revision=\(scanRevision) latest=\(self.scanRevisionGate.current)")
                    self.isScanning = false
                    self.needsRescan = false
                    self.launchScan()
                    return
                }

                let oldBySessionId = Dictionary(
                    self.agents.compactMap { agent in
                        agent.sessionId.map { ($0, agent) }
                    },
                    uniquingKeysWith: { current, _ in current }
                )
                let justCompleted = Set(results.agents.compactMap { newAgent -> String? in
                    guard let sid = newAgent.sessionId,
                          let oldAgent = oldBySessionId[sid],
                          Self.shouldMarkUnreadCompletion(
                            oldAgent: oldAgent, newAgent: newAgent
                          ) else { return nil }
                    return sid
                })
                self.unreadSessionIds.formUnion(justCompleted)

                // 未读是主线程上的交互状态，不能采用扫描开始时的旧快照；否则用户在
                // 扫描期间点击已读，旧结果完成后会把蓝点重新覆盖回来。
                let newAgents = Self.sortAgents(results.agents.map { agent in
                    agent.withHasUnread(
                        agent.sessionId.map(self.unreadSessionIds.contains) ?? false
                    )
                })

                // 通知 diff:第一性——只认"真·等授权"信号:
                //   codex 经审批策略+execpolicy 证明会等待用户的命令/交互工具，
                //   claude PermissionRequest/permission_prompt/AskUserQuestion。
                //   claude 的 PreToolUse 超时降级是推测,不通知(只用于菜单栏图标快速提示)。
                let oldById = Dictionary(self.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let newIds = Set(newAgents.map { $0.id })

                // 进程退出:清理通知状态与已发横幅
                for oldAgent in self.agents where !newIds.contains(oldAgent.id) {
                    self.notificationManager.purge(agentId: oldAgent.id)
                }
                for newAgent in newAgents {
                    guard let oldAgent = oldById[newAgent.id] else { continue }   // 新 agent,不通知
                    let old = oldAgent.status
                    let nw = newAgent.status
                    // codex confirming 进入 = 真实等待用户审批或用户交互工具。
                    // claude 走 explicit 集(下面)。
                    if old != .confirming && nw == .confirming && newAgent.type == .codex {
                        self.notificationManager.notify(agent: newAgent, kind: .needsConfirmation)
                    }
                    // confirming 离开(不管来源):清横幅
                    if old == .confirming && nw != .confirming {
                        self.notificationManager.clearConfirming(agentId: newAgent.id)
                    }
                    if Self.shouldNotifyCompletion(oldAgent: oldAgent, newAgent: newAgent) {
                        self.notificationManager.notify(agent: newAgent, kind: .completed)
                    }
                }
                // Claude 真 confirming：Hook 明确信号或 transcript 中未完成的
                // AskUserQuestion 都可进入。后者保证 App 在等待期间重启也能恢复通知。
                let enteredExplicit = explicitConfirming.subtracting(self.lastExplicitConfirming)
                self.lastExplicitConfirming = explicitConfirming
                let previousClaudeConfirming = Set(self.agents.compactMap { agent in
                    agent.type == .claude && agent.status == .confirming ? agent.sessionId : nil
                })
                let currentClaudeConfirming = Set(newAgents.compactMap { agent in
                    agent.type == .claude && agent.status == .confirming ? agent.sessionId : nil
                })
                let enteredClaudeConfirming = currentClaudeConfirming.subtracting(previousClaudeConfirming)
                for sid in enteredExplicit.union(enteredClaudeConfirming) {
                    if let agent = newAgents.first(where: { $0.sessionId == sid && $0.type == .claude && $0.status == .confirming }) {
                        self.notificationManager.notify(agent: agent, kind: .needsConfirmation)
                    }
                }

                self.agents = newAgents
                logger.debug("SCAN agents=\(newAgents.count) :: \(newAgents.map { "\($0.type.rawValue)#\($0.pid)[\($0.status.label)]" }.joined(separator: " "), privacy: .public)")
                self.cwdCache = results.updatedCwdCache
                self.terminalAppCache = results.updatedTerminalAppCache
                self.codexSessionCache = results.updatedCodexSessionCache
                self.tokenStatsReader.prune(keeping: results.usedTranscriptPaths)
                self.isScanning = false
                if self.needsRescan {
                    self.needsRescan = false
                    self.launchScan()
                }
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
        let updatedTerminalAppCache: [Int: TerminalApp]
        let updatedCodexSessionCache: [Int: String]
        let usedTranscriptPaths: Set<String>
    }

    private nonisolated static func performScan(
        cwdCache: [Int: (path: String, time: Date)],
        cacheTTL: TimeInterval,
        terminalAppCache: [Int: TerminalApp],
        transcriptReader: TranscriptTailReader,
        sessionsDir: URL,
        jobsDir: URL,
        hookStatuses: [String: AgentStatus],
        turnStarts: [String: Date],
        lastHookEvents: [String: Date],
        tokenStatsReader: TokenStatsReader,
        codexReader: CodexTranscriptReader,
        codexSessionCache: [Int: String]
    ) -> ScanResult {
        let terminalProcesses = getTerminalProcesses(
            cwdCache: cwdCache, cacheTTL: cacheTTL, terminalAppCache: terminalAppCache
        )
        let allSessions = loadAllSessions(sessionsDir: sessionsDir)

        var agents: [AgentInfo] = []
        var usedTranscriptPaths: Set<String> = []
        var newCwdCache = cwdCache
        var newCodexSessionCache = codexSessionCache
        var assignedCodexSessionPaths: Set<String> = []

        for proc in terminalProcesses.processes {
            newCwdCache[proc.pid] = (proc.cwd, Date())

            // codex 不读 claude sessionData:codex 不写 ~/.claude/sessions,且 pid 复用会让
            // allSessions[pid] 命中残留 claude session,污染 sessionCwd / kind → findSessionPath 失配。
            let sessionData = proc.type == .codex ? nil : allSessions[proc.pid]

            let sessionStatus = sessionData?["status"] as? String
            var sessionId = sessionData?["sessionId"] as? String
            let sessionCwd = sessionData?["cwd"] as? String ?? proc.cwd
            let sessionName = sessionData?["name"] as? String
            let kind = sessionData?["kind"] as? String
            let updatedAt = sessionData?["updatedAt"] as? Double ?? 0

            if kind != nil && kind != "interactive" { continue }

            // codex:解析 session rollout 文件,拿到 状态 / token / 轮起始时间。
            // 路径走 pid 缓存(进程存活期间不变);缓存未命中则按 cwd 在「今天」目录查找。
            var codexState: CodexTranscriptReader.CodexState?
            var codexSessionPath: String?
            if proc.type == .codex {
                if let cached = newCodexSessionCache[proc.pid],
                   FileManager.default.fileExists(atPath: cached),
                   !assignedCodexSessionPaths.contains(cached) {
                    codexSessionPath = cached
                } else {
                    newCodexSessionCache.removeValue(forKey: proc.pid)
                    codexSessionPath = codexReader.findSessionPath(
                        cwd: sessionCwd,
                        processStartedAt: proc.startedAt,
                        excluding: assignedCodexSessionPaths
                    )
                    if let codexSessionPath { newCodexSessionCache[proc.pid] = codexSessionPath }
                }
                if let p = codexSessionPath {
                    assignedCodexSessionPaths.insert(p)
                    codexState = codexReader.readState(transcriptPath: p)
                    sessionId = codexState?.sessionId
                }
            }

            let status: AgentStatus

            if let sid = sessionId, let hookStatus = hookStatuses[sid] {
                status = hookStatus
            } else if let codexStatus = codexState?.status {
                status = codexStatus
            } else if sessionStatus == "busy", let sid = sessionId {
                status = inferDetailedStatus(sessionId: sid, cwd: sessionCwd, transcriptReader: transcriptReader)
            } else if sessionStatus == "idle" {
                if let childStatus = findActiveChildJobStatus(
                    cwd: sessionCwd, parentPid: proc.pid, allSessions: allSessions,
                    transcriptReader: transcriptReader, jobsDir: jobsDir
                ) {
                    status = childStatus
                } else {
                    status = .idle
                }
            } else if proc.type == .codex {
                // codex 进程在但 session 暂时读不到(启动初期/文件未就绪):
                // 视为等待输入,优于 CPU 兜底(初始化 CPU 高易误判 Running)。
                status = .idle
            } else if sessionStatus == nil {
                status = cpuFallbackStatus(cpu: proc.cpu, stat: proc.stat)
            } else {
                status = .busy
            }

            let elapsedTime: String
            if status.isActive, let turnStart = (sessionId.flatMap { turnStarts[$0] }) ?? codexState?.turnStart {
                let seconds = Int(Date().timeIntervalSince(turnStart))
                elapsedTime = formatSeconds(max(0, seconds))
            } else if status.isActive {
                elapsedTime = proc.etime.isEmpty ? "" : proc.etime
            } else {
                elapsedTime = ""
            }

            var lastActive: Double
            if let sid = sessionId, let hookTime = lastHookEvents[sid] {
                lastActive = hookTime.timeIntervalSince1970 * 1000
            } else if let sid = sessionId,
               let transcriptPath = transcriptReader.findTranscriptPath(sessionId: sid, cwd: sessionCwd),
               let attrs = try? FileManager.default.attributesOfItem(atPath: transcriptPath),
               let mtime = attrs[.modificationDate] as? Date {
                lastActive = mtime.timeIntervalSince1970 * 1000
            } else if let codexPath = codexSessionPath,
               let attrs = try? FileManager.default.attributesOfItem(atPath: codexPath),
               let mtime = attrs[.modificationDate] as? Date {
                // codex:用 session rollout 文件 mtime 作为最近活动时间(同 claude transcript mtime)。
                // 同时驱动 idle 时的 "Xs ago" 显示与按最近活动排序。
                lastActive = mtime.timeIntervalSince1970 * 1000
            } else {
                let sessionFile = sessionsDir.appendingPathComponent("\(proc.pid).json")
                if let attrs = try? FileManager.default.attributesOfItem(atPath: sessionFile.path),
                   let mtime = attrs[.modificationDate] as? Date {
                    lastActive = mtime.timeIntervalSince1970 * 1000
                } else if updatedAt > 0 {
                    lastActive = updatedAt
                } else if proc.type == .codex {
                    // codex 无 claude sessionFile:用进程启动时间兜底,
                    // 保证 idle 时 "Xs ago" 有值(否则 lastActive=0 不渲染)。
                    lastActive = proc.startedAt.timeIntervalSince1970 * 1000
                } else {
                    lastActive = 0
                }
            }

            let childLastActive = latestChildActivity(
                parentPid: proc.pid, parentCwd: sessionCwd,
                allSessions: allSessions, transcriptReader: transcriptReader
            )
            if childLastActive > lastActive {
                lastActive = childLastActive
            }

            let tokenUsage: TokenUsage?
            if proc.type == .claude, let sid = sessionId,
               let transcriptPath = transcriptReader.findTranscriptPath(sessionId: sid, cwd: sessionCwd) {
                tokenUsage = tokenStatsReader.accumulate(transcriptPath: transcriptPath)
                usedTranscriptPaths.insert(transcriptPath)
            } else if proc.type == .codex {
                tokenUsage = codexState?.tokenUsage
            } else {
                tokenUsage = nil
            }

            agents.append(AgentInfo(
                pid: proc.pid,
                processStartedAt: proc.startedAt,
                type: proc.type,
                tty: proc.tty,
                workingDirectory: sessionCwd,
                elapsedTime: elapsedTime,
                status: status,
                sessionName: sessionName,
                sessionId: sessionId,
                lastActiveAt: lastActive,
                hasUnread: false,
                terminalApp: proc.terminalApp,
                turnOutcome: codexState?.turnOutcome,
                tokenUsage: tokenUsage
            ))
        }

        let now = Date()
        let livePids = Set(terminalProcesses.processes.map(\.pid))
        for (pid, entry) in newCwdCache {
            if !livePids.contains(pid) && now.timeIntervalSince(entry.time) > cacheTTL * 3 {
                newCwdCache.removeValue(forKey: pid)
            }
        }

        let newTerminalAppCache = terminalProcesses.terminalAppCache.filter { livePids.contains($0.key) }
        // codex session 缓存同 terminalAppCache:pid 消失即清理。
        let prunedCodexSessionCache = newCodexSessionCache.filter { livePids.contains($0.key) }

        return ScanResult(
            agents: sortAgents(agents),
            updatedCwdCache: newCwdCache,
            updatedTerminalAppCache: newTerminalAppCache,
            updatedCodexSessionCache: prunedCodexSessionCache,
            usedTranscriptPaths: usedTranscriptPaths
        )
    }

    private nonisolated static func sortAgents(_ agents: [AgentInfo]) -> [AgentInfo] {
        agents.sorted {
            if $0.status.sortPriority != $1.status.sortPriority {
                return $0.status.sortPriority < $1.status.sortPriority
            }
            if !$0.status.isActive {
                if $0.hasUnread != $1.hasUnread {
                    return $0.hasUnread
                }
                return $0.lastActiveAt > $1.lastActiveAt
            }
            return $0.elapsedSeconds < $1.elapsedSeconds
        }
    }

    // MARK: - Latest child job activity

    private nonisolated static func latestChildActivity(
        parentPid: Int, parentCwd: String,
        allSessions: [Int: [String: Any]], transcriptReader: TranscriptTailReader
    ) -> Double {
        var latest: Double = 0
        for (childPid, session) in allSessions {
            guard childPid != parentPid,
                  let kind = session["kind"] as? String, kind == "bg",
                  let childCwd = session["cwd"] as? String, childCwd == parentCwd,
                  let childSessionId = session["sessionId"] as? String else { continue }

            if let path = transcriptReader.findTranscriptPath(sessionId: childSessionId, cwd: childCwd),
               let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let mtime = attrs[.modificationDate] as? Date {
                let ms = mtime.timeIntervalSince1970 * 1000
                if ms > latest { latest = ms }
            } else if let ua = session["updatedAt"] as? Double, ua > latest {
                latest = ua
            }
        }
        return latest
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

    /// 只有正常结束才发送完成通知。Codex 中断也会产生 Active → Idle，
    /// 但它不是任务完成，必须在通知层明确排除。
    nonisolated static func shouldNotifyCompletion(oldAgent: AgentInfo, newAgent: AgentInfo) -> Bool {
        oldAgent.status.isActive
            && !newAgent.status.isActive
            && oldAgent.elapsedSeconds > 30
            && newAgent.turnOutcome != .aborted
    }

    /// 蓝点表示“这一会话有一轮正常完成且用户尚未查看”。Claude 没有 turnOutcome，
    /// 继续使用 Active → Idle；Codex 必须看到 task_complete，排除 Ctrl+C 的 aborted。
    nonisolated static func shouldMarkUnreadCompletion(
        oldAgent: AgentInfo, newAgent: AgentInfo
    ) -> Bool {
        guard let oldSessionId = oldAgent.sessionId,
              oldSessionId == newAgent.sessionId,
              oldAgent.type == newAgent.type,
              oldAgent.status.isActive,
              !newAgent.status.isActive else { return false }

        switch newAgent.type {
        case .claude:
            return true
        case .codex:
            return newAgent.turnOutcome == .completed
        }
    }

    nonisolated static func cpuFallbackStatus(cpu: Double, stat: String) -> AgentStatus {
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
        /// 进程启动时间(由 ps etime 反推);codex 无 session 文件时兜底 lastActive。
        let startedAt: Date
        let type: AgentType
        let cwd: String
        let terminalApp: TerminalApp
    }

    private struct ProcessScanOutput {
        let processes: [TerminalProcess]
        let terminalAppCache: [Int: TerminalApp]
    }

    private nonisolated static func getTerminalProcesses(
        cwdCache: [Int: (path: String, time: Date)],
        cacheTTL: TimeInterval,
        terminalAppCache: [Int: TerminalApp]
    ) -> ProcessScanOutput {
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
            return ProcessScanOutput(processes: [], terminalAppCache: terminalAppCache)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let psOutput = String(data: data, encoding: .utf8) ?? ""
        let lines = psOutput.components(separatedBy: "\n")
        var results: [TerminalProcess] = []
        var newTerminalAppCache = terminalAppCache
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
            let startedAt = Date().addingTimeInterval(TimeInterval(-Self.parseEtimeSeconds(etime)))

            let cwd: String
            if let cached = cwdCache[pid], now.timeIntervalSince(cached.time) < cacheTTL {
                cwd = cached.path
            } else {
                cwd = getWorkingDirectory(pid: pid)
            }

            // Terminal app is stable for a pid's lifetime — detect once, then reuse.
            let terminalApp: TerminalApp
            if let cached = newTerminalAppCache[pid] {
                terminalApp = cached
            } else {
                terminalApp = detectTerminal(pid: pid)
                newTerminalAppCache[pid] = terminalApp
            }

            results.append(TerminalProcess(
                pid: pid, tty: tty, stat: stat, cpu: cpu,
                etime: formatElapsedTime(etime), startedAt: startedAt, type: type,
                cwd: cwd.isEmpty ? "unknown" : cwd,
                terminalApp: terminalApp
            ))
        }

        return ProcessScanOutput(processes: results, terminalAppCache: newTerminalAppCache)
    }

    nonisolated static func isClaudeLine(_ line: String) -> Bool {
        let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 6 else { return false }
        let command = parts[5...].joined(separator: " ")
        return (command == "claude" || command.hasPrefix("claude "))
            && !command.contains("--output-format stream-json")
            && !command.contains("bypassPermissions")
    }

    nonisolated static func isCodexLine(_ line: String) -> Bool {
        let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 6 else { return false }
        let command = parts[5...].joined(separator: " ")
        // 新版 Codex CLI 直接以 `codex` 运行;旧版为 `node /path/codex`。两种格式都需识别。
        let isCodex = command == "codex"
            || command.hasPrefix("codex ")
            || (command.hasPrefix("node") && command.contains("/codex"))
        return isCodex
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
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment

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

    // MARK: - Detect host terminal by walking the process parent chain

    /// Walks the parent PID chain from `pid` upward, returning the first known
    /// terminal emulator ancestor. Pattern observed: claude → zsh → login → Terminal.app.
    /// The terminal app's own parent is launchd (pid 1), so we must inspect each
    /// node's comm *before* stopping on ppid <= 1.
    nonisolated static func detectTerminal(pid: Int) -> TerminalApp {
        var current = pid
        for _ in 0..<20 {
            guard let (ppid, comm) = psParentAndName(pid: current) else { break }
            let base = (comm as NSString).lastPathComponent
            if base == "Terminal" { return .terminal }
            if base == "iTerm2" || base == "iTerm" { return .iTerm2 }
            if ppid <= 1 { break }
            current = ppid
        }
        return .unknown
    }

    /// Returns (ppid, comm) for a pid via `ps -o ppid=,comm= -p <pid>`.
    private nonisolated static func psParentAndName(pid: Int) -> (ppid: Int, comm: String)? {
        let process = Process()
        let pipe = Pipe()

        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "ppid=,comm=", "-p", "\(pid)"]

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else { return nil }

        let parts = output.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 2, let ppid = Int(parts[0]) else { return nil }
        let comm = parts[1...].joined(separator: " ")
        return (ppid, comm)
    }

    // MARK: - Time formatting

    /// 解析 ps etime 原始格式为秒:"20" / "1:20" / "1:02:03" / "1-02:03:04"。
    nonisolated static func parseEtimeSeconds(_ etime: String) -> Int {
        var days = 0
        var hms = etime
        if let dash = etime.firstIndex(of: "-") {
            days = Int(etime[..<dash]) ?? 0
            hms = String(etime[etime.index(after: dash)...])
        }
        let parts = hms.split(separator: ":").compactMap { Int($0) }
        var total = days * 86400
        switch parts.count {
        case 3: total += parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: total += parts[0] * 60 + parts[1]
        case 1: total += parts[0]
        default: break
        }
        return total
    }

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

    private nonisolated static func formatSeconds(_ totalSeconds: Int) -> String {
        guard totalSeconds > 0 else { return "0s" }
        let days = totalSeconds / 86400
        let hours = (totalSeconds % 86400) / 3600
        let minutes = (totalSeconds % 3600) / 60
        if days > 0 {
            return "\(days)d \(hours)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            let secs = totalSeconds % 60
            return "\(minutes)m \(secs)s"
        } else {
            return "\(totalSeconds)s"
        }
    }
}

import Foundation

/// Reads the tail of a JSONL transcript file to infer fine-grained activity status.
class TranscriptTailReader {
    private let tailBytes: Int = 65536 // 64KB tail read

    /// Infer activity from transcript file.
    /// Returns nil if file doesn't exist or cannot be parsed.
    func inferActivity(transcriptPath: String) -> AgentStatus? {
        let url = URL(fileURLWithPath: transcriptPath)
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { fileHandle.closeFile() }

        let fileSize = fileHandle.seekToEndOfFile()
        guard fileSize > 0 else { return nil }

        let readSize = min(UInt64(tailBytes), fileSize)
        let offset = fileSize - readSize
        fileHandle.seek(toFileOffset: offset)

        let tailData = fileHandle.readDataToEndOfFile()
        guard let tailString = String(data: tailData, encoding: .utf8) else { return nil }

        // Split by newlines, process from the end
        let lines = tailString.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Scan from the last line backward to find the most recent meaningful event
        for i in stride(from: lines.count - 1, through: max(0, lines.count - 20), by: -1) {
            guard let data = lines[i].data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            switch type {
            case "assistant":
                return inferFromAssistantMessage(json)
            case "tool_result":
                return .processing
            default:
                continue
            }
        }

        return nil
    }

    private func inferFromAssistantMessage(_ json: [String: Any]) -> AgentStatus {
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]],
              !content.isEmpty else {
            return .busy
        }

        // Per Codex review: take the LAST element (represents latest activity)
        guard let lastBlock = content.last,
              let blockType = lastBlock["type"] as? String else {
            return .busy
        }

        switch blockType {
        case "thinking":
            return .thinking
        case "text":
            // text without tool_use means crafting response
            let hasToolUse = content.contains { ($0["type"] as? String) == "tool_use" }
            return hasToolUse ? .busy : .crafting
        case "tool_use":
            return inferFromToolUse(lastBlock)
        default:
            return .busy
        }
    }

    private func inferFromToolUse(_ block: [String: Any]) -> AgentStatus {
        guard let toolName = block["name"] as? String else { return .running }

        switch toolName {
        case "Read":
            return .reading
        case "Edit", "NotebookEdit":
            return .editing
        case "Write":
            return .writing
        case "Bash", "Monitor":
            return .running
        case "Agent", "TaskCreate", "SendMessage", "Workflow":
            return .processing
        case "WebSearch", "WebFetch",
             _ where toolName.contains("search"):
            return .searching
        default:
            // MCP tools and others - check for patterns
            if toolName.contains("search") || toolName.contains("Grep") || toolName.contains("Glob") {
                return .searching
            }
            if toolName.contains("read") || toolName.contains("fetch") {
                return .reading
            }
            return .running
        }
    }

    /// Locate the transcript JSONL path for a given session.
    /// Claude stores transcripts at: ~/.claude/projects/{encoded-project-path}/{sessionId}.jsonl
    func findTranscriptPath(sessionId: String, cwd: String) -> String? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let projectsDir = "\(homeDir)/.claude/projects"

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) else {
            return nil
        }

        // The project directory name is the cwd path with / replaced by -
        // e.g. /Users/lucky/Desktop/AI/AgentDashboard -> -Users-lucky-Desktop-AI-AgentDashboard
        let encodedPath = cwd.replacingOccurrences(of: "/", with: "-")

        for entry in entries {
            if entry == encodedPath || entry.hasSuffix(encodedPath) {
                let transcriptPath = "\(projectsDir)/\(entry)/\(sessionId).jsonl"
                if FileManager.default.fileExists(atPath: transcriptPath) {
                    return transcriptPath
                }
            }
        }

        // Fallback: search all project dirs for the session file
        for entry in entries {
            let transcriptPath = "\(projectsDir)/\(entry)/\(sessionId).jsonl"
            if FileManager.default.fileExists(atPath: transcriptPath) {
                return transcriptPath
            }
        }

        return nil
    }
}

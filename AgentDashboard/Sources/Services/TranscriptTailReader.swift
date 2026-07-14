import Foundation
import os

private let logger = Logger(subsystem: "com.lucky.AgentDashboard", category: "TranscriptTailReader")

final class TranscriptTailReader: @unchecked Sendable {
    private let tailBytes: Int = 65536
    private let queue = DispatchQueue(label: "com.lucky.AgentDashboard.transcriptCache")
    private var pathCache: [String: String] = [:]

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

        let validData: Data
        if offset > 0 {
            if let newlineIndex = tailData.firstIndex(of: 0x0A) {
                let startIndex = tailData.index(after: newlineIndex)
                validData = tailData[startIndex...]
            } else {
                validData = tailData
            }
        } else {
            validData = tailData
        }

        guard let tailString = String(data: validData, encoding: .utf8) else {
            logger.warning("Failed to decode transcript tail as UTF-8: \(transcriptPath)")
            return nil
        }

        let lines = tailString.components(separatedBy: "\n").filter { !$0.isEmpty }
        var resolvedToolUseIds: Set<String> = []

        for i in stride(from: lines.count - 1, through: max(0, lines.count - 20), by: -1) {
            guard let data = lines[i].data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            switch type {
            case "user":
                // Claude stores tool results inside a user message. Remember their ids while
                // walking backwards so an answered AskUserQuestion cannot be mistaken for a
                // still-pending question.
                resolvedToolUseIds.formUnion(toolResultIds(from: json))
            case "assistant":
                return inferFromAssistantMessage(json, resolvedToolUseIds: resolvedToolUseIds)
            case "tool_result":
                if let toolUseId = json["tool_use_id"] as? String, !toolUseId.isEmpty {
                    resolvedToolUseIds.insert(toolUseId)
                } else {
                    return .processing
                }
            default:
                continue
            }
        }

        return resolvedToolUseIds.isEmpty ? nil : .processing
    }

    private func inferFromAssistantMessage(
        _ json: [String: Any], resolvedToolUseIds: Set<String>
    ) -> AgentStatus {
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]],
              !content.isEmpty else {
            return .busy
        }

        guard let lastBlock = content.last,
              let blockType = lastBlock["type"] as? String else {
            return .busy
        }

        switch blockType {
        case "thinking":
            return .thinking
        case "text":
            let hasToolUse = content.contains { ($0["type"] as? String) == "tool_use" }
            return hasToolUse ? .busy : .crafting
        case "tool_use":
            if let toolUseId = lastBlock["id"] as? String,
               resolvedToolUseIds.contains(toolUseId) {
                return .processing
            }
            return inferFromToolUse(lastBlock)
        default:
            return .busy
        }
    }

    private func toolResultIds(from json: [String: Any]) -> Set<String> {
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return []
        }
        return Set(content.compactMap { block in
            guard (block["type"] as? String) == "tool_result",
                  let toolUseId = block["tool_use_id"] as? String,
                  !toolUseId.isEmpty else { return nil }
            return toolUseId
        })
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
        case "AskUserQuestion":
            return .confirming
        case "Agent", "TaskCreate", "SendMessage", "Workflow":
            return .processing
        case "WebSearch", "WebFetch",
             _ where toolName.contains("search"):
            return .searching
        default:
            if toolName.contains("search") || toolName.contains("Grep") || toolName.contains("Glob") {
                return .searching
            }
            if toolName.contains("read") || toolName.contains("fetch") {
                return .reading
            }
            return .running
        }
    }

    func findTranscriptPath(sessionId: String, cwd: String) -> String? {
        let cacheKey = sessionId

        let cached: String? = queue.sync { pathCache[cacheKey] }
        if let cached = cached {
            if FileManager.default.fileExists(atPath: cached) {
                return cached
            }
            queue.sync { _ = pathCache.removeValue(forKey: cacheKey) }
        }

        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let projectsDir = "\(homeDir)/.claude/projects"

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) else {
            return nil
        }

        let encodedPath = cwd.replacingOccurrences(of: "/", with: "-")

        for entry in entries {
            if entry == encodedPath || entry.hasSuffix(encodedPath) {
                let transcriptPath = "\(projectsDir)/\(entry)/\(sessionId).jsonl"
                if FileManager.default.fileExists(atPath: transcriptPath) {
                    queue.sync { pathCache[cacheKey] = transcriptPath }
                    return transcriptPath
                }
            }
        }

        for entry in entries {
            let transcriptPath = "\(projectsDir)/\(entry)/\(sessionId).jsonl"
            if FileManager.default.fileExists(atPath: transcriptPath) {
                queue.sync { pathCache[cacheKey] = transcriptPath }
                return transcriptPath
            }
        }

        return nil
    }

    func clearCache() {
        queue.sync { pathCache.removeAll() }
    }
}

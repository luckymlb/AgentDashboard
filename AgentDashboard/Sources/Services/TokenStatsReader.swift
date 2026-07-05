import Foundation
import os

private let logger = Logger(subsystem: "com.lucky.AgentDashboard", category: "TokenStatsReader")

/// 增量累加每个 Claude 会话 transcript 的 token 用量。
///
/// 按 transcript path 缓存 (上次读到的 offset, 累计 usage),每次只解析新增的 assistant 行;
/// 文件被截断/重建(offset 回退)时全量重算。并发范式照搬 `TranscriptTailReader`:
/// `@unchecked Sendable` + 串行 `DispatchQueue` 保护内部字典。必须在后台线程调用。
final class TokenStatsReader: @unchecked Sendable {
    private struct Accumulator {
        var offset: UInt64
        var usage: TokenUsage
    }

    private let queue = DispatchQueue(label: "com.lucky.AgentDashboard.tokenStats")
    private var accumulators: [String: Accumulator] = [:]

    /// 增量累加并返回该 transcript 的累计 token 用量。
    func accumulate(transcriptPath: String) -> TokenUsage {
        guard let fileHandle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: transcriptPath)) else {
            return .zero
        }
        defer { fileHandle.closeFile() }

        let fileSize = fileHandle.seekToEndOfFile()
        guard fileSize > 0 else {
            return queue.sync { accumulators[transcriptPath]?.usage ?? .zero }
        }

        let cached = queue.sync { accumulators[transcriptPath] }

        // 文件被截断/重建(fileSize < offset)或首次读取 → 从头全量重算。
        var startOffset: UInt64 = 0
        var running = TokenUsage.zero
        if let cached, cached.offset > 0, fileSize >= cached.offset {
            startOffset = cached.offset
            running = cached.usage
        }

        // 没有新增内容直接返回缓存值。
        guard startOffset < fileSize else {
            return running
        }

        fileHandle.seek(toFileOffset: startOffset)
        let data = fileHandle.readDataToEndOfFile()

        // 只处理到最后一个换行(完整行);尾部可能尚未写完的行留到下次,
        // offset 始终推进到 \n 之后(行首),避免漏加或重复加某一行。
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            // 整段尚无换行(一行还没写完),留到下次。
            return running
        }
        let processedData = data[data.startIndex...lastNewline]
        let newOffset = startOffset + UInt64(data.distance(from: data.startIndex, to: lastNewline)) + 1

        guard let text = String(data: processedData, encoding: .utf8) else {
            logger.warning("Failed to decode transcript as UTF-8: \(transcriptPath)")
            return running
        }

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (json["type"] as? String) == "assistant" else { continue }
            running = running + usage(from: json)
        }

        queue.sync { accumulators[transcriptPath] = Accumulator(offset: newOffset, usage: running) }
        return running
    }

    /// 清理本次扫描未命中的条目(已退出的 agent 对应的 transcript)。
    func prune(keeping paths: Set<String>) {
        queue.sync { accumulators = accumulators.filter { paths.contains($0.key) } }
    }

    private func usage(from json: [String: Any]) -> TokenUsage {
        let message = json["message"] as? [String: Any]
        let dict = (message?["usage"] as? [String: Any]) ?? [:]
        return TokenUsage(
            inputTokens: intField(dict, "input_tokens"),
            cacheCreationTokens: intField(dict, "cache_creation_input_tokens"),
            cacheReadTokens: intField(dict, "cache_read_input_tokens"),
            outputTokens: intField(dict, "output_tokens"),
            model: message?["model"] as? String
        )
    }

    // JSONSerialization 解出的数值是 NSNumber;Int(truncating:) 兼容大额 token,避免 Int32 溢出。
    private func intField(_ dict: [String: Any], _ key: String) -> Int {
        if let n = dict[key] as? NSNumber { return Int(truncating: n) }
        return 0
    }
}

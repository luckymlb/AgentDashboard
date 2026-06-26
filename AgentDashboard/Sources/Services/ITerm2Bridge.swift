import Foundation
import os

private let logger = Logger(subsystem: "com.lucky.AgentDashboard", category: "ITerm2Bridge")

enum ITerm2Error: Error {
    case invalidTTY
    case scriptFailed(String)
    case sessionNotFound
}

class ITerm2Bridge {
    private static let ttyPattern = try! NSRegularExpression(pattern: #"^(/dev/)?ttys\d+$"#)

    static func activateSession(tty: String) {
        guard isValidTTY(tty) else {
            logger.error("Invalid tty format rejected: \(tty)")
            return
        }

        let devicePath = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"

        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(devicePath)" then
                            tell t to select
                            tell w
                                set index to 1
                            end tell
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "not_found"
        end tell
        """

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()

            process.standardOutput = outPipe
            process.standardError = errPipe
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            do {
                try process.run()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if process.terminationStatus != 0 {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8) ?? "unknown"
                    logger.error("osascript failed (exit \(process.terminationStatus)): \(errMsg)")
                } else if output == "not_found" {
                    logger.info("iTerm2 session not found for tty: \(tty)")
                } else {
                    logger.debug("iTerm2 session activated for tty: \(tty)")
                }
            } catch {
                logger.error("Failed to launch osascript: \(error.localizedDescription)")
            }
        }
    }

    private static func isValidTTY(_ tty: String) -> Bool {
        let range = NSRange(tty.startIndex..., in: tty)
        return ttyPattern.firstMatch(in: tty, range: range) != nil
    }
}

import Foundation


enum ITerm2Bridge {
    private static let ttyPattern = try! NSRegularExpression(pattern: #"^(/dev/)?ttys\d+$"#)

    /// 返回 nil 表示 tty 未通过白名单校验。保留为 internal 供脚本回归测试使用。
    static func activationScript(tty: String) -> String? {
        guard isValidTTY(tty) else { return nil }
        let devicePath = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"

        return """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(devicePath)" then
                            tell s to select
                            tell t to select
                            set miniaturized of w to false
                            tell w to select
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "not_found"
        end tell
        """
    }

    private static func isValidTTY(_ tty: String) -> Bool {
        let range = NSRange(tty.startIndex..., in: tty)
        return ttyPattern.firstMatch(in: tty, range: range) != nil
    }
}

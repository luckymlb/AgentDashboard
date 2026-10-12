import Foundation


/// Activates the Terminal.app tab bound to a given tty.
/// Both the bare (`ttysNNN`) and `/dev/`-prefixed forms are compared, since
/// the exact value returned by `tty of t` is not guaranteed across versions.
/// Only invoked when the agent was detected as running under Terminal.app —
/// `tell application "Terminal"` would otherwise launch the app.
enum TerminalAppBridge {
    private static let ttyPattern = try! NSRegularExpression(pattern: #"^(/dev/)?ttys\d+$"#)

    /// 返回 nil 表示 tty 未通过白名单校验。保留为 internal 供脚本回归测试使用。
    static func activationScript(tty: String) -> String? {
        guard isValidTTY(tty) else { return nil }
        let devicePath = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        let bareTTY = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty

        return """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    set tTTY to tty of t
                    if tTTY is "\(bareTTY)" or tTTY is "\(devicePath)" then
                        set selected of t to true
                        set miniaturized of w to false
                        set frontmost of w to true
                        set index of w to 1
                        activate
                        return "ok"
                    end if
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

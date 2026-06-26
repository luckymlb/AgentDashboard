import Foundation

class ITerm2Bridge {
    static func activateSession(tty: String) {
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
            let pipe = Pipe()

            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                // silently fail
            }
        }
    }
}

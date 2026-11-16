import Foundation

/// Runs root commands through `sudo`, which shows a Touch ID prompt when the system's
/// `pam_tid.so` module is enabled for sudo (in /etc/pam.d/sudo_local or /etc/pam.d/sudo).
///
/// The app never asks for or handles a password here: sudo runs with no terminal and no askpass
/// helper (`-A` makes pam_tid skip Touch ID), so if Touch ID is cancelled or unavailable, sudo
/// can't read a password and fails, and the caller falls back to the macOS password dialog.
enum TouchIDSudo {
    static let enableCommand = "sed -e 's/^#auth/auth/' /etc/pam.d/sudo_local.template | sudo tee /etc/pam.d/sudo_local"

    /// True when sudo is configured to accept Touch ID.
    static var isEnabled: Bool {
        for path in ["/etc/pam.d/sudo_local", "/etc/pam.d/sudo"] {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.hasPrefix("#"), t.hasPrefix("auth"), t.contains("pam_tid.so") { return true }
            }
        }
        return false
    }

    enum Outcome { case success, notAuthenticated }

    /// Authenticates with Touch ID via `sudo -v`, then runs the script as root.
    /// Returns `.notAuthenticated` if Touch ID was declined or couldn't be used.
    static func run(_ script: String) throws -> Outcome {
        guard isEnabled else { return .notAuthenticated }

        // Step 1: authenticate (Touch ID sheet). Fails fast if the user cancels.
        let auth = exec(["-v"])
        guard auth.status == 0 else { return .notAuthenticated }

        // Step 2: run the work, reusing sudo's cached credential (-n = never prompt).
        var result = exec(["-n", "/bin/sh", "-c", script])
        if result.status != 0, isSudoAuthError(result.stderr) {
            // Credential caching may be disabled; try once more with an interactive Touch ID prompt.
            result = exec(["/bin/sh", "-c", script])
            if result.status != 0, isSudoAuthError(result.stderr) { return .notAuthenticated }
        }
        if result.status != 0 {
            let msg = (result.stderr + "\n" + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ManagerError.message(msg.isEmpty ? "Command failed (exit \(result.status))." : msg)
        }
        return .success
    }

    private static func isSudoAuthError(_ stderr: String) -> Bool {
        stderr.contains("sudo:") && (stderr.contains("password") || stderr.contains("authentication") || stderr.contains("terminal is required"))
    }

    private static func exec(_ args: [String]) -> (status: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "SUDO_ASKPASS")
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (-1, "", error.localizedDescription) }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }
}

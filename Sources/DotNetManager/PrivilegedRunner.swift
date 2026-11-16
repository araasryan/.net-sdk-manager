import Foundation
import Security

/// Runs shell scripts as root using Authorization Services.
///
/// The system authorization dialog (SecurityAgent) offers Touch ID on Macs with an enrolled
/// fingerprint and falls back to the account password otherwise. The approved credential is
/// cached by the system for a few minutes, so consecutive installs/uninstalls don't re-prompt.
enum PrivilegedRunner {
    private typealias AEWP = @convention(c) (
        AuthorizationRef,
        UnsafePointer<CChar>,
        AuthorizationFlags,
        UnsafePointer<UnsafeMutablePointer<CChar>?>,
        UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    /// AuthorizationExecuteWithPrivileges is deprecated and not exposed to Swift, but still shipped.
    private static let executeWithPrivileges: AEWP? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AuthorizationExecuteWithPrivileges") else { return nil }
        return unsafeBitCast(sym, to: AEWP.self)
    }()

    private static let lock = NSLock()
    private static var authRef: AuthorizationRef?

    static var isAvailable: Bool { executeWithPrivileges != nil }

    /// Ask the user for admin rights (Touch ID or password). Returns an authorization reference with the admin right.
    private static func authorize(prompt: String) throws -> AuthorizationRef {
        lock.lock(); defer { lock.unlock() }
        if authRef == nil {
            var ref: AuthorizationRef?
            let st = AuthorizationCreate(nil, nil, [], &ref)
            guard st == errAuthorizationSuccess, let ref else { throw ManagerError.message("Couldn't create authorization (\(st)).") }
            authRef = ref
        }
        let ref = authRef!

        let rightName = strdup(kAuthorizationRightExecute)!
        let promptKey = strdup(kAuthorizationEnvironmentPrompt)!
        let promptVal = strdup(prompt)!
        defer { free(rightName); free(promptKey); free(promptVal) }
        var right = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
        var envItem = AuthorizationItem(name: promptKey, valueLength: strlen(promptVal), value: promptVal, flags: 0)
        let status: OSStatus = withUnsafeMutablePointer(to: &right) { rp in
            withUnsafeMutablePointer(to: &envItem) { ep in
                var rights = AuthorizationRights(count: 1, items: rp)
                var env = AuthorizationEnvironment(count: 1, items: ep)
                return AuthorizationCopyRights(ref, &rights, &env, [.interactionAllowed, .extendRights, .preAuthorize], nil)
            }
        }
        switch status {
        case errAuthorizationSuccess: return ref
        case errAuthorizationCanceled: throw ManagerError.message("Cancelled.")
        case errAuthorizationDenied: throw ManagerError.message("Authorization was denied.")
        default: throw ManagerError.message("Authorization failed (\(status)).")
        }
    }

    /// Runs `script` with /bin/sh as root. Throws with the script's output if it exits non-zero.
    @discardableResult
    static func run(_ script: String, prompt: String) throws -> String {
        guard let execute = executeWithPrivileges else { throw ManagerError.message("Privileged execution unavailable.") }
        let ref = try authorize(prompt: prompt)

        let marker = "__DNM_EXIT__"
        let wrapped = "( \(script)\n) 2>&1; echo \"\(marker)$?\""

        var pipe: UnsafeMutablePointer<FILE>?
        let status: OSStatus = "-c".withCString { a0 in
            wrapped.withCString { a1 in
                let args: [UnsafeMutablePointer<CChar>?] = [UnsafeMutablePointer(mutating: a0), UnsafeMutablePointer(mutating: a1), nil]
                return args.withUnsafeBufferPointer { buf in
                    execute(ref, "/bin/sh", [], buf.baseAddress!, &pipe)
                }
            }
        }
        if status == errAuthorizationCanceled { throw ManagerError.message("Cancelled.") }
        guard status == errAuthorizationSuccess, let pipe else { throw ManagerError.message("Couldn't run privileged command (\(status)).") }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = fread(&buffer, 1, buffer.count, pipe)
            if n > 0 { output.append(buffer, count: n) }
            if n < buffer.count { if feof(pipe) != 0 || ferror(pipe) != 0 { break } }
        }
        fclose(pipe)
        // Reap the child so it doesn't linger as a zombie.
        var st: Int32 = 0
        while waitpid(-1, &st, WNOHANG) > 0 {}

        var text = String(decoding: output, as: UTF8.self)
        guard let r = text.range(of: marker, options: .backwards) else {
            throw ManagerError.message("Privileged command ended unexpectedly.\n\(text)")
        }
        let code = Int(text[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        text = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if code != 0 { throw ManagerError.message(text.isEmpty ? "Command failed (exit \(code))." : text) }
        return text
    }
}

import Foundation
import CryptoKit

enum ManagerError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

// MARK: - Scanning installed components

enum Scanner {
    /// Known dotnet roots: the official pkg location, the x64-on-arm emulation location, and the user-local dotnet-install location.
    static var roots: [URL] {
        var r = [URL(fileURLWithPath: "/usr/local/share/dotnet")]
        r.append(URL(fileURLWithPath: "/usr/local/share/dotnet/x64"))
        r.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dotnet"))
        if let env = ProcessInfo.processInfo.environment["DOTNET_ROOT"] {
            let u = URL(fileURLWithPath: env)
            if !r.contains(u) { r.append(u) }
        }
        return r
    }

    static func scan() -> [InstalledComponent] {
        var out: [InstalledComponent] = []
        for root in roots {
            let sdkDir = root.appendingPathComponent("sdk")
            for v in subdirs(sdkDir) where looksLikeVersion(v) {
                out.append(.init(kind: .sdk, frameworkName: "sdk", version: v, root: root,
                                 path: sdkDir.appendingPathComponent(v).path))
            }
            let shared = root.appendingPathComponent("shared")
            for fw in subdirs(shared) {
                let kind: ComponentKind = fw == "Microsoft.NETCore.App" ? .runtime
                    : fw == "Microsoft.AspNetCore.App" ? .aspnet : .other
                let fwDir = shared.appendingPathComponent(fw)
                for v in subdirs(fwDir) where looksLikeVersion(v) {
                    out.append(.init(kind: kind, frameworkName: fw, version: v, root: root,
                                     path: fwDir.appendingPathComponent(v).path))
                }
            }
        }
        return out.sorted { ($0.kind.rawValue, $1.sortKey) < ($1.kind.rawValue, $0.sortKey) }
    }

    static func subdirs(_ url: URL) -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: url.path) else { return [] }
        return items.filter {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.appendingPathComponent($0).path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    static func looksLikeVersion(_ s: String) -> Bool {
        s.range(of: #"^\d+\.\d+\.\d+([\-\.+][A-Za-z0-9\.\-]+)?$"#, options: .regularExpression) != nil
    }

    static func directorySize(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            if let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                total += Int64(v.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}

// MARK: - Shell / privileged execution

enum Shell {
    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let edata = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let o = String(decoding: data, as: UTF8.self)
        if p.terminationStatus != 0 {
            let e = String(decoding: edata, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ManagerError.message(e.isEmpty ? "Command failed (\(p.terminationStatus))" : e)
        }
        return o
    }

    /// Single-quote a string for /bin/sh.
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Runs a shell script, prompting for an administrator password via the standard macOS dialog.
    static func runAsAdmin(_ script: String, prompt: String) throws {
        // Preferred: sudo with Touch ID (when pam_tid is enabled for sudo).
        if TouchIDSudo.isEnabled, try TouchIDSudo.run(script) == .success {
            return
        }
        // Next: Authorization Services system dialog (password).
        if PrivilegedRunner.isAvailable {
            try PrivilegedRunner.run(script, prompt: prompt)
            return
        }
        // Fallback: AppleScript admin prompt (password only).
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let promptEsc = prompt.replacingOccurrences(of: "\"", with: "'")
        let apple = "do shell script \"\(escaped)\" with prompt \"\(promptEsc)\" with administrator privileges"
        do {
            try run("/usr/bin/osascript", ["-e", apple])
        } catch ManagerError.message(let m) where m.contains("-128") {
            throw ManagerError.message("Cancelled.")
        }
    }

    static func runMaybeAdmin(_ script: String, admin: Bool, prompt: String) throws {
        if admin { try runAsAdmin(script, prompt: prompt) } else { try run("/bin/sh", ["-c", script]) }
    }
}

// MARK: - Uninstall

enum Uninstaller {
    static func uninstall(_ items: [InstalledComponent]) throws {
        let groups = Dictionary(grouping: items, by: \.requiresAdmin)
        for (admin, comps) in groups {
            var lines = ["set -e"]
            for c in comps {
                lines.append("rm -rf \(Shell.q(c.path))")
                // Remove matching sdk-manifests / templates / host fxr leftovers when safe
                if c.kind == .sdk {
                    let band = sdkFeatureBand(c.version)
                    let others = Scanner.scan().filter { $0.kind == .sdk && $0.root == c.root && $0.path != c.path && sdkFeatureBand($0.version) == band && !comps.contains($0) }
                    if others.isEmpty, let band {
                        lines.append("rm -rf \(Shell.q(c.root.appendingPathComponent("sdk-manifests/\(band)").path))")
                    }
                }
                if c.kind == .runtime {
                    // Only drop the matching hostfxr if another one remains, otherwise the `dotnet` muxer breaks.
                    let fxrDir = c.root.appendingPathComponent("host/fxr")
                    let fxrs = Scanner.subdirs(fxrDir)
                    if fxrs.contains(c.version) && fxrs.count > 1 {
                        lines.append("rm -rf \(Shell.q(fxrDir.appendingPathComponent(c.version).path))")
                    }
                    lines.append("rm -rf \(Shell.q(c.root.appendingPathComponent("packs/Microsoft.NETCore.App.Ref/\(c.version)").path))")
                    lines.append("rm -rf \(Shell.q(c.root.appendingPathComponent("packs/Microsoft.NETCore.App.Host.\(currentRID)/\(c.version)").path))")
                }
                if c.kind == .aspnet {
                    lines.append("rm -rf \(Shell.q(c.root.appendingPathComponent("packs/Microsoft.AspNetCore.App.Ref/\(c.version)").path))")
                }
                if admin {
                    // Forget installer receipts that reference this version so macOS doesn't think it's still installed.
                    let v = c.version.replacingOccurrences(of: ".", with: "\\.")
                    lines.append("for r in $(pkgutil --pkgs | grep -i 'dotnet' | grep -E '\(v)([^0-9]|$)' || true); do pkgutil --forget \"$r\" >/dev/null || true; done")
                }
            }
            let names = comps.map { "\($0.kind.displayName) \($0.version)" }.joined(separator: ", ")
            try Shell.runMaybeAdmin(lines.joined(separator: "\n"), admin: admin,
                                    prompt: "DotNet Manager wants to uninstall \(names).")
        }
    }

    /// 9.0.104 -> "9.0.100"
    static func sdkFeatureBand(_ v: String) -> String? {
        let base = v.split(separator: "-").first.map(String.init) ?? v
        let p = base.split(separator: ".")
        guard p.count >= 3, let patch = Int(p[2]) else { return nil }
        return "\(p[0]).\(p[1]).\(patch / 100 * 100)"
    }
}

// MARK: - Release metadata + install

enum ReleaseService {
    static let indexURL = URL(string: "https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json")!

    static func channels() async throws -> [Channel] {
        let (data, _) = try await URLSession.shared.data(from: indexURL)
        return try JSONDecoder().decode(ReleasesIndex.self, from: data).releasesIndex
    }

    static func releases(for channel: Channel) async throws -> [Release] {
        guard let url = URL(string: channel.releasesJson) else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(ChannelReleases.self, from: data).releases
    }
}

final class Downloader: NSObject, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    private let progress: (Double) -> Void
    private var session: URLSession!

    init(progress: @escaping (Double) -> Void) {
        self.progress = progress
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { c in
            continuation = c
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
        if t > 0 { progress(Double(w) / Double(t)) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(downloadTask.originalRequest?.url?.lastPathComponent ?? "dotnet.pkg")
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: dest)
            continuation?.resume(returning: dest)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        s.finishTasksAndInvalidate()
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error); continuation = nil }
        if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: ManagerError.message("Download failed: HTTP \(http.statusCode)"))
            continuation = nil
        }
    }
}

enum Installer {
    static func install(_ item: Installable, progress: @escaping (String, Double?) -> Void) async throws {
        guard let url = URL(string: item.file.url), url.host?.hasSuffix("microsoft.com") == true || url.host?.hasSuffix("dot.net") == true else {
            throw ManagerError.message("Refusing to download from an unexpected host.")
        }
        progress("Downloading \(item.file.name)…", 0)
        let file = try await Downloader { p in progress("Downloading \(item.file.name)…", p) }.download(url)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        if let expected = item.file.hash?.lowercased(), !expected.isEmpty {
            progress("Verifying checksum…", nil)
            let actual = try sha512(file)
            guard actual == expected else { throw ManagerError.message("Checksum mismatch — the download may be corrupted.") }
        }

        progress("Checking package signature…", nil)
        let sig = (try? Shell.run("/usr/sbin/pkgutil", ["--check-signature", file.path])) ?? ""
        guard sig.contains("Microsoft") else { throw ManagerError.message("Package is not signed by Microsoft.") }

        progress("Installing (you'll be asked for your password)…", nil)
        try Shell.runAsAdmin("/usr/sbin/installer -pkg \(Shell.q(file.path)) -target /",
                             prompt: "DotNet Manager wants to install \(item.kind.rawValue) \(item.version).")
    }

    static func sha512(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA512()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

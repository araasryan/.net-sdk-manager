import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var installed: [InstalledComponent] = []
    @Published var channels: [Channel] = []
    @Published var releases: [String: [Release]] = [:]   // channel-version -> releases
    @Published var isScanning = false
    @Published var loadingChannels = false
    @Published var loadingReleases: Set<String> = []
    @Published var busyMessage: String?
    @Published var busyProgress: Double?
    @Published var errorMessage: String?
    @Published var infoMessage: String?

    var isBusy: Bool { busyMessage != nil }

    // MARK: Installed

    func refreshInstalled() async {
        isScanning = true
        let comps = await Task.detached { Scanner.scan() }.value
        installed = comps
        isScanning = false
        // Compute sizes in the background
        for c in comps {
            let path = c.path
            let size = await Task.detached(priority: .utility) { Scanner.directorySize(path) }.value
            if let i = installed.firstIndex(where: { $0.path == path }) { installed[i].sizeBytes = size }
        }
    }

    func isInstalled(_ kind: InstallableKind, _ version: String) -> Bool {
        installed.contains {
            switch kind {
            case .sdk: return $0.kind == .sdk && $0.version == version
            case .runtime: return $0.kind == .runtime && $0.version == version
            case .aspnet: return $0.kind == .aspnet && $0.version == version
            }
        }
    }

    func uninstall(_ items: [InstalledComponent]) async {
        guard !items.isEmpty else { return }
        busyMessage = "Uninstalling \(items.count) item(s)…"
        busyProgress = nil
        defer { busyMessage = nil }
        do {
            try await Task.detached { try Uninstaller.uninstall(items) }.value
            infoMessage = "Uninstalled " + items.map { "\($0.kind.displayName) \($0.version)" }.joined(separator: ", ")
        } catch {
            if error.localizedDescription != "Cancelled." { errorMessage = error.localizedDescription }
        }
        await refreshInstalled()
    }

    // MARK: Available

    func loadChannels() async {
        guard channels.isEmpty, !loadingChannels else { return }
        loadingChannels = true
        defer { loadingChannels = false }
        do { channels = try await ReleaseService.channels() }
        catch { errorMessage = "Couldn't load .NET release list: \(error.localizedDescription)" }
    }

    func loadReleases(_ ch: Channel) async {
        guard releases[ch.id] == nil, !loadingReleases.contains(ch.id) else { return }
        loadingReleases.insert(ch.id)
        defer { loadingReleases.remove(ch.id) }
        do { releases[ch.id] = try await ReleaseService.releases(for: ch) }
        catch { errorMessage = "Couldn't load releases for .NET \(ch.channelVersion): \(error.localizedDescription)" }
    }

    func install(_ item: Installable) async {
        busyMessage = "Preparing…"
        busyProgress = nil
        defer { busyMessage = nil; busyProgress = nil }
        do {
            try await Installer.install(item) { msg, p in
                Task { @MainActor in
                    self.busyMessage = msg
                    self.busyProgress = p
                }
            }
            infoMessage = "Installed \(item.kind.rawValue) \(item.version)"
        } catch {
            if error.localizedDescription != "Cancelled." { errorMessage = error.localizedDescription }
        }
        await refreshInstalled()
    }
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

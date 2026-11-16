import Foundation

// MARK: - Installed components

enum ComponentKind: String, CaseIterable, Identifiable, Codable {
    case sdk = "SDK"
    case runtime = "Microsoft.NETCore.App"
    case aspnet = "Microsoft.AspNetCore.App"
    case other = "Other"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sdk: return "SDK"
        case .runtime: return ".NET Runtime"
        case .aspnet: return "ASP.NET Core Runtime"
        case .other: return "Shared Framework"
        }
    }

    var symbol: String {
        switch self {
        case .sdk: return "hammer"
        case .runtime: return "cpu"
        case .aspnet: return "globe"
        case .other: return "shippingbox"
        }
    }
}

struct InstalledComponent: Identifiable, Hashable {
    var id: String { path }
    let kind: ComponentKind
    let frameworkName: String   // e.g. Microsoft.NETCore.App, or "sdk"
    let version: String
    let root: URL               // dotnet root, e.g. /usr/local/share/dotnet
    let path: String            // full path to the version directory
    var sizeBytes: Int64?

    var requiresAdmin: Bool { !FileManager.default.isWritableFile(atPath: (path as NSString).deletingLastPathComponent) }
    var majorMinor: String { version.split(separator: ".").prefix(2).joined(separator: ".") }
    var sortKey: SemVer { SemVer(version) }
}

/// Loose semantic-version comparison good enough for .NET versions like 9.0.100-rc.2.24474.11
struct SemVer: Comparable, Hashable {
    let parts: [Int]
    let pre: String?

    init(_ s: String) {
        let split = s.split(separator: "-", maxSplits: 1).map(String.init)
        parts = split[0].split(separator: ".").map { Int($0) ?? 0 }
        pre = split.count > 1 ? split[1] : nil
    }

    static func < (a: SemVer, b: SemVer) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        switch (a.pre, b.pre) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case let (p, q): return p! < q!
        }
    }
}

// MARK: - Release metadata (builds.dotnet.microsoft.com)

struct ReleasesIndex: Decodable {
    let releasesIndex: [Channel]
    enum CodingKeys: String, CodingKey { case releasesIndex = "releases-index" }
}

struct Channel: Decodable, Identifiable, Hashable {
    var id: String { channelVersion }
    let channelVersion: String
    let latestRelease: String
    let latestReleaseDate: String
    let latestRuntime: String
    let latestSdk: String
    let supportPhase: String
    let releaseType: String
    let eolDate: String?
    let releasesJson: String

    enum CodingKeys: String, CodingKey {
        case channelVersion = "channel-version"
        case latestRelease = "latest-release"
        case latestReleaseDate = "latest-release-date"
        case latestRuntime = "latest-runtime"
        case latestSdk = "latest-sdk"
        case supportPhase = "support-phase"
        case releaseType = "release-type"
        case eolDate = "eol-date"
        case releasesJson = "releases.json"
    }

    var isSupported: Bool { ["active", "maintenance", "preview", "go-live"].contains(supportPhase) }
}

struct ChannelReleases: Decodable {
    let releases: [Release]
}

struct Release: Decodable, Identifiable, Hashable {
    var id: String { releaseVersion }
    let releaseDate: String
    let releaseVersion: String
    let security: Bool?
    let releaseNotes: String?
    let runtime: Product?
    let sdks: [Product]?
    let sdk: Product?
    let aspnetcoreRuntime: Product?

    enum CodingKeys: String, CodingKey {
        case releaseDate = "release-date"
        case releaseVersion = "release-version"
        case security
        case releaseNotes = "release-notes"
        case runtime, sdks, sdk
        case aspnetcoreRuntime = "aspnetcore-runtime"
    }

    var allSdks: [Product] {
        if let sdks, !sdks.isEmpty { return sdks }
        return sdk.map { [$0] } ?? []
    }
}

struct Product: Decodable, Hashable {
    let version: String
    let files: [ReleaseFile]?

    func pkg(for rid: String) -> ReleaseFile? {
        files?.first { $0.rid == rid && $0.url.hasSuffix(".pkg") }
    }
}

struct ReleaseFile: Decodable, Hashable {
    let name: String
    let rid: String?
    let url: String
    let hash: String?
}

enum InstallableKind: String {
    case sdk = "SDK"
    case runtime = ".NET Runtime"
    case aspnet = "ASP.NET Core Runtime"
}

struct Installable: Identifiable, Hashable {
    var id: String { "\(kind.rawValue)-\(version)" }
    let kind: InstallableKind
    let version: String
    let file: ReleaseFile
}

var currentRID: String {
    #if arch(arm64)
    return "osx-arm64"
    #else
    return "osx-x64"
    #endif
}

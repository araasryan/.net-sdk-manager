import SwiftUI
import AppKit

@main
struct DotNetManagerApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Running as a bare SwiftPM executable: make sure we get a Dock icon and a key window.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup(".NET Manager") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 520)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await model.refreshInstalled() } }
                    .keyboardShortcut("r")
            }
        }
    }
}

enum SidebarItem: Hashable {
    case installed
    case channel(String)
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: SidebarItem? = .installed
    @State private var showUnsupported = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("This Mac") {
                    Label {
                        HStack {
                            Text("Installed")
                            Spacer()
                            Text("\(model.installed.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    } icon: { Image(systemName: "internaldrive") }
                    .tag(SidebarItem.installed)
                }
                Section("Available") {
                    if model.loadingChannels {
                        ProgressView().controlSize(.small)
                    }
                    ForEach(visibleChannels) { ch in
                        Label {
                            HStack {
                                Text(".NET \(ch.channelVersion)")
                                Spacer()
                                PhaseBadge(channel: ch)
                            }
                        } icon: { Image(systemName: "shippingbox") }
                        .tag(SidebarItem.channel(ch.id))
                    }
                    Toggle("Show end-of-life", isOn: $showUnsupported)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .safeAreaInset(edge: .bottom) { TouchIDStatus() }
        } detail: {
            switch selection {
            case .installed, .none:
                InstalledView()
            case .channel(let id):
                if let ch = model.channels.first(where: { $0.id == id }) {
                    ChannelView(channel: ch).id(id)
                }
            }
        }
        .overlay { if model.isBusy { BusyOverlay() } }
        .task {
            await model.refreshInstalled()
            await model.loadChannels()
        }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("Done", isPresented: Binding(get: { model.infoMessage != nil }, set: { if !$0 { model.infoMessage = nil } })) {
            Button("OK") { model.infoMessage = nil }
        } message: { Text(model.infoMessage ?? "") }
    }

    var visibleChannels: [Channel] {
        model.channels.filter { showUnsupported || $0.isSupported }
    }
}

struct PhaseBadge: View {
    let channel: Channel
    var body: some View {
        let (text, color): (String, Color) = {
            switch channel.supportPhase {
            case "preview", "go-live": return ("Preview", .purple)
            case "eol": return ("EOL", .gray)
            default: return (channel.releaseType.uppercased(), channel.releaseType == "lts" ? .green : .blue)
            }
        }()
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Installed

struct InstalledView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection = Set<InstalledComponent.ID>()
    @State private var filter: ComponentKind? = nil
    @State private var confirm: [InstalledComponent]? = nil

    var rows: [InstalledComponent] {
        model.installed.filter { filter == nil || $0.kind == filter }
    }

    var body: some View {
        Group {
            if model.installed.isEmpty && !model.isScanning {
                ContentUnavailableView {
                    Label("No .NET installations found", systemImage: "shippingbox")
                } description: {
                    Text("Looked in /usr/local/share/dotnet and ~/.dotnet.\nPick a version under Available to install one.")
                }
            } else {
                Table(rows, selection: $selection) {
                    TableColumn("Component") { c in
                        Label(c.kind == .other ? c.frameworkName : c.kind.displayName, systemImage: c.kind.symbol)
                    }
                    .width(min: 160, ideal: 200)
                    TableColumn("Version") { c in Text(c.version).monospacedDigit().textSelection(.enabled) }
                        .width(min: 90, ideal: 130)
                    TableColumn("Location") { c in
                        Text(c.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    TableColumn("Size") { c in
                        Text(c.sizeBytes?.byteString ?? "…").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .width(min: 60, ideal: 80)
                }
                .contextMenu(forSelectionType: InstalledComponent.ID.self) { ids in
                    let items = model.installed.filter { ids.contains($0.id) }
                    if !items.isEmpty {
                        Button("Uninstall…", role: .destructive) { confirm = items }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(items.map { URL(fileURLWithPath: $0.path) })
                        }
                    }
                }
            }
        }
        .navigationTitle("Installed")
        .navigationSubtitle(summary)
        .toolbar {
            ToolbarItem {
                Picker("Filter", selection: $filter) {
                    Text("All").tag(ComponentKind?.none)
                    Text("SDKs").tag(ComponentKind?.some(.sdk))
                    Text("Runtimes").tag(ComponentKind?.some(.runtime))
                    Text("ASP.NET").tag(ComponentKind?.some(.aspnet))
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Button { Task { await model.refreshInstalled() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            ToolbarItem {
                Button(role: .destructive) {
                    confirm = model.installed.filter { selection.contains($0.id) }
                } label: { Label("Uninstall", systemImage: "trash") }
                .disabled(selection.isEmpty)
                .help("Uninstall selected")
            }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Uninstall", role: .destructive) {
                let items = confirm ?? []
                confirm = nil
                selection.removeAll()
                Task { await model.uninstall(items) }
            }
        } message: {
            Text((confirm ?? []).map { "• \($0.kind.displayName) \($0.version)" }.joined(separator: "\n")
                 + "\n\nThis deletes the files from disk. You may be asked for your password.")
        }
    }

    var confirmTitle: String {
        let n = confirm?.count ?? 0
        return n == 1 ? "Uninstall \(confirm![0].kind.displayName) \(confirm![0].version)?" : "Uninstall \(n) components?"
    }

    var summary: String {
        let sdks = model.installed.filter { $0.kind == .sdk }.count
        let rts = model.installed.filter { $0.kind != .sdk }.count
        let total = model.installed.compactMap(\.sizeBytes).reduce(0, +)
        return "\(sdks) SDKs · \(rts) runtimes" + (total > 0 ? " · \(total.byteString)" : "")
    }
}

// MARK: - Channel / Available

struct ChannelView: View {
    @EnvironmentObject var model: AppModel
    let channel: Channel
    @State private var includePreviews = true

    var releases: [Release] { model.releases[channel.id] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.loadingReleases.contains(channel.id) && releases.isEmpty {
                ProgressView("Loading releases…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(releases) { r in ReleaseRow(release: r) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle(".NET \(channel.channelVersion)")
        .navigationSubtitle("\(channel.releaseType.uppercased()) · \(channel.supportPhase)")
        .task { await model.loadReleases(channel) }
    }

    var header: some View {
        HStack(alignment: .top, spacing: 24) {
            Stat(title: "Latest SDK", value: channel.latestSdk)
            Stat(title: "Latest runtime", value: channel.latestRuntime)
            Stat(title: "Released", value: channel.latestReleaseDate)
            if let eol = channel.eolDate { Stat(title: "End of support", value: eol) }
            Spacer()
            if let latest = releases.first, let sdk = latest.allSdks.first, let f = sdk.pkg(for: currentRID) {
                let item = Installable(kind: .sdk, version: sdk.version, file: f)
                if model.isInstalled(.sdk, sdk.version) {
                    Label("Latest SDK installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button { Task { await model.install(item) } } label: {
                        Label("Install SDK \(sdk.version)", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                }
            }
        }
        .padding()
    }
}

struct Stat: View {
    let title: String, value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit())
        }
    }
}

struct ReleaseRow: View {
    @EnvironmentObject var model: AppModel
    let release: Release

    var installables: [Installable] {
        var out: [Installable] = []
        for s in release.allSdks { if let f = s.pkg(for: currentRID) { out.append(.init(kind: .sdk, version: s.version, file: f)) } }
        if let r = release.runtime, let f = r.pkg(for: currentRID) { out.append(.init(kind: .runtime, version: r.version, file: f)) }
        if let a = release.aspnetcoreRuntime, let f = a.pkg(for: currentRID) { out.append(.init(kind: .aspnet, version: a.version, file: f)) }
        return out
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(release.releaseVersion).font(.headline.monospacedDigit())
                    if release.security == true {
                        Label("Security", systemImage: "lock.shield")
                            .labelStyle(.titleAndIcon).font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.orange.opacity(0.18), in: Capsule()).foregroundStyle(.orange)
                    }
                }
                Text(release.releaseDate).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 170, alignment: .leading)

            FlowChips(items: installables)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

struct FlowChips: View {
    @EnvironmentObject var model: AppModel
    let items: [Installable]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items) { item in
                let installed = model.isInstalled(item.kind, item.version)
                Button {
                    Task { await model.install(item) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: installed ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(installed ? .green : .accentColor)
                        Text(shortName(item.kind)).foregroundStyle(.secondary)
                        Text(item.version).monospacedDigit()
                    }
                    .font(.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(installed || model.isBusy)
                .help(installed ? "Already installed" : "Download and install \(item.kind.rawValue) \(item.version)")
            }
        }
    }

    func shortName(_ k: InstallableKind) -> String {
        switch k { case .sdk: "SDK"; case .runtime: "Runtime"; case .aspnet: "ASP.NET" }
    }
}

struct BusyOverlay: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()
            VStack(spacing: 12) {
                if let p = model.busyProgress {
                    ProgressView(value: p).frame(width: 260)
                    Text("\(Int(p * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
                Text(model.busyMessage ?? "").font(.callout)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Touch ID status

struct TouchIDStatus: View {
    @State private var enabled = TouchIDSudo.isEnabled
    @State private var showHelp = false
    @State private var copied = false

    var body: some View {
        Button { showHelp = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "touchid")
                    .foregroundStyle(enabled ? Color.green : Color.secondary)
                Text(enabled ? "Touch ID: on" : "Touch ID: off")
                Spacer()
                if !enabled { Text("Set up").foregroundStyle(Color.accentColor) }
            }
            .font(.caption)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            enabled = TouchIDSudo.isEnabled
        }
        .sheet(isPresented: $showHelp) {
            VStack(alignment: .leading, spacing: 14) {
                Label(enabled ? "Touch ID is enabled" : "Use Touch ID for installs and uninstalls",
                      systemImage: "touchid").font(.title3.weight(.semibold))
                if enabled {
                    Text("Admin actions will ask for your fingerprint. If you cancel or Touch ID isn't available, you'll get the regular password dialog instead.")
                } else {
                    Text("Admin actions run through sudo. macOS can approve sudo with Touch ID, but it's off by default. To turn it on, run this once in Terminal (it asks for your password):")
                    HStack {
                        Text(TouchIDSudo.enableCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(TouchIDSudo.enableCommand, forType: .string)
                            copied = true
                        }
                    }
                    Text("This uses Apple's own template in /etc/pam.d/sudo_local, which survives macOS updates. It also enables Touch ID for sudo in Terminal. Until then, the app asks for your password.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Done") { showHelp = false; enabled = TouchIDSudo.isEnabled }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 520)
        }
    }
}

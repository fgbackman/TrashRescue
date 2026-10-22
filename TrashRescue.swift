// TrashRescue.swift
// Get files back after emptying the Trash on an Apple Silicon Mac — from the places a copy can still exist:
//   1. APFS local snapshots (made hourly by macOS when Time Machine is set up, kept ~24 h)
//   2. Time Machine backups
//   3. iCloud Drive / Photos / Notes "Recently Deleted"
//
// Build & run in Terminal (needs Xcode or Command Line Tools: xcode-select --install):
//   ./build.sh        → builds TrashRescue.app (Dock icon + menu-bar icon) and opens it
//
// Nothing on your disk is changed. Snapshots are mounted read-only; recovered files are
// copied to ~/Desktop/Recovered from Trash.

import SwiftUI
import AppKit

// MARK: - Shell helpers

@discardableResult
func sh(_ tool: String, _ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Runs a shell command as root through the standard macOS password prompt.
func shAsAdmin(_ command: String) -> (ok: Bool, out: String) {
    let escaped = command
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let source = "do shell script \"\(escaped)\" with administrator privileges"
    var error: NSDictionary?
    guard let script = NSAppleScript(source: source) else { return (false, "Couldn't build the admin request.") }
    let result = script.executeAndReturnError(&error)
    if let error {
        return (false, error[NSAppleScript.errorMessage] as? String ?? "\(error)")
    }
    return (true, result.stringValue ?? "")
}

/// The device behind the user-data volume, e.g. /dev/disk3s5.
func dataVolumeDevice() -> String? {
    var fs = statfs()
    guard statfs("/System/Volumes/Data", &fs) == 0 else { return nil }
    return withUnsafeBytes(of: fs.f_mntfromname) { raw in
        String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
    }
}

func openApp(_ bundleID: String) {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Models

struct Snapshot: Identifiable, Hashable {
    let name: String              // com.apple.TimeMachine.2026-10-09-153012.local
    var id: String { name }

    var date: Date? {
        guard let stamp = name.split(separator: ".")
            .first(where: { $0.count == 17 && $0.first?.isNumber == true }) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.date(from: String(stamp))
    }
    var label: String {
        guard let date else { return name }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
    var mountPoint: String { "/private/tmp/TrashRescue/\(name)" }
    var isMounted: Bool { FileManager.default.fileExists(atPath: mountPoint + "/Users") }
}

struct TrashItem: Identifiable, Hashable {
    let url: URL
    let isFolder: Bool
    let bytes: Int64
    let modified: Date?
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

enum Page: Hashable {
    case snapshot(String)
    case timeMachine
    case cloud
}

// MARK: - Logic

@MainActor
final class Rescue: ObservableObject {
    @Published var snapshots: [Snapshot] = []
    @Published var items: [TrashItem] = []
    @Published var picked = Set<URL>()
    @Published var status = ""
    @Published var busy = false
    @Published var tmInfo = ""
    @Published var mountTick = 0   // forces a redraw after mount / unmount

    let homeRel = String(FileManager.default.homeDirectoryForCurrentUser.path.dropFirst())   // "Users/fred"
    let recoverDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/Recovered from Trash", isDirectory: true)

    @Published var loaded = false

    init() { refresh() }

    /// Asks tmutil for snapshots and backup info on a background thread so the window never freezes.
    func refresh() {
        busy = true
        status = "Looking for snapshots…"
        Task.detached(priority: .userInitiated) {
            let snapOut = sh("/usr/bin/tmutil", ["listlocalsnapshots", "/"]).out
            let found = snapOut.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("com.apple.TimeMachine") }
                .map { Snapshot(name: $0) }
                .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            let info = sh("/usr/bin/tmutil", ["destinationinfo"]).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                self.snapshots = found
                self.tmInfo = info
                self.busy = false
                self.loaded = true
                self.status = found.isEmpty
                    ? "No local snapshots on this Mac (macOS only makes them when Time Machine is set up). Check the Time Machine and iCloud pages."
                    : "\(found.count) snapshot(s) found. Pick the newest one from BEFORE you emptied the Trash."
            }
        }
    }

    func trashURL(_ s: Snapshot) -> URL {
        URL(fileURLWithPath: s.mountPoint)
            .appendingPathComponent(homeRel)
            .appendingPathComponent(".Trash")
    }

    func mount(_ s: Snapshot) {
        guard let dev = dataVolumeDevice() else { status = "Couldn't find this Mac's Data volume."; return }
        status = "Waiting for your password…"
        let cmd = "mkdir -p '\(s.mountPoint)' && /sbin/mount_apfs -o nobrowse -s '\(s.name)' '\(dev)' '\(s.mountPoint)'"
        let r = shAsAdmin(cmd)
        mountTick += 1
        if r.ok || s.isMounted {
            status = "Mounted read-only."
            loadTrash(s)
        } else {
            status = "Mount failed: \(r.out)  — If it says 'Operation not permitted', add Trash Rescue under System Settings › Privacy & Security › Full Disk Access, relaunch it, and try again."
        }
    }

    func unmount(_ s: Snapshot) {
        let r = shAsAdmin("/sbin/umount '\(s.mountPoint)' && rmdir '\(s.mountPoint)'")
        mountTick += 1
        items = []
        picked = []
        status = r.ok ? "Unmounted." : "Unmount failed: \(r.out)"
    }

    func openInFinder(_ s: Snapshot) {
        NSWorkspace.shared.open(URL(fileURLWithPath: s.mountPoint).appendingPathComponent(homeRel))
    }

    func loadTrash(_ s: Snapshot) {
        items = []
        picked = []
        guard s.isMounted else { return }
        let trash = trashURL(s)
        let when = s.label
        busy = true
        status = "Reading the Trash as it was at \(when)…"
        Task.detached(priority: .userInitiated) {
            let result = Rescue.scan(trash)
            await MainActor.run {
                self.busy = false
                switch result {
                case .success(let list):
                    self.items = list
                    self.status = list.isEmpty
                        ? "The Trash was empty at \(when) — try an older snapshot."
                        : "\(list.count) item(s) were in the Trash at \(when). Select and recover."
                case .failure(let err):
                    self.status = "Couldn't read the snapshot's Trash: \(err.localizedDescription). Add Trash Rescue under System Settings › Privacy & Security › Full Disk Access, relaunch it, and try again."
                }
            }
        }
    }

    func recover(all: Bool) {
        let chosen = items.filter { all || picked.contains($0.url) }
        guard !chosen.isEmpty else { status = "Select something first."; return }
        let dest = recoverDir
        busy = true
        status = "Copying \(chosen.count) item(s)…"
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            var copied = 0
            var failed: [String] = []
            for item in chosen {
                let target = Rescue.uniqueURL(in: dest, for: item.name)
                do {
                    try fm.copyItem(at: item.url, to: target)
                    copied += 1
                } catch {
                    failed.append("\(item.name): \(error.localizedDescription)")
                }
            }
            let n = copied
            let fails = failed
            await MainActor.run {
                self.busy = false
                self.status = fails.isEmpty
                    ? "Recovered \(n) item(s) to Desktop › Recovered from Trash."
                    : "Recovered \(n); \(fails.count) failed — \(fails.joined(separator: "; "))"
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            }
        }
    }

    nonisolated static func scan(_ dir: URL) -> Result<[TrashItem], Error> {
        let keys: [URLResourceKey] = [.isDirectoryKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys, options: [])
            let list = urls
                .filter { $0.lastPathComponent != ".DS_Store" }
                .map { url -> TrashItem in
                    let v = try? url.resourceValues(forKeys: Set(keys))
                    let isDir = v?.isDirectory ?? false
                    return TrashItem(url: url,
                                     isFolder: isDir,
                                     bytes: isDir ? folderSize(url) : Int64(v?.totalFileAllocatedSize ?? 0),
                                     modified: v?.contentModificationDate)
                }
                .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            return .success(list)
        } catch {
            return .failure(error)
        }
    }

    nonisolated static func folderSize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url,
                                               includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                               options: [], errorHandler: nil)
        while let f = e?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    nonisolated static func uniqueURL(in dir: URL, for name: String) -> URL {
        var url = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }
}

// MARK: - Views

struct Banner: View {
    var body: some View {
        Label("On an Apple Silicon Mac, emptying the Trash destroys each file's encryption key, so \"undelete\" scanners can't rebuild the files from the disk. A copy can only survive in a snapshot, a backup, or iCloud — this app checks those.",
              systemImage: "info.circle")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SnapshotDetail: View {
    @ObservedObject var vm: Rescue
    let snap: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Snapshot from \(snap.label)").font(.title2.bold())
            if !snap.isMounted {
                Text("This is a frozen, read-only copy of your disk that macOS took automatically. If it was taken before you emptied the Trash, your files are inside it. Mounting asks for your Mac password and changes nothing on your disk.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Mount read-only & show the Trash") { vm.mount(snap) }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.busy)
            } else {
                Table(vm.items, selection: $vm.picked) {
                    TableColumn("Name") { i in
                        Label(i.name, systemImage: i.isFolder ? "folder" : "doc")
                    }
                    TableColumn("Size") { i in
                        Text(ByteCountFormatter.string(fromByteCount: i.bytes, countStyle: .file))
                    }
                    .width(90)
                    TableColumn("Modified") { i in
                        Text(i.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    }
                    .width(170)
                }
                .frame(minHeight: 240)

                HStack {
                    Button("Recover selected") { vm.recover(all: false) }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.picked.isEmpty || vm.busy)
                    Button("Recover all") { vm.recover(all: true) }
                        .disabled(vm.items.isEmpty || vm.busy)
                    Spacer()
                    Button("Browse snapshot in Finder") { vm.openInFinder(snap) }
                    Button("Unmount") { vm.unmount(snap) }
                }
            }
        }
    }
}

struct TimeMachineDetail: View {
    let info: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Time Machine backup").font(.title2.bold())
            Text("Time Machine never backs up the Trash folder itself — but it did back up your files where they lived before you trashed them. Open the folder they came from in Finder, open Time Machine, go back to a date before you deleted them, select the files and click Restore.")
                .fixedSize(horizontal: false, vertical: true)
            if info.contains("No destinations") {
                Label("Time Machine isn't set up on this Mac, so there's no backup to restore from here. If you have another Mac or an external drive with backups, check there.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GroupBox("Backup destination") {
                Text(info.isEmpty ? "No information." : info)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Open Time Machine") { openApp("com.apple.backup.launcher") }
                .buttonStyle(.borderedProminent)
        }
    }
}

struct CloudDetail: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("iCloud, Photos & Notes").font(.title2.bold())
            Text("If the files were in iCloud Drive — including Desktop & Documents when they sync to iCloud — iCloud keeps deleted files for 30 days under Recently Deleted.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Open iCloud Drive (then Recently Deleted)") {
                NSWorkspace.shared.open(URL(string: "https://www.icloud.com/iclouddrive/")!)
            }
            .buttonStyle(.borderedProminent)
            Divider()
            Text("Photos and Notes keep their own Recently Deleted for 30 days, separate from the Finder Trash.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Photos") { openApp("com.apple.Photos") }
                Button("Open Notes") { openApp("com.apple.Notes") }
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var vm: Rescue
    @State private var page: Page?

    private func row(_ title: String, _ icon: String, _ target: Page) -> some View {
        let on = page == target
        return Button { page = target } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(on ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pickDefaultPage() {
        guard vm.loaded, page == nil else { return }
        page = vm.snapshots.first.map { .snapshot($0.name) } ?? .timeMachine
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 12)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Trash Rescue").font(.headline)
                    Spacer()
                    Button { vm.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Look for snapshots again")
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        header("Snapshots on this Mac")
                        if vm.snapshots.isEmpty {
                            Text(vm.loaded ? "None found" : "Checking…")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        ForEach(vm.snapshots) { s in
                            row(s.label,
                                s.isMounted ? "externaldrive.fill.badge.checkmark" : "square.stack.3d.down.right",
                                .snapshot(s.name))
                        }
                        header("Other places to look")
                        row("Time Machine backup", "clock.arrow.circlepath", .timeMachine)
                        row("iCloud, Photos & Notes", "icloud", .cloud)
                    }
                    .padding(8)
                }
            }
            .frame(width: 250)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.regularMaterial)

            Divider()

            // Detail
            VStack(alignment: .leading, spacing: 14) {
                Banner()
                switch page {
                case .snapshot(let name):
                    if let s = vm.snapshots.first(where: { $0.name == name }) {
                        SnapshotDetail(vm: vm, snap: s)
                    }
                case .timeMachine:
                    TimeMachineDetail(info: vm.tmInfo)
                case .cloud:
                    CloudDetail()
                case nil:
                    Text("Pick the newest snapshot taken before you emptied the Trash.")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if vm.busy { ProgressView().controlSize(.small) }
                    Text(vm.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { pickDefaultPage() }
        .onChange(of: vm.loaded) { _, _ in pickDefaultPage() }
        .task(id: page) {
            if case .snapshot(let name)? = page,
               let s = vm.snapshots.first(where: { $0.name == name }) {
                vm.loadTrash(s)
            } else {
                vm.items = []
            }
        }
    }
}

// MARK: - App

/// The menu-bar icon: MenuBarIcon.png / @2x from the app bundle, drawn as a template so it
/// turns white in dark mode. Falls back to an SF Symbol when run outside the bundle.
func menuBarIcon() -> NSImage {
    let base = NSImage(named: "MenuBarIcon")?.copy() as? NSImage
        ?? NSImage(systemSymbolName: "trash", accessibilityDescription: "Trash Rescue")!
    base.isTemplate = true
    base.size = NSSize(width: 18, height: 18)
    return base
}

struct MenuBarMenu: View {
    @ObservedObject var vm: Rescue
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(vm.snapshots.isEmpty
             ? "No local snapshots found"
             : "\(vm.snapshots.count) snapshots · newest \(vm.snapshots[0].label)")
        Divider()
        Button("Open Trash Rescue") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")
        Button("Refresh Snapshots") { vm.refresh() }
            .keyboardShortcut("r")
        Button("Show Recovered Files") {
            let dir = vm.recoverDir
            if FileManager.default.fileExists(atPath: dir.path) {
                NSWorkspace.shared.open(dir)
            } else {
                NSWorkspace.shared.open(dir.deletingLastPathComponent())
            }
        }
        Divider()
        Button("Quit Trash Rescue") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let icon = NSImage(named: "AppIcon") { NSApp.applicationIconImage = icon }
        NSApp.activate(ignoringOtherApps: true)
    }
    // Stay alive in the menu bar after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct TrashRescueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var vm = Rescue()

    var body: some Scene {
        WindowGroup("Trash Rescue", id: "main") {
            ContentView(vm: vm).frame(minWidth: 860, minHeight: 560)
        }
        MenuBarExtra {
            MenuBarMenu(vm: vm)
        } label: {
            Image(nsImage: menuBarIcon())
        }
    }
}

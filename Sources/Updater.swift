import Foundation
import AppKit

/// Checks GitHub Releases for a newer version and installs it in place.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repo = "245678000000/PixelShift"
    private let lastCheckKey = "update.lastCheck"
    private let autoKey = "update.auto"
    private let skipKey = "update.skipVersion"

    @Published var isChecking = false
    @Published var isInstalling = false

    var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoKey); objectWillChange.send() }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
        var zipAsset: Asset? { assets.first { $0.name.lowercased().hasSuffix(".zip") } }
    }

    /// Called at launch: checks at most once a day, silently unless an update exists.
    func checkOnLaunch() {
        guard autoCheck else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let release = try await fetchLatest()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
            let newer = Self.compare(release.version, Self.currentVersion) > 0
            if newer {
                if !userInitiated, UserDefaults.standard.string(forKey: skipKey) == release.version { return }
                promptUpdate(release)
            } else if userInitiated {
                info("已是最新版本", "PixelShift \(Self.currentVersion) 是目前的最新版本。")
            }
        } catch {
            if userInitiated { info("检查更新失败", error.localizedDescription) }
        }
    }

    private func fetchLatest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("PixelShift/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "Updater", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: http.statusCode == 404 ? "还没有发布任何版本" : "服务器返回 \(http.statusCode)"])
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// Numeric dotted-version comparison: "1.10" > "1.9".
    static func compare(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    // MARK: UI

    private func promptUpdate(_ r: Release) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 PixelShift \(r.version)"
        alert.informativeText = "当前版本 \(Self.currentVersion)。"
        let notes = (r.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 180))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let tv = NSTextView(frame: scroll.bounds)
            tv.isEditable = false
            tv.font = .systemFont(ofSize: 12)
            tv.string = notes
            tv.textContainerInset = NSSize(width: 6, height: 6)
            tv.autoresizingMask = [.width]
            scroll.documentView = tv
            alert.accessoryView = scroll
        }
        let canInstall = r.zipAsset != nil
        alert.addButton(withTitle: canInstall ? "立即更新" : "前往下载")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "跳过此版本")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let asset = r.zipAsset { Task { await install(asset.browser_download_url, release: r) } }
            else { NSWorkspace.shared.open(r.html_url) }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(r.version, forKey: skipKey)
        default: break
        }
    }

    private func info(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // MARK: Install

    private func install(_ url: URL, release: Release) async {
        isInstalling = true
        defer { isInstalling = false }
        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        do {
            let (tmpZip, _) = try await URLSession.shared.download(from: url)
            let work = fm.temporaryDirectory.appendingPathComponent("PixelShift-update-\(UUID().uuidString)")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try run("/usr/bin/ditto", ["-x", "-k", tmpZip.path, work.path])
            guard let newApp = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }) else {
                throw NSError(domain: "Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: "下载包里没有找到应用"])
            }
            _ = try? run("/usr/bin/xattr", ["-cr", newApp.path])

            guard fm.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
                throw NSError(domain: "Updater", code: 2, userInfo: [NSLocalizedDescriptionKey: "没有权限写入 \(current.deletingLastPathComponent().path)"])
            }
            _ = try fm.replaceItemAt(current, withItemAt: newApp)
            relaunch(current)
        } catch {
            let a = NSAlert()
            a.messageText = "自动更新失败"
            a.informativeText = "\(error.localizedDescription)\n\n可以前往网页手动下载新版本。"
            a.addButton(withTitle: "前往下载")
            a.addButton(withTitle: "取消")
            if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.html_url) }
        }
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "Updater", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\((tool as NSString).lastPathComponent) 执行失败"])
        }
        return p.terminationStatus
    }

    private func relaunch(_ app: URL) {
        // Wait for this process to exit, then reopen the (new) app.
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"\(app.path)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try? p.run()
        NSApp.terminate(nil)
    }
}

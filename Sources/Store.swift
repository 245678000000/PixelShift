import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var options: ConversionOptions
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var options: ConversionOptions { didSet { save() } }
    @Published var presets: [Preset] { didSet { save() } }

    private let optionsKey = "options.v1", presetsKey = "presets.v1"

    init() {
        let d = UserDefaults.standard
        options = d.data(forKey: optionsKey).flatMap { try? JSONDecoder().decode(ConversionOptions.self, from: $0) } ?? ConversionOptions()
        presets = d.data(forKey: presetsKey).flatMap { try? JSONDecoder().decode([Preset].self, from: $0) } ?? []
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(options), forKey: optionsKey)
        d.set(try? JSONEncoder().encode(presets), forKey: presetsKey)
    }

    func saveCurrentAsPreset() {
        let alert = NSAlert()
        alert.messageText = "存储为预置"
        alert.informativeText = "为当前的格式与设置命名："
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "例如：微信发图 500kB"
        alert.accessoryView = field
        alert.addButton(withTitle: "存储")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        presets.append(Preset(name: name.isEmpty ? "预置 \(presets.count + 1)" : name, options: options))
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            options.customFolderPath = url.path
            options.destination = .custom
        }
    }
}

enum TaskStatus: Equatable {
    case pending, running
    case done(URL, Int, CGSize)
    case failed(String)
}

@MainActor
final class TaskItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    @Published var thumbnail: NSImage?
    @Published var fileSize: Int = 0
    @Published var pixelSize: CGSize = .zero
    @Published var typeName: String = ""
    @Published var status: TaskStatus = .pending
    @Published var crop: CGRect?
    /// Per-file settings; nil = follow the global settings.
    @Published var override: ConversionOptions?

    init(url: URL) {
        self.url = url
        typeName = url.pathExtension.uppercased()
        loadInfo()
    }

    var name: String { url.deletingPathExtension().lastPathComponent }

    private func loadInfo() {
        let url = self.url
        Task.detached(priority: .utility) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var px = CGSize.zero  // computed below
            var thumb: CGImage?
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
                if let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                    let w = p[kCGImagePropertyPixelWidth] as? Int ?? 0
                    let h = p[kCGImagePropertyPixelHeight] as? Int ?? 0
                    let o = p[kCGImagePropertyOrientation] as? Int ?? 1
                    px = o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
                }
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 640,
                ]
                thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            }
            let finalThumb = thumb
            let finalPx = px
            await MainActor.run {
                self.fileSize = size
                self.pixelSize = finalPx
                if let t = finalThumb { self.thumbnail = NSImage(cgImage: t, size: .zero) }
            }
        }
    }
}

@MainActor
final class TaskStore: ObservableObject {
    static let shared = TaskStore()

    @Published var items: [TaskItem] = []
    let settings = SettingsStore()

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        q.qualityOfService = .userInitiated
        return q
    }()

    var runningCount: Int { items.filter { $0.status == .running }.count }
    var doneCount: Int { items.filter { if case .done = $0.status { return true }; return false }.count }
    var pendingCount: Int { items.filter { if case .pending = $0.status { return true }; if case .failed = $0.status { return true }; return false }.count }

    // MARK: Adding

    func add(_ urls: [URL]) {
        let existing = Set(items.map { $0.url.standardizedFileURL })
        var seen = existing
        for url in expand(urls) {
            let std = url.standardizedFileURL
            guard !seen.contains(std) else { continue }
            seen.insert(std)
            items.append(TaskItem(url: std))
        }
    }

    private func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let e = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let f = e?.nextObject() as? URL { if isImage(f) { out.append(f) } }
            } else if isImage(url) {
                out.append(url)
            }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func isImage(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension) else { return false }
        return t.conforms(to: .image)
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image, .folder]
        panel.prompt = "添加"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func handleDrop(_ providers: [NSItemProvider]) {
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in TaskStore.shared.add([url]) }
            }
        }
    }

    // MARK: Converting

    func convertAll() {
        for item in items {
            switch item.status {
            case .pending, .failed: convert(item)
            default: break
            }
        }
    }

    func convert(_ item: TaskItem) {
        if item.status == .running { return }
        objectWillChange.send()
        item.status = .running
        let url = item.url
        let opts = item.override ?? settings.options
        let crop = item.crop
        queue.addOperation {
            let result = Result { try Converter.convert(url, options: opts, crop: crop) }
            Task { @MainActor in
                TaskStore.shared.objectWillChange.send()
                var entry = HistoryEntry(date: Date(), sourcePath: url.path, outputPath: nil,
                                         format: opts.format.rawValue, sourceBytes: item.fileSize,
                                         outputBytes: 0, width: 0, height: 0, error: nil)
                switch result {
                case .success(let r):
                    item.status = .done(r.url, r.bytes, r.pixelSize)
                    entry.outputPath = r.url.path; entry.outputBytes = r.bytes
                    entry.width = Int(r.pixelSize.width); entry.height = Int(r.pixelSize.height)
                case .failure(let e):
                    item.status = .failed(e.localizedDescription)
                    entry.error = e.localizedDescription
                }
                HistoryStore.shared.record(entry)
            }
        }
    }

    func reset(_ item: TaskItem) { if item.status != .running { objectWillChange.send(); item.status = .pending } }

    func remove(_ item: TaskItem) { items.removeAll { $0.id == item.id } }

    func removeAll() { items.removeAll { $0.status != .running } }

    func removeFinished() {
        items.removeAll { if case .done = $0.status { return true }; return false }
    }

    func revealOutputs() {
        let urls = items.compactMap { item -> URL? in
            if case .done(let u, _, _) = item.status { return u }
            return nil
        }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
}

func formatBytes(_ n: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
}

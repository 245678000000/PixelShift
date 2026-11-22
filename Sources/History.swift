import SwiftUI
import AppKit
import ImageIO

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var sourcePath: String
    var outputPath: String?
    var format: String
    var sourceBytes: Int
    var outputBytes: Int
    var width: Int
    var height: Int
    var error: String?

    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
    var outputURL: URL? { outputPath.map { URL(fileURLWithPath: $0) } }
    var succeeded: Bool { error == nil && outputPath != nil }
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    @Published private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PixelShift", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private init() {
        if let d = try? Data(contentsOf: fileURL),
           let e = try? JSONDecoder().decode([HistoryEntry].self, from: d) {
            entries = e
        }
    }

    func record(_ e: HistoryEntry) {
        entries.insert(e, at: 0)
        if entries.count > 2000 { entries.removeLast(entries.count - 2000) }
        save()
    }

    func remove(_ e: HistoryEntry) { entries.removeAll { $0.id == e.id }; save() }
    func clear() { entries.removeAll(); save() }

    private func save() {
        if let d = try? JSONEncoder().encode(entries) { try? d.write(to: fileURL, options: .atomic) }
    }
}

// MARK: - Window

struct HistoryView: View {
    @EnvironmentObject var history: HistoryStore
    @State private var query = ""
    @State private var confirmClear = false

    private var filtered: [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return history.entries }
        return history.entries.filter {
            $0.sourcePath.localizedCaseInsensitiveContains(q)
                || ($0.outputPath?.localizedCaseInsensitiveContains(q) ?? false)
                || $0.format.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        Group {
            if filtered.isEmpty {
                Text(query.isEmpty ? "没有相关历史记录" : "没有匹配“\(query)”的记录")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groupedByDay, id: \.0) { day, items in
                        Section(day) {
                            ForEach(items) { HistoryRow(entry: $0) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 560, minHeight: 320)
        .navigationTitle("历史记录")
        .searchable(text: $query, placement: .toolbar, prompt: "搜索")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("清空") { confirmClear = true }.disabled(history.entries.isEmpty)
            }
        }
        .confirmationDialog("清空全部历史记录？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { history.clear() }
        } message: {
            Text("只删除记录，不会删除已转换的文件。")
        }
    }

    private var groupedByDay: [(String, [HistoryEntry])] {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "yyyy年M月d日 EEEE"
        var result: [(String, [HistoryEntry])] = []
        for e in filtered {
            let label: String
            if cal.isDateInToday(e.date) { label = "今天" }
            else if cal.isDateInYesterday(e.date) { label = "昨天" }
            else { label = fmt.string(from: e.date) }
            if result.last?.0 == label { result[result.count - 1].1.append(e) }
            else { result.append((label, [e])) }
        }
        return result
    }
}

struct HistoryRow: View {
    @EnvironmentObject var history: HistoryStore
    let entry: HistoryEntry
    @State private var thumb: NSImage?

    private var outputExists: Bool {
        entry.outputPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06))
                if let thumb { Image(nsImage: thumb).resizable().scaledToFill() }
                else { Image(systemName: entry.succeeded ? "photo" : "exclamationmark.triangle").foregroundStyle(.tertiary) }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.sourceURL.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(entry.outputURL?.lastPathComponent ?? entry.format)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(entry.succeeded ? .primary : .secondary)
                }
                .font(.system(size: 13, weight: .medium))
                Text(verbatim: detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(entry.date, format: .dateTime.hour().minute()).font(.system(size: 11)).foregroundStyle(.tertiary)
            if entry.succeeded {
                Button { reveal() } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).disabled(!outputExists).help("在 Finder 中显示")
            }
        }
        .padding(.vertical, 3)
        .opacity(entry.succeeded && !outputExists ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if outputExists, let u = entry.outputURL { NSWorkspace.shared.open(u) } }
        .contextMenu {
            if let u = entry.outputURL, outputExists {
                Button("打开") { NSWorkspace.shared.open(u) }
                Button("在 Finder 中显示") { reveal() }
            }
            if FileManager.default.fileExists(atPath: entry.sourcePath) {
                Button("在 Finder 中显示原文件") { NSWorkspace.shared.activateFileViewerSelecting([entry.sourceURL]) }
                Button("重新加入转换列表") { TaskStore.shared.add([entry.sourceURL]) }
            }
            Divider()
            Button("删除此记录") { history.remove(entry) }
        }
        .task(id: entry.id) { thumb = await loadThumb() }
    }

    private var detail: String {
        if let err = entry.error { return "\(entry.format) · 失败：\(err)" }
        var parts = [entry.format, "\(entry.width)×\(entry.height)",
                     "\(formatBytes(entry.sourceBytes)) → \(formatBytes(entry.outputBytes))"]
        if entry.sourceBytes > 0 {
            let pct = Int((Double(entry.outputBytes) / Double(entry.sourceBytes) - 1) * 100)
            parts.append(pct <= 0 ? "\(pct)%" : "+\(pct)%")
        }
        if !outputExists { parts.append("文件已不存在") }
        return parts.joined(separator: " · ")
    }

    private func reveal() {
        if let u = entry.outputURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    private func loadThumb() async -> NSImage? {
        let paths = [outputExists ? entry.outputPath : nil, entry.sourcePath].compactMap { $0 }
        return await Task.detached(priority: .utility) { () -> NSImage? in
            guard let src = paths.lazy.compactMap({ p -> CGImageSource? in
                guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
                      CGImageSourceGetCount(s) > 0 else { return nil }
                return s
            }).first else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 120,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: .zero)
        }.value
    }
}

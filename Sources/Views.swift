import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: TaskStore
    @EnvironmentObject var settings: SettingsStore
    @State private var showSettings = false
    @State private var dropTargeted = false
    @State private var showHelp = false
    @Environment(\.openWindow) private var openWindow
    @AppStorage("viewMode") private var viewMode = "grid"

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider()
                if store.items.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        if viewMode == "grid" {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                                ForEach(store.items) { TaskCell(item: $0, style: .grid) }
                            }
                            .padding(12)
                        } else {
                            LazyVStack(spacing: 10) {
                                ForEach(store.items) { TaskCell(item: $0, style: .list) }
                            }
                            .padding(12)
                        }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
            .padding(12)

            bottomBar
        }
        .frame(minWidth: 560, minHeight: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            store.handleDrop(providers); return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.06))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .alert("使用说明", isPresented: $showHelp) {
            Button("好") {}
        } message: {
            Text("1. 把图片或文件夹拖进窗口，或点左下角 +。\n2. 在顶部选择输出格式，点齿轮调整大小、体积上限、旋转/翻转、目标文件夹。\n3. 点 ▶ 开始转换（⌘↩ 全部开始）。\n\n常用设置可在齿轮面板中“存储为预置”。")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("图片").font(.system(size: 14, weight: .medium))
            Text("—").foregroundStyle(.secondary)
            Picker("", selection: $settings.options.format) {
                Section("图片") {
                    ForEach(OutputFormat.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            .labelsHidden()
            .fixedSize()

            if !settings.presets.isEmpty {
                Menu {
                    ForEach(settings.presets) { p in
                        Button(p.name) { settings.options = p.options }
                    }
                } label: { Label("预置", systemImage: "square.stack") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Spacer()
            Text(settings.options.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Picker("", selection: $viewMode) {
                Image(systemName: "square.grid.2x2").help("网格").tag("grid")
                Image(systemName: "list.bullet").help("列表").tag("list")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Button { showSettings.toggle() } label: {
                Image(systemName: "gearshape").font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .help("转换设置")
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                SettingsPanel().environmentObject(settings)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    // MARK: Empty / footer

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text("把图片或文件夹拖到这里").font(.title3).foregroundStyle(.secondary)
            Text("支持 HEIC、JPEG、PNG、TIFF、WebP、GIF、BMP、RAW 等").font(.caption).foregroundStyle(.tertiary)
            Button("选择文件…") { store.openPanel() }.controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var progressText: String {
        let total = store.items.count
        if total == 0 { return "没有转换任务" }
        if store.runningCount > 0 { return "正在转换 \(store.doneCount)/\(total)…" }
        if store.doneCount == total { return "\(total) 个任务已完成" }
        return "\(total) 个转换任务"
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Button { store.openPanel() } label: { Image(systemName: "plus") }.help("添加文件 (⌘O)")
            Button { store.revealOutputs() } label: { Image(systemName: "folder") }
                .disabled(store.doneCount == 0).help("在 Finder 中显示结果 (⌘R)")
            Spacer()
            Text(progressText).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button { store.removeFinished() } label: { Image(systemName: "checkmark.circle") }
                .disabled(store.doneCount == 0).help("移除已完成")
            Button { store.removeAll() } label: { Image(systemName: "xmark.circle") }
                .disabled(store.items.isEmpty).help("移除全部 (⌘⌫)")
            Button { openWindow(id: "history") } label: { Image(systemName: "clock") }.help("显示历史记录 (⌘Y)")
            Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }.help("帮助")
            Button { store.convertAll() } label: {
                Label("全部开始", systemImage: "play.fill").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(store.pendingCount == 0)
            .help("全部开始 (⌘↩)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 15))
        .padding(.leading, 16).padding(.trailing, 12)
        .padding(.top, 2).padding(.bottom, 10)
    }

}


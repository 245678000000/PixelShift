import SwiftUI
import AppKit

enum CellStyle { case list, grid }

struct TaskCell: View {
    @EnvironmentObject var store: TaskStore
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject var item: TaskItem
    let style: CellStyle
    @State private var hovering = false
    @State private var showCrop = false
    @State private var showSettings = false

    var body: some View {
        Group {
            if style == .grid { gridBody } else { listBody }
        }
        .onHover { hovering = $0 }
        .sheet(isPresented: $showCrop) { CropSheet(item: item).environmentObject(store) }
        .contextMenu { menu }
    }

    // MARK: Layouts

    private var listBody: some View {
        HStack(spacing: 12) {
            thumb.frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    badges
                }
                Text(info).font(.system(size: 11)).foregroundStyle(.secondary)
                statusLine
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                primaryActions
                cropButton
                gearButton
                removeButton
            }
            .buttonStyle(.borderless)
            .font(.system(size: 14))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.07 : 0.04)))
    }

    private var gridBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color.primary.opacity(0.06)
                thumb
                HStack(spacing: 4) { badges }.padding(8)
            }
            .frame(height: 170)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(alignment: .topTrailing) {
                removeButton
                    .buttonStyle(.borderless)
                    .font(.system(size: 17))
                    .background(Circle().fill(.white).padding(3))
                    .padding(7)
                    .opacity(hovering || item.status != .pending ? 1 : 0.75)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(info).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                statusLine.frame(height: 16, alignment: .leading)
            }
            .padding(.horizontal, 10).padding(.top, 8)

            HStack(spacing: 12) {
                primaryActions
                Spacer()
                cropButton
                gearButton
            }
            .buttonStyle(.borderless)
            .font(.system(size: 14))
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(hovering ? 0.07 : 0.04)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
    }

    // MARK: Parts

    @ViewBuilder private var thumb: some View {
        if let t = item.thumbnail {
            Image(nsImage: t).resizable().interpolation(.high).scaledToFill()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
        } else {
            Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var badges: some View {
        if let o = item.override {
            badge(o.format.rawValue + " · 单独设置", color: .purple)
        }
        if item.crop != nil { badge("已裁切", color: .blue) }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.85)))
    }

    private var info: String {
        var parts = [formatBytes(item.fileSize)]
        if item.pixelSize != .zero { parts.append("\(Int(item.pixelSize.width))×\(Int(item.pixelSize.height))") }
        parts.append(item.typeName)
        if let c = item.crop, item.pixelSize != .zero {
            parts.append("裁切为 \(Int((c.width * item.pixelSize.width).rounded()))×\(Int((c.height * item.pixelSize.height).rounded()))")
        }
        return parts.joined(separator: " • ")
    }

    @ViewBuilder private var statusLine: some View {
        switch item.status {
        case .pending:
            Text("等待开始").font(.system(size: 11)).foregroundStyle(.tertiary)
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("转换中…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .done(let u, let bytes, let size):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(verbatim: "\(u.lastPathComponent) · \(formatBytes(bytes)) · \(Int(size.width))×\(Int(size.height))")
                    .lineLimit(1).truncationMode(.middle)
                if item.fileSize > 0 {
                    let pct = Int((Double(bytes) / Double(item.fileSize) - 1) * 100)
                    Text(verbatim: pct <= 0 ? "\(pct)%" : "+\(pct)%")
                        .foregroundStyle(pct <= 0 ? Color.green : Color.orange)
                }
            }
            .font(.system(size: 11))
        case .failed(let msg):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(msg).foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.system(size: 11))
        }
    }

    @ViewBuilder private var primaryActions: some View {
        switch item.status {
        case .pending, .failed:
            Button { store.convert(item) } label: { Image(systemName: "play.fill") }.help("开始")
        case .running:
            ProgressView().controlSize(.small)
        case .done(let u, _, _):
            Button { NSWorkspace.shared.activateFileViewerSelecting([u]) } label: {
                Image(systemName: "magnifyingglass")
            }.help("在 Finder 中显示")
            Button { store.reset(item); store.convert(item) } label: {
                Image(systemName: "arrow.clockwise")
            }.help("重新转换")
        }
    }

    private var cropButton: some View {
        Button { showCrop = true } label: {
            Image(systemName: "crop").foregroundStyle(item.crop == nil ? Color.primary : Color.accentColor)
        }
        .help(item.crop == nil ? "裁切" : "编辑裁切")
        .disabled(item.status == .running)
    }

    private var gearButton: some View {
        Button { showSettings.toggle() } label: {
            Image(systemName: "gearshape").foregroundStyle(item.override == nil ? Color.primary : Color.purple)
        }
        .help(item.override == nil ? "为这张图单独设置" : "编辑单独设置")
        .disabled(item.status == .running)
        .popover(isPresented: $showSettings, arrowEdge: .bottom) {
            ItemSettingsPanel(item: item).environmentObject(store).environmentObject(settings)
        }
    }

    private var removeButton: some View {
        Button { store.remove(item) } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .help("移除")
        .disabled(item.status == .running)
    }

    @ViewBuilder private var menu: some View {
        Button("在 Finder 中显示原文件") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        if case .done(let u, _, _) = item.status {
            Button("在 Finder 中显示结果") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
            Button("打开结果") { NSWorkspace.shared.open(u) }
            Button("重新转换") { store.reset(item); store.convert(item) }
        }
        Divider()
        Button("裁切…") { showCrop = true }
        if item.crop != nil { Button("取消裁切") { item.crop = nil; store.reset(item) } }
        Button("单独设置…") { showSettings = true }
        if item.override != nil { Button("恢复为全局设置") { item.override = nil; store.reset(item) } }
        Divider()
        Button("移除") { store.remove(item) }
    }
}

// MARK: - Summary

extension ConversionOptions {
    var summary: String {
        var parts: [String] = []
        if format.isLossy { parts.append("质量 \(Int(quality * 100))%") }
        if resizeEnabled {
            switch resizeMode {
            case .percent: parts.append("缩放 \(Int(resizePercent))%")
            case .longEdge: parts.append("长边 \(resizeLongEdge)px")
            case .exact: parts.append("\(resizeWidth)×\(resizeHeight)")
            }
        }
        if sizeLimitEnabled { parts.append("≤ \(sizeLimitKB) kB") }
        if transform != .none { parts.append(transform.rawValue) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Shared options editor

struct OptionsEditor: View {
    @Binding var options: ConversionOptions
    var showFormat = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showFormat {
                row("格式") {
                    Picker("", selection: $options.format) {
                        ForEach(OutputFormat.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }

            row("目标文件夹") {
                Menu {
                    Button("与原文件相同") { options.destination = .sameAsSource }
                    if let p = options.customFolderPath {
                        Button((p as NSString).lastPathComponent) { options.destination = .custom }
                    }
                    Divider()
                    Button("选择文件夹…") {
                        if let p = chooseFolderPath() { options.customFolderPath = p; options.destination = .custom }
                    }
                } label: { Text(folderLabel) }
                .fixedSize()
            }

            if options.format.isLossy {
                row("质量") {
                    HStack {
                        Slider(value: $options.quality, in: 0.1...1, step: 0.01).frame(width: 180)
                        Text(verbatim: "\(Int(options.quality * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("调整大小", isOn: $options.resizeEnabled)
                if options.resizeEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: $options.resizeMode) {
                            ForEach(ResizeMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                        switch options.resizeMode {
                        case .percent:
                            HStack { numberField($options.resizePercent); Text("%") }
                        case .longEdge:
                            HStack { numberField($options.resizeLongEdge); Text("像素") }
                        case .exact:
                            HStack {
                                numberField($options.resizeWidth); Text("×"); numberField($options.resizeHeight); Text("像素")
                            }
                            Toggle("保持宽高比（在框内适配）", isOn: $options.keepAspect)
                        }
                        Toggle("不放大小图", isOn: $options.noUpscale)
                    }
                    .padding(.leading, 20)
                }
            }

            HStack {
                Toggle("文件大小限制 (单位: kB)", isOn: $options.sizeLimitEnabled)
                if options.sizeLimitEnabled { numberField($options.sizeLimitKB) }
            }

            row("转换") {
                Picker("", selection: $options.transform) {
                    ForEach(ImageTransform.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
        }
        .toggleStyle(.checkbox)
    }

    private var folderLabel: String {
        if options.destination == .custom, let p = options.customFolderPath {
            return (p as NSString).lastPathComponent
        }
        return "与原文件相同"
    }

    private func row<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer()
            content()
        }
    }

    private func numberField(_ b: Binding<Int>) -> some View {
        TextField("", value: b, format: .number.grouping(.never)).frame(width: 70).multilineTextAlignment(.trailing)
    }

    private func numberField(_ b: Binding<Double>) -> some View {
        TextField("", value: b, format: .number.grouping(.never)).frame(width: 70).multilineTextAlignment(.trailing)
    }
}

@MainActor func chooseFolderPath() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "选择"
    return panel.runModal() == .OK ? panel.url?.path : nil
}

// MARK: - Global settings popover

struct SettingsPanel: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("全局设置").font(.headline)
            Text("应用于所有没有单独设置的文件。").font(.caption).foregroundStyle(.secondary)
            OptionsEditor(options: $settings.options)
            Divider()
            HStack {
                Menu("预置") {
                    if settings.presets.isEmpty {
                        Text("还没有预置")
                    } else {
                        Section("载入") {
                            ForEach(settings.presets) { p in
                                Button(p.name) { settings.options = p.options }
                            }
                        }
                        Menu("删除") {
                            ForEach(settings.presets) { p in
                                Button(p.name) { settings.presets.removeAll { $0.id == p.id } }
                            }
                        }
                    }
                    Divider()
                    Button("存储当前设置为预置…") { settings.saveCurrentAsPreset() }
                }
                .fixedSize()
                Spacer()
                Button("恢复默认") {
                    let fmt = settings.options.format
                    settings.options = ConversionOptions()
                    settings.options.format = fmt
                }
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

// MARK: - Per-file settings popover

struct ItemSettingsPanel: View {
    @EnvironmentObject var store: TaskStore
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject var item: TaskItem

    private var isOn: Binding<Bool> {
        Binding(
            get: { item.override != nil },
            set: { on in
                item.override = on ? settings.options : nil
                store.reset(item)
            })
    }

    private var options: Binding<ConversionOptions> {
        Binding(
            get: { item.override ?? settings.options },
            set: { item.override = $0; store.reset(item) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                Toggle("为这张图单独设置", isOn: isOn).toggleStyle(.switch).controlSize(.small)
            }

            if item.override != nil {
                OptionsEditor(options: options, showFormat: true)
                Divider()
                HStack {
                    Menu("载入预置") {
                        if settings.presets.isEmpty { Text("还没有预置") }
                        ForEach(settings.presets) { p in
                            Button(p.name) { options.wrappedValue = p.options }
                        }
                        Divider()
                        Button("全局设置") { options.wrappedValue = settings.options }
                    }
                    .fixedSize()
                    Spacer()
                    Button("应用到全部文件") {
                        let o = item.override
                        for t in store.items where t.status != .running {
                            t.override = o
                            store.reset(t)
                        }
                    }
                    .help("把这套设置作为所有文件的单独设置")
                }
            } else {
                Text("当前使用全局设置：\(settings.options.format.rawValue)\(settings.options.summary.isEmpty ? "" : " · " + settings.options.summary)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

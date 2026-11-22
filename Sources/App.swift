import SwiftUI
import AppKit

@main
struct PixelShiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = TaskStore.shared

    var body: some Scene {
        Window("PixelShift", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(store.settings)
        }
        .defaultSize(width: 820, height: 600)

        Window("历史记录", id: "history") {
            HistoryView().environmentObject(HistoryStore.shared)
        }
        .defaultSize(width: 760, height: 480)
        .keyboardShortcut("y", modifiers: .command)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加文件…") { store.openPanel() }.keyboardShortcut("o")
            }
            CommandMenu("转换") {
                Button("全部开始") { store.convertAll() }.keyboardShortcut(.return, modifiers: .command)
                Button("在 Finder 中显示结果") { store.revealOutputs() }.keyboardShortcut("r")
                Divider()
                Button("移除已完成") { store.removeFinished() }
                Button("移除全部") { store.removeAll() }.keyboardShortcut(.delete, modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bypass the stale Dock icon cache.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in TaskStore.shared.add(urls) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { model?.busy != true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.busy == true else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Триває запис образу"
        alert.informativeText = "Дочекайтеся завершення або зупиніть запис. Після зупинки накопичувач потрібно буде записати заново."
        alert.addButton(withTitle: "Продовжити запис")
        alert.addButton(withTitle: "Зупинити запис")
        if alert.runModal() == .alertSecondButtonReturn { model?.cancelWrite() }
        return .terminateCancel
    }
}

@main
struct ISOForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("ISO Forge") {
            ContentView(model: model)
                .frame(minWidth: 920, minHeight: 730)
                .preferredColorScheme(.dark)
                .onAppear { delegate.model = model }
                .onOpenURL { model.loadImage($0) }
        }
        .defaultSize(width: 1000, height: 790)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Відкрити ISO або IMG…") { model.chooseImage() }
                    .keyboardShortcut("o").disabled(model.busy)
            }
            CommandMenu("Накопичувач") {
                Button("Оновити список дисків") { model.refreshDisks() }.keyboardShortcut("r").disabled(model.busy)
                Button(model.createTitle + "…") { model.prepareConfirmation() }.disabled(!model.ready)
                Button("Зберегти журнал…") { model.exportLog() }.disabled(model.session == nil)
            }
            CommandGroup(replacing: .help) {
                Button("Як користуватися ISO Forge") { model.showHelp = true }
            }
        }
    }
}

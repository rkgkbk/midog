import SwiftUI
import AppKit

@MainActor
final class MainWindowOpener {
    static let shared = MainWindowOpener()
    static let windowID = "main"

    private var openAction: (() -> Void)?

    private init() {}

    func install(_ action: @escaping () -> Void) {
        openAction = action
    }

    func open() {
        openAction?()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private var isQuitting = false
    private weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureApplicationIcon()
        configureStatusItem()
        ContentFilterInstaller.shared.install()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(observedWindowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )

        Task { @MainActor [weak self] in
            self?.registerExistingWindows()
        }
    }

    private func configureApplicationIcon() {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: iconURL) else { return }
        NSApp.applicationIconImage = image
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 退出 UI 不再结束 launchd 服务。
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        if let button = item.button {
            button.image = NSImage(named: "StatusDog") ?? NSApp.applicationIconImage
            button.image?.isTemplate = false
            button.imagePosition = .imageOnly
            button.toolTip = "midog"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        statusMenu.addItem(withTitle: "显示窗口", action: #selector(showMainWindowFromMenu), keyEquivalent: "")
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "退出", action: #selector(quitApplication), keyEquivalent: "q")
        statusMenu.items.forEach { $0.target = self }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
            return
        }

        showMainWindow()
    }

    @objc private func showMainWindowFromMenu() {
        showMainWindow()
    }

    @objc private func quitApplication() {
        isQuitting = true
        NSApp.terminate(nil)
    }

    @objc private func observedWindowDidBecomeMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        configure(window)
    }

    private func registerExistingWindows() {
        appWindows.forEach(configure)
    }

    func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
        configure(window)
    }

    private func configure(_ window: NSWindow) {
        if mainWindow == nil {
            mainWindow = window
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    private var appWindows: [NSWindow] {
        NSApp.windows.filter { $0.canBecomeMain && !$0.isExcludedFromWindowsMenu }
    }

    private var preferredWindow: NSWindow? {
        if let mainWindow {
            return mainWindow
        }
        return appWindows.first
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        registerExistingWindows()

        if let window = preferredWindow {
            DispatchQueue.main.async { [weak self, weak window] in
                guard let window else { return }
                self?.bringToFront(window)
            }
            return
        }

        MainWindowOpener.shared.open()
        DispatchQueue.main.async { [weak self] in
            self?.registerExistingWindows()
            if let window = self?.preferredWindow {
                self?.bringToFront(window)
            }
        }
    }

    private func bringToFront(_ window: NSWindow) {
        window.deminiaturize(nil)
        window.orderFrontRegardless()
        window.makeMain()
        window.makeKey()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    private func hideMainWindow() {
        appWindows.forEach { $0.orderOut(nil) }
        NSApp.setActivationPolicy(.accessory)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isQuitting else { return true }
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }
}

@main
struct midogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store.shared

    var body: some Scene {
        WindowGroup(id: MainWindowOpener.windowID) {
            RootView()
                .environmentObject(store)
        }
        .windowResizability(.contentMinSize)
    }
}

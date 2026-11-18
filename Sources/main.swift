import Cocoa
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let engine = SyncEngine()
    private let tray = StatusController()
    private let settingsWindow = SettingsWindowController()
    private let activityWindow = ActivityWindowController()
    private let trashWindow = TrashWindowController()
    private let linksWindow = LinksWindowController()
    private let serviceProvider = ServiceProvider()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Возврат из браузера после входа: ydisksync://callback#access_token=...
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        installMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.onStatus = { [weak self] s in
            DispatchQueue.main.async {
                self?.tray.update(s)
                ActivityLog.shared.apply(s)
            }
        }
        engine.onDiskInfo = { [weak self] i in DispatchQueue.main.async { self?.tray.setUsage(i) } }
        tray.onOpenSettings = { [weak self] in self?.openSettings() }
        tray.onOpenActivity = { [weak self] in self?.openActivity() }
        tray.onOpenTrash = { [weak self] in
            self?.trashWindow.show { self?.engine.requestSync() }
        }
        tray.onCreateLink = { LinkService.chooseAndCreate() }
        tray.onOpenLinks = { [weak self] in self?.linksWindow.show() }
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
        ServiceSetup.enableOnFirstLaunch()
        UNUserNotificationCenter.current().delegate = self
        tray.onSyncNow = { [weak self] in self?.engine.requestSync() }
        tray.onConfirmDeletes = { [weak self] in self?.engine.requestSync(allowMassDelete: true) }
        tray.onTogglePause = { [weak self] in
            Settings.shared.paused.toggle()
            self?.engine.reschedule()
        }
        engine.reschedule()
        if !Settings.shared.isConfigured { openSettings() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    private func openActivity() {
        activityWindow.show { [weak self] in self?.engine.requestSync() }
    }

    private func openSettings() {
        settingsWindow.show { [weak self] in self?.engine.reschedule() }
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: s) else { return }
        if let token = OAuth.token(from: url) {
            Settings.shared.token = token
            NotificationCenter.default.post(name: .tokenChanged, object: nil)
            engine.reschedule()
            NSApp.activate(ignoringOtherApps: true)
        } else if let err = OAuth.errorText(from: url) {
            let a = NSAlert()
            a.messageText = "Не удалось войти"
            a.informativeText = err
            a.runModal()
        }
    }

    /// Без главного меню в полях ввода не работают ⌘V / ⌘C.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

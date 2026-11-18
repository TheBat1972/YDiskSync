import Foundation
import Cocoa
import UserNotifications

/// Создание публичных ссылок на файлы из папки синхронизации.
enum LinkService {
    /// «/Users/me/Яндекс Диск/Документы/a.pdf» → «/Документы/a.pdf»
    static func remotePath(forLocal path: String) throws -> String {
        let root = URL(fileURLWithPath: Settings.shared.localFolder).resolvingSymlinksInPath().path
        let p = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard !root.isEmpty, p.hasPrefix(root + "/") else {
            throw SyncError.bad("Файл вне папки синхронизации: " + (path as NSString).lastPathComponent)
        }
        return "/" + String(p.dropFirst(root.count + 1))
    }

    /// Создаёт ссылки в фоне, результат отдаёт в главном потоке.
    static func create(for paths: [String], done: @escaping (Result<[String], Error>) -> Void) {
        guard let token = Settings.shared.token else { done(.failure(SyncError.notConfigured)); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let api = YandexAPI(token: token)
            var urls: [String] = []
            var failure: Error?
            for p in paths {
                do {
                    let url = try api.publish(try remotePath(forLocal: p))
                    urls.append(url)
                    ActivityLog.shared.add(.info, "Создана ссылка: " + (p as NSString).lastPathComponent, url)
                } catch {
                    failure = error
                    ActivityLog.shared.add(.error, "Не удалось создать ссылку: " + (p as NSString).lastPathComponent,
                                           error.localizedDescription)
                }
            }
            DispatchQueue.main.async {
                if urls.isEmpty, let f = failure { done(.failure(f)) } else { done(.success(urls)) }
            }
        }
    }

    /// Создаёт ссылки, копирует их в буфер обмена и сообщает об этом.
    static func createAndCopy(_ paths: [String]) {
        create(for: paths) { result in
            switch result {
            case .success(let urls):
                copy(urls.joined(separator: "\n"))
                notify("Ссылка скопирована", urls.count == 1 ? urls[0] : "Ссылок: \(urls.count)")
            case .failure(let e):
                notify("Не удалось создать ссылку", e.localizedDescription)
            }
        }
    }

    /// Выбор файла в папке синхронизации и создание ссылки.
    static func chooseAndCreate() {
        guard Settings.shared.isConfigured else {
            notify("Сначала настройте синхронизацию", "Подключите аккаунт и выберите папку в настройках")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: Settings.shared.localFolder)
        panel.prompt = "Создать ссылку"
        panel.message = "Выберите файлы или папки внутри папки синхронизации"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { createAndCopy(panel.urls.map { $0.path }) }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func notify(_ title: String, _ body: String) {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { DispatchQueue.main.async { NSSound.beep() }; return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// Пункт «Службы → Ссылка Яндекс Диска» в контекстном меню Finder.
final class ServiceProvider: NSObject {
    @objc func createLink(_ pboard: NSPasteboard, userData: String,
                          error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let urls = pboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            error.pointee = "Не выбрано ни одного файла" as NSString
            return
        }
        let paths = urls.map { $0.path }
        DispatchQueue.main.async { LinkService.createAndCopy(paths) }
    }
}

/// Включает пункт «Ссылка Яндекс Диска» в контекстном меню Finder («Службы»).
/// Отдельного разрешения для этого в macOS нет — это переключатель в настройках служб,
/// поэтому приложение выставляет его само (запись в настройки pbs).
enum ServiceSetup {
    private static let statusKey = "ru.local.YDiskSync - Ссылка Яндекс Диска - createLink"

    static func enable() {
        let domain = "pbs" as CFString
        let key = "NSServicesStatus" as CFString
        var dict = (CFPreferencesCopyAppValue(key, domain) as? [String: Any]) ?? [:]
        dict[statusKey] = [
            "enabled_context_menu": true,
            "enabled_services_menu": true,
            "presentation_modes": ["ContextMenu": true, "FinderPreview": true, "ServicesMenu": true]
        ] as [String: Any]
        CFPreferencesSetAppValue(key, dict as CFDictionary, domain)
        CFPreferencesAppSynchronize(domain)
        NSUpdateDynamicServices()
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
            p.arguments = ["-update"]
            try? p.run()
            p.waitUntilExit()
        }
    }

    /// Один раз при первом запуске.
    static func enableOnFirstLaunch() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "finderServiceEnabledV1") else { return }
        d.set(true, forKey: "finderServiceEnabledV1")
        enable()
        LinkService.notify("Меню Finder",
                           "Пункт «Службы → Ссылка Яндекс Диска» добавлен. Если его не видно, откройте «Настройки» программы и нажмите «Включить» — там есть пошаговая подсказка.")
    }

    /// Включает службу и показывает понятную пошаговую подсказку, затем открывает настройки.
    static func enableWithGuide() {
        enable()
        let a = NSAlert()
        a.messageText = "Как включить пункт в меню Finder"
        a.informativeText = """
        Программа уже попыталась включить пункт сама. Если в Finder (правый клик по файлу → «Службы») его всё ещё нет, сделайте так:

        1. В открывшемся окне нажмите «Сочетания клавиш…» (кнопка справа внизу).
        2. Слева выберите «Службы».
        3. Прокрутите список вниз до раздела «Файлы и папки».
        4. Поставьте галочку у «Ссылка Яндекс Диска».

        После этого пункт появится в правом клике на любом файле.
        """
        a.addButton(withTitle: "Открыть настройки")
        a.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { openKeyboardSettings() }
    }

    static func openKeyboardSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard") {
            NSWorkspace.shared.open(u)
        }
    }
}

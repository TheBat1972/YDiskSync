import Cocoa

/// Значок в строке меню и его меню. Во время синхронизации значок вращается и показывает проценты.
final class StatusController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var status: SyncStatus = .notConfigured
    private var usage = ""
    private var animTimer: Timer?
    private var angle: CGFloat = 0
    private var spinBase: NSImage?

    var onOpenSettings: (() -> Void)?
    var onOpenActivity: (() -> Void)?
    var onOpenTrash: (() -> Void)?
    var onCreateLink: (() -> Void)?
    var onOpenLinks: (() -> Void)?
    var onSyncNow: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onConfirmDeletes: (() -> Void)?

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.imagePosition = .imageLeft
        update(.notConfigured)
    }

    // MARK: значок

    private func symbol(_ names: [String]) -> NSImage? {
        for n in names {
            if let img = NSImage(systemSymbolName: n, accessibilityDescription: "Яндекс Диск") {
                img.isTemplate = true
                return img
            }
        }
        return nil
    }

    private func rotated(_ img: NSImage, _ degrees: CGFloat) -> NSImage {
        let side: CGFloat = 18
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        let t = NSAffineTransform()
        t.translateX(by: side / 2, yBy: side / 2)
        t.rotate(byDegrees: degrees)
        t.translateX(by: -side / 2, yBy: -side / 2)
        t.concat()
        let s = img.size
        let k = min(side / s.width, side / s.height) * 0.9
        let w = s.width * k, h = s.height * k
        img.draw(in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        out.unlockFocus()
        out.isTemplate = true
        return out
    }

    private func startSpinning() {
        guard animTimer == nil else { return }
        spinBase = symbol(["arrow.triangle.2.circlepath"])
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let base = self.spinBase else { return }
            self.angle -= 30
            self.item.button?.image = self.rotated(base, self.angle)
        }
    }

    private func stopSpinning() {
        animTimer?.invalidate()
        animTimer = nil
        angle = 0
    }

    func update(_ s: SyncStatus) {
        status = s
        switch s {
        case .syncing(_, let fraction):
            startSpinning()
            if let f = fraction { item.button?.title = " \(Int(f * 100))%" } else { item.button?.title = "" }
        case .error, .needsConfirmation:
            stopSpinning()
            item.button?.title = ""
            item.button?.image = symbol(["externaldrive.badge.exclamationmark", "exclamationmark.triangle"])
        case .paused:
            stopSpinning()
            item.button?.title = ""
            item.button?.image = symbol(["pause.circle"])
        case .idle:
            stopSpinning()
            item.button?.title = ""
            item.button?.image = symbol(["externaldrive.badge.checkmark", "externaldrive"])
        case .notConfigured:
            stopSpinning()
            item.button?.title = ""
            item.button?.image = symbol(["externaldrive.badge.questionmark", "externaldrive"])
        }
        if item.button?.image == nil { item.button?.title = "Я" }
        rebuild()
    }

    func setUsage(_ info: YandexAPI.DiskInfo) {
        let f = ByteCountFormatter()
        f.countStyle = .file
        usage = "Занято \(f.string(fromByteCount: info.used)) из \(f.string(fromByteCount: info.total))"
    }

    // MARK: меню

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    private func line(_ text: String, tip: String? = nil) {
        let short = text.count > 70 ? String(text.prefix(70)) + "…" : text
        let it = NSMenuItem(title: short, action: nil, keyEquivalent: "")
        it.isEnabled = false
        it.toolTip = tip ?? text
        menu.addItem(it)
    }

    private func action(_ title: String, _ sel: Selector, _ key: String = "") {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        menu.addItem(it)
    }

    private func rebuild() {
        menu.removeAllItems()
        switch status {
        case .notConfigured: line("Нужна настройка: подключите аккаунт и выберите папки")
        case .paused: line("Синхронизация приостановлена")
        case .syncing(let t, _): line(t)
        case .idle(let date, let summary):
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            line("Синхронизировано в \(f.string(from: date))")
            if !summary.isEmpty { line(summary) }
        case .error(let m): line("Ошибка: " + m, tip: m)
        case .needsConfirmation(let m): line(m)
        }
        if !usage.isEmpty { line(usage) }
        menu.addItem(.separator())

        action("Журнал синхронизации…", #selector(openActivity), "l")
        if Settings.shared.isConfigured {
            action("Открыть папку на Маке", #selector(openFolder), "o")
        }
        action("Открыть Яндекс Диск в браузере", #selector(openWeb))
        if Settings.shared.token != nil {
            action("Корзина Диска…", #selector(openTrash), "t")
            action("Публичные ссылки…", #selector(openLinks))
        }
        if Settings.shared.isConfigured {
            action("Создать ссылку на файл…", #selector(createLink), "k")
        }
        menu.addItem(.separator())

        if case .needsConfirmation = status {
            action("Подтвердить удаление и синхронизировать", #selector(confirmDeletes))
        }
        if Settings.shared.isConfigured {
            action("Синхронизировать сейчас", #selector(syncNow), "r")
            action(Settings.shared.paused ? "Возобновить" : "Приостановить", #selector(togglePause))
            menu.addItem(.separator())
        }
        action("Настройки…", #selector(openSettings), ",")
        action("Выйти", #selector(quit), "q")
    }

    @objc private func openFolder() { NSWorkspace.shared.open(URL(fileURLWithPath: Settings.shared.localFolder)) }
    @objc private func openWeb() { NSWorkspace.shared.open(URL(string: "https://disk.yandex.ru")!) }
    @objc private func syncNow() { onSyncNow?() }
    @objc private func togglePause() { onTogglePause?() }
    @objc private func confirmDeletes() { onConfirmDeletes?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func createLink() { onCreateLink?() }
    @objc private func openLinks() { onOpenLinks?() }
    @objc private func openTrash() { onOpenTrash?() }
    @objc private func openActivity() { onOpenActivity?() }
    @objc private func quit() { NSApp.terminate(nil) }
}

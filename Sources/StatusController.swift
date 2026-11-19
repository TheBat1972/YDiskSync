import Cocoa

/// Значок в строке меню и его меню. Во время синхронизации значок вращается и показывает проценты.
final class StatusController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var status: SyncStatus = .notConfigured
    private var usage = ""
    private var animTimer: Timer?
    private var angle: CGFloat = 0

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

    /// Буква рядом со значком отличает этот клиент от второго.
    static let letter = "Я"
    private var spinBase: NSImage?

    private func symbol(_ names: [String]) -> NSImage? {
        for n in names {
            if let img = NSImage(systemSymbolName: n, accessibilityDescription: "Яндекс Диск") { return img }
        }
        return nil
    }

    /// Состояние синхронизации; от него зависит цвет буквы клиента.
    private enum Mark { case ok, fail, warn, work, pause, none }

    private var currentMark: Mark {
        switch status {
        case .idle: return .ok
        case .error: return .fail
        case .needsConfirmation: return .warn
        case .syncing: return .work
        case .paused: return .pause
        case .notConfigured: return .none
        }
    }

    /// Цвет состояния — им же окрашена буква клиента.
    private func markColor(_ m: Mark, gray: NSColor) -> NSColor {
        switch m {
        case .ok: return .systemGreen
        case .fail: return .systemRed
        case .warn: return .systemOrange
        case .work: return .systemBlue
        case .pause, .none: return gray
        }
    }

    /// Значок (можно повернуть) + буква справа, окрашенная по состоянию.
    /// Изображение не шаблонное: цвет значка и буквы подбирается под тёмную/светлую строку меню.
    private func compose(_ base: NSImage?, rotation: CGFloat = 0, alpha: CGFloat = 1) -> NSImage {
        let side: CGFloat = 18
        let markW: CGFloat = 0
        let mark = currentMark
        let font = NSFont.systemFont(ofSize: 11, weight: .heavy)
        let letter = StatusController.letter as NSString
        let ls = letter.size(withAttributes: [.font: font])
        let img = NSImage(size: NSSize(width: markW + side + 1 + ls.width, height: side), flipped: false) { [weak self] _ in
            let dark = self?.item.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let fg = (dark ? NSColor.white : NSColor.black).withAlphaComponent(alpha)
            let gray = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.45)


            if let base = base {
                let s = base.size
                let k = min(side / s.width, side / s.height) * 0.9
                let w = s.width * k, h = s.height * k
                let tinted = NSImage(size: NSSize(width: w, height: h), flipped: false) { r in
                    base.draw(in: r)
                    fg.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                NSGraphicsContext.saveGraphicsState()
                let t = NSAffineTransform()
                t.translateX(by: markW + side / 2, yBy: side / 2)
                t.rotate(byDegrees: rotation)
                t.translateX(by: -(markW + side / 2), yBy: -side / 2)
                t.concat()
                tinted.draw(in: NSRect(x: markW + (side - w) / 2, y: (side - h) / 2, width: w, height: h))
                NSGraphicsContext.restoreGraphicsState()
            }
            letter.draw(at: NSPoint(x: markW + side + 1, y: (side - ls.height) / 2),
                        withAttributes: [.font: font,
                                         .foregroundColor: (self?.markColor(mark, gray: gray) ?? fg).withAlphaComponent(alpha)])
            return true
        }
        img.isTemplate = false
        return img
    }

    private func startSpinning() {
        guard animTimer == nil else { return }
        spinBase = symbol(["arrow.triangle.2.circlepath"])
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.angle -= 30
            self.item.button?.image = self.compose(self.spinBase, rotation: self.angle)
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
            item.button?.image = compose(spinBase ?? symbol(["arrow.triangle.2.circlepath"]), rotation: angle)
            if let f = fraction { item.button?.title = " \(Int(f * 100))%" } else { item.button?.title = "" }
        case .error, .needsConfirmation:
            stopSpinning()
            item.button?.title = ""
            item.button?.image = compose(symbol(["externaldrive.badge.exclamationmark", "exclamationmark.triangle"]))
        case .paused:
            stopSpinning()
            item.button?.title = ""
            item.button?.image = compose(symbol(["pause.circle"]))
        case .idle:
            stopSpinning()
            item.button?.title = ""
            item.button?.image = compose(symbol(["externaldrive.badge.checkmark", "externaldrive"]))
        case .notConfigured:
            stopSpinning()
            item.button?.title = ""
            item.button?.image = compose(symbol(["externaldrive.badge.questionmark", "externaldrive"]), alpha: 0.5)
        }
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
        case .syncing(let t, _):
            line(t)
            let plan = ActivityLog.shared.plan
            if !plan.isEmpty { line(plan) }
            let speed = ActivityLog.shared.speed
            if !speed.isEmpty { line(speed) }
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

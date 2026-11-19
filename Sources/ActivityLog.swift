import Foundation

enum EventKind { case download, upload, delete, conflict, folder, info, error, done }

struct SyncEvent: Identifiable {
    let id = UUID()
    let date: Date
    let kind: EventKind
    let title: String
    let detail: String
}

/// Журнал событий и текущий прогресс — для окна «Журнал синхронизации».
final class ActivityLog: ObservableObject {
    static let shared = ActivityLog()

    @Published var events: [SyncEvent] = []          // новые сверху
    @Published var isSyncing = false
    @Published var progress: Double? = nil
    @Published var step = ""
    @Published var speed = ""                        // строка со скоростью передачи
    @Published var plan = ""                         // план текущего цикла (для меню)
    @Published var headline = "Ожидание"
    @Published var lastCheck: Date? = nil
    @Published var hasError = false

    /// Можно вызывать из любого потока.
    func add(_ kind: EventKind, _ title: String, _ detail: String = "") {
        DispatchQueue.main.async {
            self.events.insert(SyncEvent(date: Date(), kind: kind, title: title, detail: detail), at: 0)
            if self.events.count > 500 { self.events.removeLast(self.events.count - 500) }
        }
    }

    func clear() { events.removeAll() }

    /// Главный поток.
    func apply(_ s: SyncStatus) {
        hasError = false
        if case .syncing = s {} else { speed = ""; plan = "" }
        switch s {
        case .syncing(let text, let fraction):
            isSyncing = true; progress = fraction; step = text; headline = "Идёт синхронизация…"
        case .idle(let date, let summary):
            isSyncing = false; progress = nil; lastCheck = date
            headline = "Всё синхронизировано"; step = summary
        case .error(let m):
            isSyncing = false; progress = nil; headline = "Ошибка синхронизации"; step = m; hasError = true
        case .paused:
            isSyncing = false; progress = nil; headline = "Приостановлено"; step = ""
        case .notConfigured:
            isSyncing = false; progress = nil; headline = "Нужна настройка"; step = ""
        case .needsConfirmation(let m):
            isSyncing = false; progress = nil; headline = "Нужно подтверждение"; step = m; hasError = true
        }
    }
}

/// Скорость передачи файлов: по закачкам/выгрузкам, закончившимся за последние 20 секунд.
final class SpeedMeter {
    private var recent: [(end: Date, bytes: Int64, secs: Double)] = []
    private var total: Int64 = 0
    private var planned: Int64 = 0

    private var foldersStart: Date?
    private var foldersShown = Date.distantPast

    /// Этап создания папок: файлов ещё не передавали — показываем темп и сколько осталось.
    func folder(_ n: Int, of m: Int) {
        guard total == 0, m > 0 else { return }
        let now = Date()
        if foldersStart == nil { foldersStart = now }
        guard now.timeIntervalSince(foldersShown) > 1 || n >= m else { return }
        foldersShown = now
        let secs = now.timeIntervalSince(foldersStart ?? now)
        var text = "Папки: \(n) из \(m)"
        if n > 3 && secs > 2 {
            let rate = Double(n) / secs
            text += " · \(Int(rate * 60 + 0.5)) в минуту · осталось " + Self.eta(Double(m - n) / rate)
        }
        DispatchQueue.main.async { ActivityLog.shared.speed = text }
    }

    /// Сколько байт всего предстоит передать в этом цикле.
    func plan(_ bytes: Int64) { planned = bytes }

    init() { DispatchQueue.main.async { ActivityLog.shared.speed = "" } }

    func record(_ url: URL, since start: Date) {
        let bytes = ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize).map(Int64.init) ?? 0
        let now = Date()
        total += bytes
        recent.append((now, bytes, max(now.timeIntervalSince(start), 0.001)))
        recent.removeAll { now.timeIntervalSince($0.end) > 20 }
        let b = recent.reduce(Int64(0)) { $0 + $1.bytes }
        let s = recent.reduce(0.0) { $0 + $1.secs }
        let speed = Double(b) / s
        var text = "Скорость: \(Self.fmt(speed))/с · передано \(Self.fmt(Double(total)))"
        if planned > total {
            text += " из \(Self.fmt(Double(planned)))"
            if speed > 0 { text += " · осталось " + Self.eta(Double(planned - total) / speed) }
        }
        DispatchQueue.main.async { ActivityLog.shared.speed = text }
    }

    static func eta(_ sec: Double) -> String {
        if sec < 60 { return "меньше минуты" }
        let m = Int(sec / 60 + 0.5)
        return m < 60 ? "~\(m) мин" : "~\(m / 60) ч \(m % 60) мин"
    }

    static func fmt(_ v: Double) -> String {
        let units = ["Б", "КБ", "МБ", "ГБ", "ТБ"]
        var x = v, i = 0
        while x >= 1024 && i < units.count - 1 { x /= 1024; i += 1 }
        let num = i == 0 ? String(format: "%.0f", x) : String(format: x < 10 ? "%.1f" : "%.0f", x)
        return num.replacingOccurrences(of: ".", with: ",") + " " + units[i]
    }
}

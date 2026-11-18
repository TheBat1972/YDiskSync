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

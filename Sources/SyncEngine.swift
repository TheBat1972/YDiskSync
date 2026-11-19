import Foundation
import CryptoKit
import Network

enum SyncStatus {
    case notConfigured
    case paused
    case syncing(String, Double?)
    case idle(Date, String)
    case error(String)
    case needsConfirmation(String)
}

struct FileState: Codable {
    var isDir: Bool
    var md5: String?
    var size: Int64
    var mtime: Double
}

struct LocalItem {
    let isDir: Bool
    let size: Int64
    let mtime: Double
}

func fileMD5(_ url: URL) throws -> String {
    let fh = try FileHandle(forReadingFrom: url)
    defer { try? fh.close() }
    var hasher = Insecure.MD5()
    while true {
        let chunk: Data? = try autoreleasepool { try fh.read(upToCount: 4 << 20) }
        guard let data = chunk, !data.isEmpty else { break }
        hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Цикл прерван, потому что на Маке появились новые изменения (не ошибка).
private struct CycleInterrupted: Error {}

/// Двусторонняя синхронизация выбранных папок Диска с локальной папкой.
/// Локальная папка зеркалит корень Диска: «/Документы/a.txt» ↔ «<папка>/Документы/a.txt».
final class SyncEngine {
    var onStatus: ((SyncStatus) -> Void)?
    var onDiskInfo: ((YandexAPI.DiskInfo) -> Void)?

    private let settings = Settings.shared
    private let queue = DispatchQueue(label: "ydisk.sync", qos: .utility)
    private let lock = NSLock()
    private var running = false
    private var pending = false
    private var pendingAllowDelete = false
    private var lastLoggedError: String?
    private let monitor = NWPathMonitor()
    private var online = true

    // Копия списка Диска для циклов, вызванных правкой на Маке: читать весь Диск заново после каждого
    // скопированного файла слишком долго. Таймер и кнопка «Синхронизировать сейчас» всегда читают заново.
    private var remoteCache: [String: RemoteItem]?
    private var remoteCacheSel: [String] = []
    private var remoteCacheDate = Date.distantPast
    private var pendingFull = true

    init() { startMonitoring() }

    private var isOnline: Bool {
        lock.lock(); defer { lock.unlock() }
        return online
    }

    /// Следим за сетью: без неё не пытаемся синхронизироваться, а когда сеть вернулась — продолжаем сразу.
    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let nowOnline = (path.status == .satisfied)
            self.lock.lock()
            let was = self.online
            self.online = nowOnline
            self.lock.unlock()
            if nowOnline && !was {
                ActivityLog.shared.add(.info, "Сеть появилась", "Продолжаю синхронизацию")
                DispatchQueue.main.async { self.requestSync() }
            } else if !nowOnline && was {
                ActivityLog.shared.add(.info, "Нет подключения к интернету", "Синхронизация продолжится, когда сеть вернётся")
                self.onStatus?(.error("Нет подключения к интернету"))
            }
        }
        monitor.start(queue: DispatchQueue(label: "ydisk.net"))
    }
    private var timer: Timer?
    private var watcher: FolderWatcher?

    // MARK: - Запуск и расписание (главный поток)

    func reschedule() {
        timer?.invalidate(); timer = nil
        lock.lock(); remoteCache = nil; pendingFull = true; lock.unlock()
        watcher?.stop(); watcher = nil
        guard settings.isConfigured else { onStatus?(.notConfigured); return }
        if settings.paused { onStatus?(.paused); return }
        timer = Timer.scheduledTimer(withTimeInterval: Double(settings.intervalMinutes) * 60,
                                     repeats: true) { [weak self] _ in self?.requestSync() }
        let w = FolderWatcher { [weak self] in self?.requestSync(fullRead: false) }
        w.start(path: settings.localFolder)
        watcher = w
        requestSync()
    }

    func requestSync(allowMassDelete: Bool = false, fullRead: Bool = true) {
        guard settings.isConfigured, !settings.paused else { return }
        if !isOnline {
            // Флаг мог устареть (система не всегда сообщает, что сеть вернулась) — проверяем по-настоящему.
            probeOnline { [weak self] ok in
                guard let self = self else { return }
                if ok {
                    self.setOnline(true)
                    DispatchQueue.main.async { self.requestSync(allowMassDelete: allowMassDelete, fullRead: fullRead) }
                } else {
                    self.onStatus?(.error("Нет подключения к интернету — синхронизация продолжится, когда сеть вернётся"))
                    self.retryIfTransient(SyncError.network("нет связи"))
                }
            }
            return
        }
        lock.lock()
        if allowMassDelete { pendingAllowDelete = true }
        if fullRead { pendingFull = true }
        if running { pending = true; lock.unlock(); return }
        running = true
        lock.unlock()
        queue.async { [weak self] in self?.loop() }
    }

    private func loop() {
        while true {
            lock.lock()
            let allow = pendingAllowDelete
            let full = pendingFull
            pendingFull = false
            pendingAllowDelete = false
            pending = false
            lock.unlock()
            do {
                let summary = try runCycle(allowMassDelete: allow, fullRead: full)
                lastLoggedError = nil
                retryReset()
                onStatus?(.idle(Date(), summary))
            } catch is CycleInterrupted {
                // состояние сохранено, следующий проход составит новый план
            } catch SyncError.needsConfirmation(let m) {
                ActivityLog.shared.add(.error, "Нужно подтверждение удаления", m)
                onStatus?(.needsConfirmation(m))
            } catch SyncError.partial(let m) {
                onStatus?(.error(m))                 // подробности по файлам уже в журнале
            } catch {
                let m = error.localizedDescription
                if m != lastLoggedError { ActivityLog.shared.add(.error, "Синхронизация не удалась", m) }
                lastLoggedError = m
                onStatus?(.error(m))
                retryIfTransient(error)
            }
            lock.lock()
            if !pending { running = false; lock.unlock(); return }
            lock.unlock()
        }
    }

    private func setOnline(_ v: Bool) {
        lock.lock(); online = v; lock.unlock()
    }

    /// Достаточно любого ответа сервера (даже с ошибкой) — значит, связь есть.
    private func probeOnline(_ done: @escaping (Bool) -> Void) {
        guard let url = URL(string: "https://cloud-api.yandex.net") else { done(true); return }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 6
        URLSession.shared.dataTask(with: req) { _, resp, err in done(resp != nil || err == nil) }.resume()
    }

    // MARK: - Повтор после сбоя связи

    private var retryDelay: Double = 10
    private var retryItem: DispatchWorkItem?

    private func retryReset() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.retryItem?.cancel()
            self.retryItem = nil
            self.retryDelay = 10
        }
    }

    /// Короткий обрыв сети может не заметить даже монитор сети — после сбоя связи или ответа сервера 5xx/429
    /// повторяем сами: через 10 секунд, затем реже (до 2 минут), пока не получится.
    private func retryIfTransient(_ error: Error) {
        var transient = false
        switch error {
        case SyncError.network: transient = true
        case SyncError.http(let c, _): transient = (c == 429 || c >= 500)
        default: break
        }
        guard transient else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.retryItem?.cancel()
            let delay = self.retryDelay
            self.retryDelay = min(self.retryDelay * 2, 120)
            let item = DispatchWorkItem { [weak self] in self?.requestSync() }
            self.retryItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    // MARK: - Состояние на диске

    private func stateFileURL() -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YDiskSync", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let h = Insecure.MD5.hash(data: Data(settings.localFolder.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("state-\(h).json")
    }

    private func loadState(_ url: URL) -> [String: FileState] {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode([String: FileState].self, from: data) else { return [:] }
        return s
    }

    private func saveState(_ s: [String: FileState], _ url: URL) {
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: - Локальная папка

    private func scanLocal(_ root: URL) throws -> [String: LocalItem] {
        var out: [String: LocalItem] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let resolved = root.resolvingSymlinksInPath()
        let base = resolved.path
        guard let en = FileManager.default.enumerator(
            at: resolved, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else {
            throw SyncError.bad("Не удалось прочитать папку синхронизации")
        }
        for case let url as URL in en {
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true { continue }
            let path = url.path
            guard path.hasPrefix(base + "/") else { continue }
            let name = url.lastPathComponent
            if name.hasPrefix("~$") || name.hasSuffix(".part") { continue }
            let rel = String(path.dropFirst(base.count + 1)).precomposedStringWithCanonicalMapping
            out[rel] = LocalItem(isDir: v?.isDirectory == true,
                                 size: Int64(v?.fileSize ?? 0),
                                 mtime: v?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        return out
    }

    private func statLocal(_ url: URL) throws -> (size: Int64, mtime: Double) {
        let v = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (Int64(v.fileSize ?? 0), v.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }

    // MARK: - Один цикл

    private func runCycle(allowMassDelete: Bool, fullRead: Bool) throws -> String {
        guard let token = settings.token, settings.isConfigured else { throw SyncError.notConfigured }
        let fm = FileManager.default
        let localRoot = URL(fileURLWithPath: settings.localFolder, isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: localRoot.path, isDirectory: &isDir), isDir.boolValue else {
            throw SyncError.bad("Папка синхронизации не найдена: \(localRoot.path)")
        }
        let api = YandexAPI(token: token)
        onStatus?(.syncing("Получение списка файлов…", nil))
        if let info = try? api.diskInfo() { onDiskInfo?(info) }

        // Выбранные папки Диска
        let selections = settings.selectedFolders
        let selRels = selections.map { $0 == "/" ? "" : String($0.dropFirst()) }
        func inSelection(_ key: String) -> Bool {
            selRels.contains { $0.isEmpty || key == $0 || key.hasPrefix($0 + "/") }
        }

        func localURL(_ rel: String) -> URL { localRoot.appendingPathComponent(rel) }
        func remotePath(_ rel: String) -> String { "/" + rel }
        var errors: [String] = []
        func logError(_ rel: String, _ error: Error) {
            errors.append("\(rel): \(error.localizedDescription)")
            ActivityLog.shared.add(.error, "Ошибка: " + (rel as NSString).lastPathComponent,
                                   rel + " — " + error.localizedDescription)
        }

        let stateURL = stateFileURL()
        let state = loadState(stateURL)
        var newState = state

        // Папки, убранные из синхронизации: копию на Маке убираем в Корзину, на Диске ничего не трогаем.
        func isAncestorOfSelection(_ key: String) -> Bool { selRels.contains { $0.hasPrefix(key + "/") } }
        let orphans = state.keys.filter { !inSelection($0) }.sorted { $0.count < $1.count }
        var trashedRoots: [String] = []
        var nOrphan = 0
        for key in orphans {
            if isAncestorOfSelection(key) || trashedRoots.contains(where: { key.hasPrefix($0 + "/") }) {
                newState[key] = nil
                continue
            }
            let url = localURL(key)
            if fm.fileExists(atPath: url.path) {
                do {
                    try fm.trashItem(at: url, resultingItemURL: nil)
                    nOrphan += 1
                    if state[key]?.isDir == true { trashedRoots.append(key) }
                    ActivityLog.shared.add(.delete, "Убрано из синхронизации: " + (key as NSString).lastPathComponent,
                                           key + " — удалено с Мака (в Корзину), на Диске осталось")
                } catch { logError(key, error); continue }
            }
            newState[key] = nil
        }

        // Диск
        var remote: [String: RemoteItem] = [:]
        lock.lock()
        let cached = remoteCache
        let cachedDate = remoteCacheDate
        let usedCache = !fullRead && cached != nil && remoteCacheSel == selections
            && Date().timeIntervalSince(cachedDate) < 900
        remoteCache = nil                  // вернём только после успешного цикла
        lock.unlock()
        if usedCache, let c = cached { remote = c }
        let readStart = Date()
        var lastTick = Date.distantPast
        for sel in selections where !usedCache {
            let selRel = sel == "/" ? "" : String(sel.dropFirst())
            let dirItem = RemoteItem(isDir: true, size: 0, md5: nil, modified: Date(), apiPath: sel)
            let tree = try api.listTree(root: sel) { folders, objects in
                let now = Date()
                if now.timeIntervalSince(lastTick) > 0.3 {
                    lastTick = now
                    self.onStatus?(.syncing("Чтение Диска: папок \(folders), объектов \(objects)…", nil))
                }
            }
            if let tree = tree {
                if !selRel.isEmpty { remote[selRel] = dirItem }
                for (rel, item) in tree { remote[selRel.isEmpty ? rel : selRel + "/" + rel] = item }
            } else if selRel.isEmpty {
                throw SyncError.bad("Не удалось прочитать корень Диска")
            } else if state[selRel] == nil {
                try api.ensureDir(sel)          // выбрали папку, которой ещё нет, — создаём
                remote[selRel] = dirItem
            }
            // иначе папку удалили на Диске: локальные копии уйдут по правилам удаления
        }

        if !usedCache {
            ActivityLog.shared.add(.info, "Список Диска получен: \(remote.count) объектов",
                                   String(format: "за %.0f с", Date().timeIntervalSince(readStart)))
        }
        onStatus?(.syncing("Просмотр папки на Маке…", nil))

        // Локальная папка (только то, что внутри выбранного)
        let local = try scanLocal(localRoot).filter { inSelection($0.key) }

        func localMD5(_ rel: String, _ l: LocalItem, _ s: FileState?) throws -> String {
            if let s = s, let m = s.md5, s.size == l.size, s.mtime == l.mtime { return m }
            return try fileMD5(localURL(rel))
        }

        // MARK: план
        var mkLocal: [String] = [], mkRemote: [String] = []
        var down: [String] = [], up: [String] = [], conflicts: [String] = []
        var delLocal: [String] = [], delRemote: [String] = []
        var rerunSoon = false

        let all = Set(local.keys).union(remote.keys).union(state.keys.filter(inSelection))
        for rel in all.sorted() {
            let l = local[rel], r = remote[rel], s = state[rel]
            do {
                if let l = l, let r = r {
                    if l.isDir != r.isDir {
                        errors.append("\(rel): файл и папка с одним именем")
                        ActivityLog.shared.add(.error, "Файл и папка с одним именем", rel)
                        continue
                    }
                    if l.isDir {
                        newState[rel] = FileState(isDir: true, md5: nil, size: 0, mtime: 0)
                        continue
                    }
                    let lm = try localMD5(rel, l, s)
                    if lm == r.md5 {
                        newState[rel] = FileState(isDir: false, md5: lm, size: l.size, mtime: l.mtime)
                        continue
                    }
                    guard let s = s else { conflicts.append(rel); continue }
                    let lc = lm != s.md5
                    let rc = r.md5 != s.md5
                    if lc && rc { conflicts.append(rel) }
                    else if lc { up.append(rel) }
                    else if rc { down.append(rel) }
                } else if let l = l {                       // есть только локально
                    if let s = s {
                        var changed = false
                        if !l.isDir { changed = try localMD5(rel, l, s) != s.md5 }
                        if changed { up.append(rel) } else { delLocal.append(rel) }   // удалено на Диске
                    } else if l.isDir { mkRemote.append(rel) } else { up.append(rel) }
                } else if let r = r {                       // есть только на Диске
                    if let s = s {
                        if !r.isDir && r.md5 != s.md5 { down.append(rel) } else { delRemote.append(rel) }  // удалено локально
                    } else if r.isDir { mkLocal.append(rel) } else { down.append(rel) }
                } else {
                    newState[rel] = nil
                }
            } catch { logError(rel, error) }
        }

        // Файлы, которые ещё пишутся, трогаем в следующий раз
        let now = Date().timeIntervalSince1970
        up = up.filter { rel in
            if let l = local[rel], now - l.mtime < 2 { rerunSoon = true; return false }
            return true
        }

        // Защита от массового удаления
        let dels = delLocal.count + delRemote.count
        let stateCount = state.keys.filter(inSelection).count
        if !allowMassDelete && UserDefaults.standard.bool(forKey: "confirmMassDelete") && dels >= 10 && (dels * 2 > stateCount || dels >= 100) {
            throw SyncError.needsConfirmation(
                "Нужно удалить \(dels) объектов (здесь: \(delLocal.count), на Диске: \(delRemote.count)). Подтвердите в меню.")
        }

        // Копия списка могла устареть: файл, который хотим перезаписать, мог измениться на Диске — тогда читаем заново.
        if usedCache {
            for rel in up {
                guard let cur = remote[rel], !cur.isDir else { continue }
                let now = try? api.remoteMD5(remotePath(rel))
                if now == nil || now! != cur.md5 {
                    lock.lock(); pendingFull = true; pending = true; lock.unlock()
                    return ""
                }
            }
        }

        // MARK: выполнение
        let total = mkLocal.count + mkRemote.count + down.count + up.count + conflicts.count + dels
        var done = 0
        var nDown = 0, nUp = 0, nDel = 0, nConf = 0
        var lastPoll = Date()
        func step(_ text: String) throws {
            done += 1
            onStatus?(.syncing("\(text) (\(done) из \(total))", total > 0 ? Double(done - 1) / Double(total) : nil))
            // Пользователь изменил файлы, пока мы работали, — план устарел: сохраняем сделанное и планируем заново.
            if Date().timeIntervalSince(lastPoll) > 2 {
                lastPoll = Date()
                lock.lock(); let again = pending; lock.unlock()
                if again && done < total {
                    saveState(newState, stateURL)
                    throw CycleInterrupted()
                }
            }
        }
        func fail(_ rel: String, _ error: Error) throws {
            var fatal = false
            if case SyncError.unauthorized = error { fatal = true }
            if case SyncError.network = error { fatal = true }   // нет сети — дальше нет смысла
            if fatal {
                saveState(newState, stateURL)                    // что успели — запомнили
                throw error
            }
            logError(rel, error)
        }
        func name(_ rel: String) -> String { (rel as NSString).lastPathComponent }

        func doDownload(_ rel: String, _ r: RemoteItem) throws {
            let dest = localURL(rel)
            let parent = dest.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let tmp = parent.appendingPathComponent(".ydisk-\(UUID().uuidString).part")
            defer { try? fm.removeItem(at: tmp) }
            try api.download(r.apiPath, to: tmp)
            try fm.setAttributes([.modificationDate: r.modified], ofItemAtPath: tmp.path)
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dest)
            }
            let st = try statLocal(dest)
            newState[rel] = FileState(isDir: false, md5: r.md5, size: st.size, mtime: st.mtime)
            nDown += 1
            ActivityLog.shared.add(.download, "Скачано с Диска: " + name(rel), rel)
        }

        func doUpload(_ rel: String) throws {
            let url = localURL(rel)
            let md5 = try fileMD5(url)
            let st = try statLocal(url)
            try api.upload(url, to: remotePath(rel))
            remote[rel] = RemoteItem(isDir: false, size: st.size, md5: md5, modified: Date(), apiPath: remotePath(rel))
            newState[rel] = FileState(isDir: false, md5: md5, size: st.size, mtime: st.mtime)
            nUp += 1
            ActivityLog.shared.add(.upload, "Загружено на Диск: " + name(rel), rel)
        }

        for rel in mkLocal.sorted() {
            try step("Папка " + (rel as NSString).lastPathComponent)
            do {
                try fm.createDirectory(at: localURL(rel), withIntermediateDirectories: true)
                newState[rel] = FileState(isDir: true, md5: nil, size: 0, mtime: 0)
                ActivityLog.shared.add(.folder, "Создана папка на Маке: " + name(rel), rel)
            } catch { try fail(rel, error) }
        }
        for rel in mkRemote.sorted() {
            try step("Папка " + (rel as NSString).lastPathComponent)
            do {
                try api.makeDir(remotePath(rel))
                remote[rel] = RemoteItem(isDir: true, size: 0, md5: nil, modified: Date(), apiPath: remotePath(rel))
                newState[rel] = FileState(isDir: true, md5: nil, size: 0, mtime: 0)
                ActivityLog.shared.add(.folder, "Создана папка на Диске: " + name(rel), rel)
            } catch { try fail(rel, error) }
        }
        for rel in down.sorted() {
            guard let r = remote[rel] else { continue }
            try step("↓ " + (rel as NSString).lastPathComponent)
            do { try doDownload(rel, r) } catch { try fail(rel, error) }
        }
        for rel in up.sorted() {
            try step("↑ " + (rel as NSString).lastPathComponent)
            do { try doUpload(rel) } catch { try fail(rel, error) }
        }
        for rel in conflicts.sorted() {
            guard let r = remote[rel] else { continue }
            try step("Конфликт: " + (rel as NSString).lastPathComponent)
            do {
                // Локальную версию сохраняем рядом как копию, с Диска берём свежую
                let url = localURL(rel)
                let ext = url.pathExtension
                let base = url.deletingPathExtension().lastPathComponent
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd HH-mm"
                let copyName = "\(base) (конфликт \(f.string(from: Date())))" + (ext.isEmpty ? "" : "." + ext)
                let parentRel = (rel as NSString).deletingLastPathComponent
                let copyRel = parentRel.isEmpty ? copyName : parentRel + "/" + copyName
                try fm.moveItem(at: url, to: localURL(copyRel))
                try doDownload(rel, r)
                try doUpload(copyRel)
                nConf += 1
                ActivityLog.shared.add(.conflict, "Конфликт: " + name(rel),
                                       "Файл изменён и здесь, и на Диске. Ваша версия сохранена как «" + copyName + "»")
            } catch { try fail(rel, error) }
        }

        // Удаления: сначала файлы, потом папки (от самых вложенных)
        let delRemoteSet = Set(delRemote)
        for rel in delLocal.sorted() where local[rel]?.isDir == false {
            try step("Удаление " + (rel as NSString).lastPathComponent)
            do {
                try fm.trashItem(at: localURL(rel), resultingItemURL: nil)
                newState[rel] = nil
                nDel += 1
                ActivityLog.shared.add(.delete, "Удалено на Маке (удалено на Диске): " + name(rel), rel)
            } catch { try fail(rel, error) }
        }
        for rel in delRemote.sorted() where remote[rel]?.isDir == false {
            try step("Удаление на Диске " + (rel as NSString).lastPathComponent)
            do {
                try api.delete(remote[rel]?.apiPath ?? remotePath(rel))
                remote[rel] = nil
                newState[rel] = nil
                nDel += 1
                ActivityLog.shared.add(.delete, "Удалено с Диска (вы удалили на Маке): " + name(rel), rel)
            } catch { try fail(rel, error) }
        }
        for rel in delLocal.sorted(by: { $0.count > $1.count }) where local[rel]?.isDir == true {
            try step("Удаление папки " + (rel as NSString).lastPathComponent)
            do {
                let names = (try? fm.contentsOfDirectory(atPath: localURL(rel).path)) ?? []
                if names.contains(where: { !$0.hasPrefix(".") }) {
                    newState[rel] = nil          // в папке появились новые файлы — оставляем и выгрузим
                } else {
                    try fm.trashItem(at: localURL(rel), resultingItemURL: nil)
                    newState[rel] = nil
                    nDel += 1
                    ActivityLog.shared.add(.delete, "Удалена папка на Маке (удалена на Диске): " + name(rel), rel)
                }
            } catch { try fail(rel, error) }
        }
        for rel in delRemote.sorted(by: { $0.count > $1.count }) where remote[rel]?.isDir == true {
            try step("Удаление папки на Диске " + (rel as NSString).lastPathComponent)
            do {
                let survivors = remote.keys.contains { $0.hasPrefix(rel + "/") && !delRemoteSet.contains($0) }
                if survivors {
                    newState[rel] = nil          // на Диске в папке есть новое — оставляем, скачаем
                } else {
                    try api.delete(remote[rel]?.apiPath ?? remotePath(rel))
                    remote[rel] = nil
                    newState[rel] = nil
                    nDel += 1
                    ActivityLog.shared.add(.delete, "Удалена папка с Диска (вы удалили на Маке): " + name(rel), rel)
                }
            } catch { try fail(rel, error) }
        }

        saveState(newState, stateURL)
        if errors.isEmpty {
            lock.lock()
            remoteCache = remote
            remoteCacheSel = selections
            remoteCacheDate = usedCache ? cachedDate : readStart
            lock.unlock()
        }
        if rerunSoon {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.requestSync(fullRead: false) }
        }
        var parts: [String] = []
        if nDown > 0 { parts.append("скачано: \(nDown)") }
        if nUp > 0 { parts.append("загружено: \(nUp)") }
        if nDel + nOrphan > 0 { parts.append("удалено: \(nDel + nOrphan)") }
        if nConf > 0 { parts.append("конфликтов: \(nConf)") }
        let summary = parts.joined(separator: ", ")
        if !errors.isEmpty {
            ActivityLog.shared.add(.error, "Синхронизация завершена с ошибками", "Ошибок: \(errors.count)")
            throw SyncError.partial("Ошибок: \(errors.count). \(errors[0])")
        }
        if !summary.isEmpty { ActivityLog.shared.add(.done, "Готово", summary) }
        return summary
    }
}

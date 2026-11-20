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
                DispatchQueue.main.async { self.requestSync(fullRead: false) }   // прочитанный список ещё годен
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
                                     repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock(); let busy = self.running; self.lock.unlock()
            if !busy { self.requestSync() }   // идёт синхронизация — не заказываем ещё одно чтение следом
        }
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
            let item = DispatchWorkItem { [weak self] in self?.requestSync(fullRead: false) }
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
        DispatchQueue.main.async { ActivityLog.shared.speed = ""; ActivityLog.shared.plan = "" }
        if let info = try? api.diskInfo() { onDiskInfo?(info) }

        // Выбранные папки Диска
        let selections = settings.selectedFolders
        let selRels = selections.map { $0 == "/" ? "" : String($0.dropFirst()) }
        // Исключения: ближайшее (самое глубокое) правило побеждает — внутри выбранной папки можно исключить вложенную.
        let exRels = settings.excludedFolders.map { String($0.dropFirst()) }
        let cacheSel = selections + settings.excludedFolders.map { "-" + $0 }
        // Читаем только корневые выбранные папки: вложенные уже входят в прочитанное дерево.
        let readRoots = selections.filter { s in !selections.contains { $0 != s && ($0 == "/" || s.hasPrefix($0 + "/")) } }
        func inSelection(_ key: String) -> Bool {
            var best = -1
            var included = false
            for r in selRels where r.isEmpty || key == r || key.hasPrefix(r + "/") {
                if r.count > best { best = r.count; included = true }
            }
            for e in exRels where key == e || key.hasPrefix(e + "/") {
                if e.count >= best { best = e.count; included = false }
            }
            return included
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
        var trashedTops: [String] = []
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
                    trashedTops.append(key)
                    if state[key]?.isDir == true { trashedRoots.append(key) }
                    ActivityLog.shared.add(.delete, "Убрано из синхронизации: " + (key as NSString).lastPathComponent,
                                           key + " — удалено с Мака (в Корзину), на Диске осталось")
                } catch { logError(key, error); continue }
            }
            newState[key] = nil
        }

        // Убранное с Мака записываем в состояние сразу: иначе при сбое позже это сочтут удалением пользователем и повторят на сервере.
        saveState(newState, stateURL)

        // Пустые папки-контейнеры (например, «X», когда были выбраны только «X/Y» и «X/Z»), остающиеся после снятия выбора.
        var checkedParents = Set<String>()
        for key in trashedTops {
            var parent = (key as NSString).deletingLastPathComponent
            while !parent.isEmpty && parent != "/" && !checkedParents.contains(parent) {
                checkedParents.insert(parent)
                if inSelection(parent) || isAncestorOfSelection(parent) { break }
                let purl = localURL(parent)
                guard let rest = try? fm.contentsOfDirectory(atPath: purl.path),
                      rest.allSatisfy({ $0 == ".DS_Store" }) else { break }
                if (try? fm.trashItem(at: purl, resultingItemURL: nil)) == nil { break }
                newState[parent] = nil
                parent = (parent as NSString).deletingLastPathComponent
            }
        }

        // Диск
        var remote: [String: RemoteItem] = [:]
        lock.lock()
        let cached = remoteCache
        let cachedDate = remoteCacheDate
        let usedCache = !fullRead && cached != nil && remoteCacheSel == cacheSel
            && Date().timeIntervalSince(cachedDate) < 900
        remoteCache = nil                  // вернём только после успешного цикла
        lock.unlock()
        if usedCache, let c = cached { remote = c }
        let readStart = Date()
        var lastTick = Date.distantPast
        var readFast = false
        for sel in readRoots where !usedCache {
            let selRel = sel == "/" ? "" : String(sel.dropFirst())
            let dirItem = RemoteItem(isDir: true, size: 0, md5: nil, modified: Date(), apiPath: sel)
            let progressCb: (Int, Int) -> Void = { folders, objects in
                let now = Date()
                if now.timeIntervalSince(lastTick) > 0.3 {
                    lastTick = now
                    self.onStatus?(.syncing("Чтение Диска: папок \(folders), объектов \(objects)…", nil))
                }
            }
            // Обычно читаем быстрым плоским списком; раз в сутки (и если он не сработал) — обходом всех папок.
            let deepKey = "lastDeepRead"
            let lastDeep = UserDefaults.standard.double(forKey: deepKey)
            if lastDeep == 0 { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: deepKey) }  // первый запуск: сразу быстрым способом
            let needDeep = lastDeep > 0 && Date().timeIntervalSince1970 - lastDeep > 86400
            var tree: [String: RemoteItem]?
            var read = false
            if !needDeep {
                let known = Set(state.filter { $0.value.isDir && inSelection($0.key) && $0.key != selRel }
                    .map { selRel.isEmpty ? $0.key : String($0.key.dropFirst(selRel.count + 1)) })
                do {
                    self.onStatus?(.syncing("Чтение Диска: запрос списка файлов…", nil))
                    tree = try api.listTreeFast(root: sel, knownDirs: known, progress: progressCb)
                    self.onStatus?(.syncing("Чтение Диска: обработка списка…", nil))
                    read = true
                readFast = true
                } catch SyncError.network(let m) { throw SyncError.network(m) }
                  catch SyncError.unauthorized { throw SyncError.unauthorized }
                  catch {
                    ActivityLog.shared.add(.info, "Быстрое чтение не сработало, читаю по папкам", error.localizedDescription)
                }
            }
            if !read {
                tree = try api.listTree(root: sel, progress: progressCb)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: deepKey)
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
            lock.lock(); pendingFull = false; lock.unlock()   // Диск только что прочитан — повторное полное чтение не нужно
            ActivityLog.shared.add(.info, "Список Диска получен: \(remote.count) объектов",
                                   String(format: "за %.0f с", Date().timeIntervalSince(readStart)) + (readFast ? " (быстрое чтение)" : " (по папкам)"))
        }
        onStatus?(.syncing("Просмотр папки на Маке…", nil))

        // Локальная папка (только то, что внутри выбранного)
        if !exRels.isEmpty { remote = remote.filter { inSelection($0.key) } }
        // Защита: сервер вернул пустой список, хотя мы знаем много файлов, — это сбой чтения, а не «всё удалено».
        do {
            let rootDirs = selRels.filter { !$0.isEmpty }.count
            let knownCount = state.keys.filter(inSelection).count
            if remote.count <= rootDirs && knownCount > 20 {
                throw SyncError.bad("Сервер вернул пустой список (известно \(knownCount) объектов). Синхронизация остановлена, чтобы ничего не потерять.")
            }
        }
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
                        if !r.isDir && r.md5 != s.md5 { down.append(rel) } else if r.isDir && selRels.contains(rel) { mkLocal.append(rel) } else { delRemote.append(rel) }  // удалено локально
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

        // Папку переименовали или перенесли: на Диске переносим её одним запросом, а не заливаем всё заново.
        // Узнаём по содержимому: тот же набор вложенных файлов и папок с теми же размерами.
        // Выбранная папка, которую переименовали на Маке: она в mkLocal (защита корня), но по сути «удалена» на Маке.
        let goneDirs: [String] = mkLocal.filter { !$0.isEmpty && local[$0] == nil && state[$0] != nil && remote[$0]?.isDir == true }
        if !mkRemote.isEmpty && !(delRemote.isEmpty && goneDirs.isEmpty) {
            let delSet = Set(delRemote).union(goneDirs), mkSet = Set(mkRemote)
            func isTop(_ rel: String, _ set: Set<String>) -> Bool {
                let p = (rel as NSString).deletingLastPathComponent
                return p.isEmpty || !set.contains(p)
            }
            let oldTops = (delRemote + goneDirs).filter { remote[$0]?.isDir == true && isTop($0, delSet) }
            let newTops = mkRemote.filter { isTop($0, mkSet) }
            if !oldTops.isEmpty && !newTops.isEmpty {
                func sigOld(_ top: String) -> String? {
                    let prefix = top + "/"
                    var parts: [String] = []
                    for (k, r) in remote where k.hasPrefix(prefix) {
                        if !delSet.contains(k) || local[k] != nil { return nil }   // внутри что-то остаётся — это не переименование
                        parts.append(String(k.dropFirst(prefix.count)) + (r.isDir ? "/" : "|\(r.size)"))
                    }
                    return parts.isEmpty ? nil : parts.sorted().joined(separator: "\n")
                }
                func sigNew(_ top: String) -> String? {
                    let prefix = top + "/"
                    var parts: [String] = []
                    for (k, l) in local where k.hasPrefix(prefix) {
                        if remote[k] != nil { return nil }
                        parts.append(String(k.dropFirst(prefix.count)) + (l.isDir ? "/" : "|\(l.size)"))
                    }
                    return parts.isEmpty ? nil : parts.sorted().joined(separator: "\n")
                }
                var newBySig: [String: [String]] = [:]
                for t in newTops { if let sg = sigNew(t) { newBySig[sg, default: []].append(t) } }
                var oldBySig: [String: [String]] = [:]
                for t in oldTops { if let sg = sigOld(t) { oldBySig[sg, default: []].append(t) } }
                for (sg, olds) in oldBySig {
                    guard olds.count == 1, let news = newBySig[sg], news.count == 1 else { continue }   // неоднозначно — не трогаем
                    let oldTop = olds[0], newTop = news[0]
                    do {
                        try api.move(remotePath(oldTop), to: remotePath(newTop))
                    } catch {
                        ActivityLog.shared.add(.info, "Не удалось переименовать на Диске, заливаю заново", oldTop + " → " + newTop)
                        continue
                    }
                    let oldPrefix = oldTop + "/"
                    for k in remote.keys.filter({ $0 == oldTop || $0.hasPrefix(oldPrefix) }) {
                        guard let item = remote[k] else { continue }
                        let nk = newTop + String(k.dropFirst(oldTop.count))
                        remote[nk] = RemoteItem(isDir: item.isDir, size: item.size, md5: item.md5,
                                                modified: item.modified, apiPath: remotePath(nk))
                        remote[k] = nil
                        if let st = state[k] { newState[nk] = st }
                        newState[k] = nil
                    }
                    let newPrefix = newTop + "/"
                    mkRemote = mkRemote.filter { $0 != newTop && !$0.hasPrefix(newPrefix) }
                    up = up.filter { !$0.hasPrefix(newPrefix) }
                    delRemote = delRemote.filter { $0 != oldTop && !$0.hasPrefix(oldPrefix) }
                    mkLocal = mkLocal.filter { $0 != oldTop && !$0.hasPrefix(oldPrefix) }
                    // выбор следует за переименованием: иначе старое имя снова создастся пустым
                    func remap(_ list: [String]) -> [String] {
                        list.map { (s: String) -> String in
                            let r = String(s.dropFirst())
                            if r == oldTop || r.hasPrefix(oldPrefix) { return "/" + newTop + String(r.dropFirst(oldTop.count)) }
                            return s
                        }
                    }
                    settings.selectedFolders = remap(settings.selectedFolders)
                    settings.excludedFolders = remap(settings.excludedFolders)
                    ActivityLog.shared.add(.folder, "Папка переименована на Диске: " + (newTop as NSString).lastPathComponent,
                                           oldTop + " → " + newTop)
                }
            }
        }

        // Папку переименовали или перенесли на сервере: переносим её и на Маке, а не качаем заново.
        if !mkLocal.isEmpty && !delLocal.isEmpty {
            let delSet = Set(delLocal), mkSet = Set(mkLocal), downSet = Set(down)
            func isTop(_ rel: String, _ set: Set<String>) -> Bool {
                let p = (rel as NSString).deletingLastPathComponent
                return p.isEmpty || !set.contains(p)
            }
            let oldTops = delLocal.filter { local[$0]?.isDir == true && isTop($0, delSet) }
            let newTops = mkLocal.filter { isTop($0, mkSet) }
            if !oldTops.isEmpty && !newTops.isEmpty {
                func sigOld(_ top: String) -> String? {
                    let prefix = top + "/"
                    var parts: [String] = []
                    for (k, l) in local where k.hasPrefix(prefix) {
                        if !delSet.contains(k) || remote[k] != nil { return nil }   // внутри что-то остаётся или изменилось
                        parts.append(String(k.dropFirst(prefix.count)) + (l.isDir ? "/" : "|\(l.size)"))
                    }
                    return parts.isEmpty ? nil : parts.sorted().joined(separator: "\n")
                }
                func sigNew(_ top: String) -> String? {
                    let prefix = top + "/"
                    var parts: [String] = []
                    for (k, r) in remote where k.hasPrefix(prefix) {
                        if local[k] != nil || !(mkSet.contains(k) || downSet.contains(k)) { return nil }
                        parts.append(String(k.dropFirst(prefix.count)) + (r.isDir ? "/" : "|\(r.size)"))
                    }
                    return parts.isEmpty ? nil : parts.sorted().joined(separator: "\n")
                }
                var newBySig: [String: [String]] = [:]
                for t in newTops { if let sg = sigNew(t) { newBySig[sg, default: []].append(t) } }
                var oldBySig: [String: [String]] = [:]
                for t in oldTops { if let sg = sigOld(t) { oldBySig[sg, default: []].append(t) } }
                for (sg, olds) in oldBySig {
                    guard olds.count == 1, let news = newBySig[sg], news.count == 1 else { continue }   // неоднозначно — не трогаем
                    let oldTop = olds[0], newTop = news[0]
                    do {
                        try fm.createDirectory(at: localURL((newTop as NSString).deletingLastPathComponent),
                                               withIntermediateDirectories: true)
                        try fm.moveItem(at: localURL(oldTop), to: localURL(newTop))
                    } catch {
                        ActivityLog.shared.add(.info, "Не удалось переименовать на Маке, скачиваю заново", oldTop + " → " + newTop)
                        continue
                    }
                    let oldPrefix = oldTop + "/"
                    for k in state.keys.filter({ $0 == oldTop || $0.hasPrefix(oldPrefix) }) {
                        let nk = newTop + String(k.dropFirst(oldTop.count))
                        if let st = state[k] { newState[nk] = st }
                        newState[k] = nil
                    }
                    let newPrefix = newTop + "/"
                    mkLocal = mkLocal.filter { $0 != newTop && !$0.hasPrefix(newPrefix) }
                    down = down.filter { !$0.hasPrefix(newPrefix) }
                    delLocal = delLocal.filter { $0 != oldTop && !$0.hasPrefix(oldPrefix) }
                    ActivityLog.shared.add(.folder, "Папка переименована на Маке: " + (newTop as NSString).lastPathComponent,
                                           oldTop + " → " + newTop)
                }
            }
        }

        // Выбранную папку переименовали на Маке, и нового имени нет в выборе: ищем её только среди соседей по папке
        // (одна папка, быстро) по тому же содержимому и переносим в облаке, а выбор переименовываем.
        for g in goneDirs where selRels.contains(g) && mkLocal.contains(g) {
            let gp = g + "/"
            var rparts: [String] = []
            for (k, r) in remote where k.hasPrefix(gp) { rparts.append(String(k.dropFirst(gp.count)) + (r.isDir ? "/" : "|\(r.size)")) }
            if rparts.isEmpty { continue }
            let rsig = rparts.sorted().joined(separator: "\n")
            let par = (g as NSString).deletingLastPathComponent
            let parURL = par.isEmpty ? localRoot : localURL(par)
            guard let names = try? fm.contentsOfDirectory(atPath: parURL.path) else { continue }
            var found: [String] = []
            for n in names where !n.hasPrefix(".") {
                let cand = par.isEmpty ? n.precomposedStringWithCanonicalMapping : par + "/" + n.precomposedStringWithCanonicalMapping
                var isD: ObjCBool = false
                guard fm.fileExists(atPath: localURL(cand).path, isDirectory: &isD), isD.boolValue else { continue }
                if cand == g || remote[cand] != nil || state[cand] != nil || inSelection(cand) { continue }
                guard let sub = try? scanLocal(localURL(cand)), !sub.isEmpty else { continue }
                let csig = sub.map { $0.key + ($0.value.isDir ? "/" : "|\($0.value.size)") }.sorted().joined(separator: "\n")
                if csig == rsig { found.append(cand) }
            }
            guard found.count == 1, let cand = found.first else { continue }
            do {
                try api.move(remotePath(g), to: remotePath(cand))
            } catch {
                ActivityLog.shared.add(.info, "Не удалось переименовать в облаке", g + " → " + cand)
                continue
            }
            let oldPrefix = g + "/"
            for k in remote.keys.filter({ $0 == g || $0.hasPrefix(oldPrefix) }) {
                guard let item = remote[k] else { continue }
                let nk = cand + String(k.dropFirst(g.count))
                remote[nk] = RemoteItem(isDir: item.isDir, size: item.size, md5: item.md5, modified: item.modified, apiPath: remotePath(nk))
                remote[k] = nil
                if let st = state[k] { newState[nk] = st }
                newState[k] = nil
            }
            mkLocal = mkLocal.filter { $0 != g && !$0.hasPrefix(oldPrefix) }
            delRemote = delRemote.filter { $0 != g && !$0.hasPrefix(oldPrefix) }
            func remap(_ list: [String]) -> [String] {
                list.map { (s: String) -> String in
                    let r = (String(s.dropFirst()))
                    if r == g || r.hasPrefix(oldPrefix) { return "/" + (cand + String(r.dropFirst(g.count))) }
                    return s
                }
            }
            settings.selectedFolders = remap(settings.selectedFolders)
            settings.excludedFolders = remap(settings.excludedFolders)
            ActivityLog.shared.add(.folder, "Папка переименована на Маке: " + (cand as NSString).lastPathComponent, g + " → " + cand)
        }

        // Выбранная папка пропала на Маке и это не переименование — значит её удалили: удаляем в облаке
        // (в корзину облака) и снимаем с неё выбор, чтобы она не вернулась.
        do {
            let gone = goneDirs.filter { mkLocal.contains($0) }
            if !gone.isEmpty {
                for g in gone {
                    let pre = g + "/"
                    mkLocal = mkLocal.filter { $0 != g && !$0.hasPrefix(pre) }
                    if !delRemote.contains(g) { delRemote.append(g) }
                    ActivityLog.shared.add(.folder, "Папка удалена на Маке — удаляю в облаке и снимаю с синхронизации: " + name(g), g)
                }
                func drop(_ list: [String]) -> [String] {
                    list.filter { (s: String) -> Bool in
                        let r = (String(s.dropFirst()))
                        return !gone.contains { r == $0 || r.hasPrefix($0 + "/") }
                    }
                }
                settings.selectedFolders = drop(settings.selectedFolders)
                settings.excludedFolders = drop(settings.excludedFolders)
            }
        }

        // Отдельные файлы, которые переименовали или перенесли: переносим, а не передаём заново.
        // Пара находится по размеру и времени изменения (Мак → сервер) или по размеру и хешу/времени (сервер → Мак);
        // если подходящих несколько — не гадаем и передаём как обычно.
        var moveRemote: [String: String] = [:]      // новое имя → старое
        var moveLocal: [String: String] = [:]
        do {
            func pairs(_ gone: [(String, String)], _ fresh: [(String, String)]) -> [(from: String, to: String)] {
                var g: [String: [String]] = [:], f: [String: [String]] = [:]
                for (rel, k) in gone { g[k, default: []].append(rel) }
                for (rel, k) in fresh { f[k, default: []].append(rel) }
                var out: [(from: String, to: String)] = []
                for (k, a) in g where a.count == 1 { if let b = f[k], b.count == 1 { out.append((from: a[0], to: b[0])) } }
                return out
            }
            func ms(_ t: Double) -> Int64 { Int64((t * 1000).rounded()) }
            let goneR: [(String, String)] = delRemote.compactMap { (rel: String) -> (String, String)? in
                guard let r = remote[rel], !r.isDir, let s = state[rel], s.size > 0 else { return nil }
                return (rel, "\(s.size)|\(ms(s.mtime))")
            }
            let freshR: [(String, String)] = up.compactMap { (rel: String) -> (String, String)? in
                guard let l = local[rel], !l.isDir, remote[rel] == nil, state[rel] == nil, l.size > 0 else { return nil }
                return (rel, "\(l.size)|\(ms(l.mtime))")
            }
            for p in pairs(goneR, freshR) { moveRemote[p.to] = p.from }
            let goneL: [(String, String)] = delLocal.compactMap { (rel: String) -> (String, String)? in
                guard let l = local[rel], !l.isDir, remote[rel] == nil, let s = state[rel], let m = s.md5, s.size > 0 else { return nil }
                return (rel, "\(s.size)|\(m)")
            }
            let freshL: [(String, String)] = down.compactMap { (rel: String) -> (String, String)? in
                guard let r = remote[rel], !r.isDir, local[rel] == nil, state[rel] == nil, r.size > 0, let m = r.md5 else { return nil }
                return (rel, "\(r.size)|\(m)")
            }
            for p in pairs(goneL, freshL) { moveLocal[p.to] = p.from }
            if !moveRemote.isEmpty {
                let fromSet = Set(moveRemote.values), toSet = Set(moveRemote.keys)
                delRemote = delRemote.filter { !fromSet.contains($0) }
                up = up.filter { !toSet.contains($0) }
            }
            if !moveLocal.isEmpty {
                let fromSet = Set(moveLocal.values), toSet = Set(moveLocal.keys)
                delLocal = delLocal.filter { !fromSet.contains($0) }
                down = down.filter { !toSet.contains($0) }
            }
        }

        // Папка удалена на Маке целиком — в облаке удаляем только её, одним запросом,
        // а не каждый файл и вложенную папку по отдельности.
        let delRemoteAll = Set(delRemote)
        do {
            var hasSurvivor = Set<String>()          // папки, в которых что-то остаётся
            for k in remote.keys where !delRemoteAll.contains(k) {
                var p = (k as NSString).deletingLastPathComponent
                while !p.isEmpty && hasSurvivor.insert(p).inserted { p = (p as NSString).deletingLastPathComponent }
            }
            let whole = Set(delRemote.filter { remote[$0]?.isDir == true && !hasSurvivor.contains($0) })
            func insideWhole(_ rel: String) -> Bool {
                var p = (rel as NSString).deletingLastPathComponent
                while !p.isEmpty {
                    if whole.contains(p) { return true }
                    p = (p as NSString).deletingLastPathComponent
                }
                return false
            }
            delRemote = delRemote.filter { !insideWhole($0) }
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
        let total = mkLocal.count + mkRemote.count + down.count + up.count + conflicts.count + dels + moveRemote.count + moveLocal.count
        var done = 0
        let meter = SpeedMeter()
        do {
            // План цикла: что и сколько предстоит передать
            let downBytes = (down + conflicts).reduce(Int64(0)) { $0 + (remote[$1]?.size ?? 0) }
            let upBytes = up.reduce(Int64(0)) { $0 + (local[$1]?.size ?? 0) }
            meter.plan(downBytes + upBytes, files: down.count + up.count + conflicts.count)
            var parts: [String] = []
            if !down.isEmpty { parts.append("скачать \(down.count) (\(SpeedMeter.fmt(Double(downBytes))))") }
            if !up.isEmpty { parts.append("загрузить \(up.count) (\(SpeedMeter.fmt(Double(upBytes))))") }
            if !conflicts.isEmpty { parts.append("конфликтов \(conflicts.count)") }
            if dels > 0 { parts.append("удалить \(dels)") }
            let dirs = mkLocal.count + mkRemote.count
            if dirs > 0 { parts.append("создать папок \(dirs)") }
            let planText = parts.isEmpty || total <= 1 ? "" : "План: " + parts.joined(separator: ", ")
            DispatchQueue.main.async { ActivityLog.shared.plan = planText }
        }
        var nDown = 0, nUp = 0, nDel = 0, nConf = 0, nMoved = 0
        var lastPoll = Date()
        // Список Облака (с учётом уже сделанного) — чтобы следующий проход не читал Облако заново.
        func keepRemoteCache() {
            lock.lock()
            remoteCache = remote
            remoteCacheSel = cacheSel
            remoteCacheDate = usedCache ? cachedDate : readStart
            lock.unlock()
        }
        let stLock = NSLock()          // защищает newState, remote и счётчики, пока файлы передаются параллельно
        keepRemoteCache()              // свежий список не пропадёт, даже если дальше случится сбой
        var foldersDone = 0
        func step(_ text: String) throws {
            done += 1
            if text.hasPrefix("Папка ") {
                foldersDone += 1
                meter.folder(foldersDone, of: mkLocal.count + mkRemote.count)
            }
            onStatus?(.syncing("\(text) (\(done) из \(total))", total > 0 ? Double(done - 1) / Double(total) : nil))
            // Пользователь изменил файлы, пока мы работали, — план устарел: сохраняем сделанное и планируем заново.
            if Date().timeIntervalSince(lastPoll) > 2 {
                lastPoll = Date()
                lock.lock(); let again = pending; lock.unlock()
                if again && done < total {
                    stLock.lock()
                    saveState(newState, stateURL)
                    keepRemoteCache()
                    stLock.unlock()
                    throw CycleInterrupted()
                }
            }
        }
        var netErrors = 0                // ошибок связи подряд; сервер может просто тормозить на отдельных файлах
        func fail(_ rel: String, _ error: Error) throws {
            var fatal = false
            if case SyncError.unauthorized = error { fatal = true }
            if case SyncError.network = error {
                netErrors += 1
                if netErrors >= 5 { fatal = true }   // связи действительно нет — дальше нет смысла
            }
            if fatal {
                stLock.lock(); saveState(newState, stateURL); keepRemoteCache(); stLock.unlock()   // что успели — запомнили
                throw error
            }
            logError(rel, error)
        }
        func name(_ rel: String) -> String { (rel as NSString).lastPathComponent }

        // Файлы передаём одновременно, до 16 штук, скользящим окном: закончилась одна — стартует следующая.
        // На мелких файлах время уходит на запросы, а не на данные, поэтому параллельность даёт основной выигрыш.
        func parallelEach(_ items: [String], _ title: (String) -> String, _ work: @escaping (String) throws -> Void) throws {
            let limiter = DispatchSemaphore(value: 16)
            let group = DispatchGroup()
            let q = DispatchQueue.global(qos: .userInitiated)
            var finished: [(String, Error?)] = []
            var thrown: Error?
            func drain() {
                stLock.lock(); let list = finished; finished = []; stLock.unlock()
                for (rel, err) in list where thrown == nil {
                    do {
                        try step(title(rel))
                        if let e = err { try fail(rel, e) } else { netErrors = 0 }
                    } catch { thrown = error }
                }
            }
            for rel in items {
                drain()
                if thrown != nil { break }
                limiter.wait()
                group.enter()
                q.async {
                    var err: Error?
                    do { try work(rel) } catch { err = error }
                    stLock.lock(); finished.append((rel, err)); stLock.unlock()
                    limiter.signal()
                    group.leave()
                }
            }
            group.wait()
            drain()
            if thrown is CycleInterrupted {
                // передачи, которые ещё шли, закончились — сохраняем окончательное состояние
                stLock.lock(); saveState(newState, stateURL); keepRemoteCache(); stLock.unlock()
            }
            if let e = thrown { throw e }
        }

        func doDownload(_ rel: String, _ r: RemoteItem) throws {
            let dest = localURL(rel)
            let parent = dest.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let tmp = parent.appendingPathComponent(".ydisk-\(UUID().uuidString).part")
            defer { try? fm.removeItem(at: tmp) }
            let t1 = Date()
            try api.download(r.apiPath, to: tmp)
            meter.record(tmp, since: t1)
            try fm.setAttributes([.modificationDate: r.modified], ofItemAtPath: tmp.path)
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dest)
            }
            let st = try statLocal(dest)
            stLock.lock()
            newState[rel] = FileState(isDir: false, md5: r.md5, size: st.size, mtime: st.mtime)
            nDown += 1
            stLock.unlock()
            ActivityLog.shared.add(.download, "Скачано с Диска: " + name(rel), rel)
        }

        func doUpload(_ rel: String) throws {
            let url = localURL(rel)
            let md5 = try fileMD5(url)
            let st = try statLocal(url)
            let t2 = Date()
            try api.upload(url, to: remotePath(rel))
            meter.record(url, since: t2)
            stLock.lock()
            remote[rel] = RemoteItem(isDir: false, size: st.size, md5: md5, modified: Date(), apiPath: remotePath(rel))
            newState[rel] = FileState(isDir: false, md5: md5, size: st.size, mtime: st.mtime)
            nUp += 1
            stLock.unlock()
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
        // Папки создаём параллельно, уровень за уровнем: родитель всегда создан раньше вложенных.
        let mkLevels = Dictionary(grouping: mkRemote) { $0.split(separator: "/").count }
        for depth in mkLevels.keys.sorted() {
            let level = (mkLevels[depth] ?? []).sorted()
            var i = 0
            while i < level.count {
                let batch = Array(level[i ..< min(i + 24, level.count)])
                i += batch.count
                var results = [Error?](repeating: nil, count: batch.count)
                let rlock = NSLock()
                DispatchQueue.concurrentPerform(iterations: batch.count) { k in
                    var e: Error? = nil
                    do { try api.makeDir(remotePath(batch[k])) } catch { e = error }
                    rlock.lock(); results[k] = e; rlock.unlock()
                }
                for (k, rel) in batch.enumerated() {
                    try step("Папка " + name(rel))
                    if let e = results[k] {
                        // Список из памяти мог устареть (папки на сервере удалили вне программы): читаем заново.
                        if usedCache, case SyncError.http(let c, _) = e, c == 409 || c == 404 {
                            lock.lock(); pendingFull = true; pending = true; remoteCache = nil; lock.unlock()
                            stLock.lock(); saveState(newState, stateURL); stLock.unlock()
                            ActivityLog.shared.add(.info, "Список устарел — читаю заново", rel)
                            throw CycleInterrupted()
                        }
                        try fail(rel, e); continue
                    }
                    remote[rel] = RemoteItem(isDir: true, size: 0, md5: nil, modified: Date(), apiPath: remotePath(rel))
                    newState[rel] = FileState(isDir: true, md5: nil, size: 0, mtime: 0)
                    ActivityLog.shared.add(.folder, "Создана папка на Диске: " + name(rel), rel)
                }
            }
        }
        // Переносы файлов: на сервере одним запросом, на Маке — перемещением.
        func doMoveRemote(_ from: String, _ to: String) throws {
            do {
                try api.move(remotePath(from), to: remotePath(to))
            } catch {
                // перенос не вышел — по-старому: заливаем новый файл и убираем старый
                try doUpload(to)
                try? api.delete(remote[from]?.apiPath ?? remotePath(from))
                stLock.lock(); remote[from] = nil; newState[from] = nil; stLock.unlock()
                return
            }
            stLock.lock()
            if let item = remote[from] {
                remote[to] = RemoteItem(isDir: false, size: item.size, md5: item.md5, modified: item.modified, apiPath: remotePath(to))
                remote[from] = nil
            }
            newState[to] = state[from]
            newState[from] = nil
            nMoved += 1
            stLock.unlock()
            ActivityLog.shared.add(.info, "Перенесено на сервере: " + name(to), from + " → " + to)
        }

        func doMoveLocal(_ from: String, _ to: String) throws {
            let dst = localURL(to)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: localURL(from), to: dst)
            let st = try statLocal(dst)
            stLock.lock()
            if let r = remote[to] {
                newState[to] = FileState(isDir: false, md5: r.md5, size: st.size, mtime: st.mtime)
            }
            newState[from] = nil
            nMoved += 1
            stLock.unlock()
            ActivityLog.shared.add(.info, "Перенесено на Маке: " + name(to), from + " → " + to)
        }

        try parallelEach(moveRemote.keys.sorted(), { "⇄ " + name($0) }) { to in
            guard let from = moveRemote[to] else { return }
            try doMoveRemote(from, to)
        }
        for to in moveLocal.keys.sorted() {
            guard let from = moveLocal[to] else { continue }
            try step("Перенос " + name(to))
            do { try doMoveLocal(from, to) } catch { try fail(to, error) }
        }
        try parallelEach(down.sorted().filter { remote[$0] != nil }, { "↓ " + ($0 as NSString).lastPathComponent }) { rel in
            if let r = remote[rel] { try doDownload(rel, r) }
        }
        try parallelEach(up.sorted(), { "↑ " + ($0 as NSString).lastPathComponent }) { rel in try doUpload(rel) }
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
        for rel in delLocal.sorted() where local[rel]?.isDir == false {
            try step("Удаление " + (rel as NSString).lastPathComponent)
            // защита от гонки: файл изменили после составления плана — не трогаем, перечитаем на следующем проходе
            if let l0 = local[rel], let cur = try? statLocal(localURL(rel)), cur.size != l0.size || abs(cur.mtime - l0.mtime) > 0.5 {
                rerunSoon = true; continue
            }
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
                let survivors = remote.keys.contains { $0.hasPrefix(rel + "/") && !delRemoteAll.contains($0) }
                if survivors {
                    newState[rel] = nil          // на Диске в папке есть новое — оставляем, скачаем
                } else {
                    try api.delete(remote[rel]?.apiPath ?? remotePath(rel))
                    remote[rel] = nil
                    newState[rel] = nil
                    nDel += 1
                    for k in newState.keys where k.hasPrefix(rel + "/") { newState[k] = nil }
                    for k in remote.keys where k.hasPrefix(rel + "/") { remote[k] = nil }
                    ActivityLog.shared.add(.delete, "Удалена папка с Диска (вы удалили на Маке): " + name(rel), rel)
                }
            } catch { try fail(rel, error) }
        }

        saveState(newState, stateURL)
        keepRemoteCache()
        if rerunSoon {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.requestSync(fullRead: false) }
        }
        var parts: [String] = []
        if nDown > 0 { parts.append("скачано: \(nDown)") }
        if nUp > 0 { parts.append("загружено: \(nUp)") }
        if nMoved > 0 { parts.append("перенесено: \(nMoved)") }
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

import Foundation

struct RemoteItem {
    let isDir: Bool
    let size: Int64
    let md5: String?
    let modified: Date
    let apiPath: String
}

enum SyncError: LocalizedError {
    case notConfigured
    case unauthorized
    case http(Int, String)
    case network(String)
    case bad(String)
    case needsConfirmation(String)
    case partial(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Не выполнен вход или не выбрана папка"
        case .unauthorized: return "Токен недействителен — войдите заново в настройках"
        case .http(let c, let m): return "Яндекс Диск ответил \(c): \(m)"
        case .network(let m): return "Нет связи: \(m)"
        case .bad(let m): return m
        case .needsConfirmation(let m): return m
        case .partial(let m): return m
        }
    }
}

/// Клиент REST API Яндекс Диска. Все вызовы блокирующие — работает на фоновой очереди движка.
final class YandexAPI {
    struct DiskInfo {
        let login: String
        let used: Int64
        let total: Int64
    }

    private let base = "https://cloud-api.yandex.net/v1/disk"
    private let token: String
    private let session: URLSession
    private static let iso = ISO8601DateFormatter()

    init(token: String) {
        self.token = token
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 6 * 3600
        session = URLSession(configuration: cfg)
    }

    deinit { session.finishTasksAndInvalidate() }

    // MARK: - Низкий уровень

    private static let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func send(_ req: URLRequest) throws -> (Data, Int) {
        var attempt = 0
        while true {
            let sem = DispatchSemaphore(value: 0)
            var out: (Data?, URLResponse?, Error?) = (nil, nil, nil)
            session.dataTask(with: req) { d, r, e in out = (d, r, e); sem.signal() }.resume()
            sem.wait()
            if let e = out.2 {
                attempt += 1
                if attempt < 3 { Thread.sleep(forTimeInterval: Double(attempt) * 2); continue }
                throw SyncError.network(e.localizedDescription)
            }
            let code = (out.1 as? HTTPURLResponse)?.statusCode ?? 0
            if (code == 429 || code >= 500) && attempt < 3 {
                attempt += 1
                Thread.sleep(forTimeInterval: Double(attempt) * 3)
                continue
            }
            return (out.0 ?? Data(), code)
        }
    }

    private func api(_ method: String, _ endpoint: String,
                     _ query: [(String, String)] = []) throws -> (Data, Int) {
        var s = base + endpoint
        if !query.isEmpty {
            s += "?" + query.map { "\($0.0)=\(YandexAPI.enc($0.1))" }.joined(separator: "&")
        }
        guard let url = URL(string: s) else { throw SyncError.bad("Некорректный путь: \(s)") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        let (d, c) = try send(req)
        if c == 401 { throw SyncError.unauthorized }
        return (d, c)
    }

    private func json(_ d: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private func message(_ d: Data) -> String {
        if let o = json(d) {
            return (o["description"] as? String) ?? (o["message"] as? String) ?? "?"
        }
        return String(data: d, encoding: .utf8) ?? "?"
    }

    // MARK: - Методы

    func diskInfo() throws -> DiskInfo {
        let (d, c) = try api("GET", "")
        guard c == 200, let o = json(d) else { throw SyncError.http(c, message(d)) }
        let u = o["user"] as? [String: Any]
        return DiskInfo(login: (u?["login"] as? String) ?? "",
                        used: (o["used_space"] as? NSNumber)?.int64Value ?? 0,
                        total: (o["total_space"] as? NSNumber)?.int64Value ?? 0)
    }

    /// Содержимое одной папки (все страницы). nil — папки нет.
    private func listOne(_ dir: String, root: String) throws -> [(String, RemoteItem)]? {
        var out: [(String, RemoteItem)] = []
        var offset = 0
        let fields = "_embedded.items.name,_embedded.items.type,_embedded.items.size,"
            + "_embedded.items.md5,_embedded.items.modified"
        while true {
            let (d, c) = try api("GET", "/resources",
                                 [("path", dir), ("limit", "1000"),
                                  ("offset", String(offset)), ("fields", fields)])
            if c == 404 { return offset == 0 ? nil : out }
            guard c == 200, let o = json(d) else { throw SyncError.http(c, message(d)) }
            let items = ((o["_embedded"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            for it in items {
                guard let name = it["name"] as? String, let type = it["type"] as? String else { continue }
                let childPath = (dir == "/" ? "" : dir) + "/" + name
                let rel = String(childPath.dropFirst(root == "/" ? 1 : root.count + 1))
                let modified = (it["modified"] as? String).flatMap { YandexAPI.iso.date(from: $0) } ?? Date()
                out.append((rel.precomposedStringWithCanonicalMapping, RemoteItem(
                    isDir: type == "dir",
                    size: (it["size"] as? NSNumber)?.int64Value ?? 0,
                    md5: it["md5"] as? String,
                    modified: modified,
                    apiPath: childPath)))
            }
            if items.count < 1000 { break }
            offset += items.count
        }
        return out
    }

    /// Рекурсивный список всего содержимого папки. Ключ — относительный путь (NFC).
    /// nil, если самой папки на Диске нет.
    /// Папки читаются по уровням, по 4 запроса одновременно.
    /// progress(папок прочитано, объектов найдено) вызывается из фоновых потоков.
    func listTree(root: String, progress: ((Int, Int) -> Void)? = nil) throws -> [String: RemoteItem]? {
        var result: [String: RemoteItem] = [:]
        var level = [root]
        var folders = 0
        let lock = NSLock()
        let q = DispatchQueue.global(qos: .utility)
        while !level.isEmpty {
            var next: [String] = []
            var firstError: Error?
            var rootMissing = false
            let limiter = DispatchSemaphore(value: 4)
            let group = DispatchGroup()
            for dir in level {
                lock.lock(); let stop = firstError != nil; lock.unlock()
                if stop { break }
                limiter.wait()
                group.enter()
                q.async {
                    defer { limiter.signal(); group.leave() }
                    do {
                        guard let items = try self.listOne(dir, root: root) else {
                            if dir == root { lock.lock(); rootMissing = true; lock.unlock() }
                            return
                        }
                        lock.lock()
                        for (rel, item) in items {
                            result[rel] = item
                            if item.isDir { next.append(item.apiPath) }
                        }
                        folders += 1
                        let f = folders, n = result.count
                        lock.unlock()
                        progress?(f, n)
                    } catch {
                        lock.lock()
                        if firstError == nil { firstError = error }
                        lock.unlock()
                    }
                }
            }
            group.wait()
            if let e = firstError { throw e }
            if rootMissing { return nil }
            level = next
        }
        return result
    }

    /// Имена подпапок (только папки) — для дерева выбора в настройках.
    func listDirs(_ path: String) throws -> [String] {
        var names: [String] = []
        var offset = 0
        while true {
            let (d, c) = try api("GET", "/resources",
                                 [("path", path), ("limit", "1000"), ("offset", String(offset)),
                                  ("fields", "_embedded.items.name,_embedded.items.type")])
            if c == 404 { return [] }
            guard c == 200, let o = json(d) else { throw SyncError.http(c, message(d)) }
            let items = ((o["_embedded"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            for it in items where (it["type"] as? String) == "dir" {
                if let n = it["name"] as? String { names.append(n) }
            }
            if items.count < 1000 { break }
            offset += items.count
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// md5 файла на Диске; nil — файла нет.
    func remoteMD5(_ path: String) throws -> String? {
        let (d, c) = try api("GET", "/resources", [("path", path), ("fields", "md5,type")])
        if c == 404 { return nil }
        guard c == 200, let o = json(d) else { throw SyncError.http(c, message(d)) }
        return o["md5"] as? String
    }

    func makeDir(_ path: String) throws {
        let (d, c) = try api("PUT", "/resources", [("path", path)])
        if c == 201 { return }
        if c == 409, (json(d)?["error"] as? String)?.contains("Existent") == true { return }
        throw SyncError.http(c, message(d))
    }

    /// Создаёт папку со всеми родителями.
    func ensureDir(_ path: String) throws {
        var cur = ""
        for comp in path.split(separator: "/") {
            cur += "/" + comp
            try makeDir(cur)
        }
    }

    /// Удаление в корзину Диска.
    func delete(_ path: String) throws {
        let (d, c) = try api("DELETE", "/resources", [("path", path), ("permanently", "false")])
        if c == 204 || c == 202 || c == 404 { return }
        throw SyncError.http(c, message(d))
    }

    func download(_ path: String, to staging: URL) throws {
        let (d, c) = try api("GET", "/resources/download", [("path", path)])
        guard c == 200, let href = json(d)?["href"] as? String, let url = URL(string: href) else {
            throw SyncError.http(c, message(d))
        }
        let sem = DispatchSemaphore(value: 0)
        var err: Error?
        var status = 0
        session.downloadTask(with: url) { tmp, resp, e in
            err = e
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let tmp = tmp, e == nil, status == 200 {
                do {
                    try? FileManager.default.removeItem(at: staging)
                    try FileManager.default.moveItem(at: tmp, to: staging)
                } catch { err = error }
            }
            sem.signal()
        }.resume()
        sem.wait()
        if let e = err { throw SyncError.network(e.localizedDescription) }
        if status != 200 { throw SyncError.http(status, "ошибка скачивания") }
    }

    func upload(_ file: URL, to path: String) throws {
        let (d, c) = try api("GET", "/resources/upload", [("path", path), ("overwrite", "true")])
        guard c == 200, let href = json(d)?["href"] as? String, let url = URL(string: href) else {
            throw SyncError.http(c, message(d))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        let sem = DispatchSemaphore(value: 0)
        var err: Error?
        var status = 0
        session.uploadTask(with: req, fromFile: file) { _, resp, e in
            err = e
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }.resume()
        sem.wait()
        if let e = err { throw SyncError.network(e.localizedDescription) }
        if status != 201 && status != 202 { throw SyncError.http(status, "ошибка загрузки") }
    }
}

// MARK: - Корзина Диска

struct TrashItem: Identifiable {
    let path: String        // путь в корзине вида "trash:/имя_хэш"
    let name: String
    let originPath: String  // откуда удалено
    let deleted: Date
    let size: Int64
    let isDir: Bool
    var id: String { path }
}

extension YandexAPI {
    func listTrash() throws -> [TrashItem] {
        var out: [TrashItem] = []
        var offset = 0
        let fields = "_embedded.items.name,_embedded.items.path,_embedded.items.type,"
            + "_embedded.items.size,_embedded.items.deleted,_embedded.items.origin_path"
        while true {
            let (d, c) = try api("GET", "/trash/resources",
                                 [("path", "/"), ("limit", "200"), ("offset", String(offset)), ("fields", fields)])
            if c == 404 { return [] }
            guard c == 200, let o = json(d) else { throw SyncError.http(c, message(d)) }
            let items = ((o["_embedded"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            for it in items {
                guard let path = it["path"] as? String, let name = it["name"] as? String else { continue }
                let origin = ((it["origin_path"] as? String) ?? "").replacingOccurrences(of: "disk:", with: "")
                let deleted = (it["deleted"] as? String).flatMap { YandexAPI.iso.date(from: $0) } ?? Date()
                out.append(TrashItem(path: path, name: name, originPath: origin, deleted: deleted,
                                     size: (it["size"] as? NSNumber)?.int64Value ?? 0,
                                     isDir: (it["type"] as? String) == "dir"))
            }
            if items.count < 200 { break }
            offset += items.count
        }
        return out.sorted { $0.deleted > $1.deleted }
    }

    /// path == nil — очистить всю корзину.
    func deleteFromTrash(_ path: String?) throws {
        var q: [(String, String)] = []
        if let p = path { q.append(("path", p)) }
        let (d, c) = try api("DELETE", "/trash/resources", q)
        try finishTrashCall(c, d)
    }

    func restoreFromTrash(_ path: String) throws {
        let (d, c) = try api("PUT", "/trash/resources/restore", [("path", path)])
        try finishTrashCall(c, d)
    }

    private func finishTrashCall(_ c: Int, _ d: Data) throws {
        if c == 204 || c == 201 { return }
        if c == 202 {
            if let href = json(d)?["href"] as? String { waitOperation(href) }
            return
        }
        throw SyncError.http(c, message(d))
    }

    /// Ждёт завершения асинхронной операции Диска (до ~40 секунд).
    private func waitOperation(_ href: String) {
        guard let url = URL(string: href) else { return }
        for _ in 0..<40 {
            var req = URLRequest(url: url)
            req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
            if let (d, c) = try? send(req), c == 200,
               let st = json(d)?["status"] as? String, st != "in-progress" { return }
            Thread.sleep(forTimeInterval: 1)
        }
    }
}

// MARK: - Публичные ссылки

struct PublicItem: Identifiable {
    let path: String        // путь на Диске, например "/Документы/a.pdf"
    let name: String
    let url: String
    let isDir: Bool
    var id: String { path }
}

extension YandexAPI {
    /// Публикует файл или папку и возвращает публичную ссылку.
    func publish(_ path: String) throws -> String {
        let (d, c) = try api("PUT", "/resources/publish", [("path", path)])
        if c == 404 { throw SyncError.bad("Этого файла ещё нет на Диске — дождитесь окончания синхронизации и повторите") }
        guard c == 200 else { throw SyncError.http(c, message(d)) }
        let (d2, c2) = try api("GET", "/resources", [("path", path), ("fields", "public_url")])
        guard c2 == 200, let url = json(d2)?["public_url"] as? String else { throw SyncError.http(c2, message(d2)) }
        return url
    }

    /// Закрывает публичный доступ (ссылка перестаёт работать).
    func unpublish(_ path: String) throws {
        let (d, c) = try api("PUT", "/resources/unpublish", [("path", path)])
        if c == 200 || c == 404 { return }
        throw SyncError.http(c, message(d))
    }

    func listPublic() throws -> [PublicItem] {
        var out: [PublicItem] = []
        var offset = 0
        let fields = "items.name,items.path,items.type,items.public_url"
        while true {
            let (d, c) = try api("GET", "/resources/public",
                                 [("limit", "200"), ("offset", String(offset)), ("fields", fields)])
            guard c == 200, let o = json(d) else { throw SyncError.http(c, message(d)) }
            let items = (o["items"] as? [[String: Any]]) ?? []
            for it in items {
                guard let path = it["path"] as? String, let url = it["public_url"] as? String else { continue }
                let clean = path.replacingOccurrences(of: "disk:", with: "")
                out.append(PublicItem(path: clean,
                                      name: (it["name"] as? String) ?? (clean as NSString).lastPathComponent,
                                      url: url, isDir: (it["type"] as? String) == "dir"))
            }
            if items.count < 200 { break }
            offset += items.count
        }
        return out
    }
}

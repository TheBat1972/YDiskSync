import Foundation
import Security

extension Notification.Name {
    static let tokenChanged = Notification.Name("ydisk.tokenChanged")
}

enum Keychain {
    private static let service = "ru.local.YDiskSync"

    static func set(_ value: String?, key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard let value = value, !value.isEmpty else { return }
        var q = base
        q[kSecValueData as String] = value.data(using: .utf8)!
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard
    private var tokenLoaded = false
    private var tokenValue: String?

    /// OAuth-токен хранится в связке ключей.
    var token: String? {
        get {
            if !tokenLoaded { tokenValue = Keychain.get(key: "token"); tokenLoaded = true }
            return tokenValue
        }
        set {
            tokenValue = newValue
            tokenLoaded = true
            Keychain.set(newValue, key: "token")
        }
    }

    var clientID: String {
        get { d.string(forKey: "clientID") ?? "" }
        set { d.set(newValue, forKey: "clientID") }
    }
    var localFolder: String {
        get { d.string(forKey: "localFolder") ?? "" }
        set { d.set(newValue, forKey: "localFolder") }
    }
    /// Папки Диска, которые синхронизируются: ["/"] — весь Диск, иначе например ["/Документы", "/Фото/2024"].
    var selectedFolders: [String] {
        get {
            let v = d.stringArray(forKey: "selectedFolders") ?? []
            return Settings.normalize(v)
        }
        set { d.set(Settings.normalize(newValue), forKey: "selectedFolders") }
    }
    /// Пользователь хотя бы раз явно выбрал, что синхронизировать.
    var selectionConfirmed: Bool {
        get { d.bool(forKey: "selectionConfirmed") }
        set { d.set(newValue, forKey: "selectionConfirmed") }
    }
    var intervalMinutes: Int {
        get { let v = d.integer(forKey: "intervalMinutes"); return v > 0 ? v : 5 }
        set { d.set(newValue, forKey: "intervalMinutes") }
    }
    var paused: Bool {
        get { d.bool(forKey: "paused") }
        set { d.set(newValue, forKey: "paused") }
    }

    /// Приводит пути к виду "/A/B", убирает дубли и папки, вложенные в уже выбранные.
    static func normalize(_ list: [String]) -> [String] {
        var items: [String] = []
        for var p in list {
            p = p.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.hasPrefix("disk:") { p = String(p.dropFirst(5)) }
            if !p.hasPrefix("/") { p = "/" + p }
            while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            items.append(p.precomposedStringWithCanonicalMapping)
        }
        if items.contains("/") { return ["/"] }
        let unique = Array(Set(items)).sorted()
        return unique.filter { p in !unique.contains { $0 != p && p.hasPrefix($0 + "/") } }
    }

    var isConfigured: Bool { token != nil && !localFolder.isEmpty && selectionConfirmed && !selectedFolders.isEmpty }
}

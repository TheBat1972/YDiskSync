import Foundation

/// Вход через Яндекс OAuth (implicit flow). В кабинете oauth.yandex.ru у приложения
/// должен быть Callback URI  ydisksync://callback
enum OAuth {
    static func authorizeURL(clientID: String) -> URL? {
        let id = YandexAPI.enc(clientID.trimmingCharacters(in: .whitespacesAndNewlines))
        return URL(string: "https://oauth.yandex.ru/authorize?response_type=token&client_id=\(id)")
    }

    /// Достаёт access_token из ydisksync://callback#access_token=...
    static func token(from url: URL) -> String? {
        guard let fragment = url.fragment,
              let items = URLComponents(string: "?" + fragment)?.queryItems else { return nil }
        return items.first(where: { $0.name == "access_token" })?.value
    }

    static func errorText(from url: URL) -> String? {
        guard let fragment = url.fragment ?? url.query,
              let items = URLComponents(string: "?" + fragment)?.queryItems else { return nil }
        return items.first(where: { $0.name == "error_description" })?.value
            ?? items.first(where: { $0.name == "error" })?.value
    }
}

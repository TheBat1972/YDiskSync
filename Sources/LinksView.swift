import SwiftUI
import Cocoa

final class LinksModel: ObservableObject {
    @Published var items: [PublicItem] = []
    @Published var loading = false
    @Published var message: String? = nil

    func reload() { perform("Загрузка…") { _ in } }

    func unpublish(_ item: PublicItem) {
        perform("Закрываю доступ…") { api in try api.unpublish(item.path) }
        ActivityLog.shared.add(.info, "Ссылка закрыта: " + item.name, item.path)
    }

    private func perform(_ busy: String, _ work: @escaping (YandexAPI) throws -> Void) {
        guard let token = Settings.shared.token else { message = "Аккаунт не подключён"; return }
        loading = true
        message = busy
        DispatchQueue.global(qos: .userInitiated).async {
            var err: String?
            var list: [PublicItem]?
            do {
                let api = YandexAPI(token: token)
                try work(api)
                list = try api.listPublic()
            } catch { err = error.localizedDescription }
            DispatchQueue.main.async {
                self.loading = false
                if let l = list { self.items = l; self.message = nil } else { self.message = err }
            }
        }
    }
}

struct LinksView: View {
    @ObservedObject var model: LinksModel

    private func confirm(_ item: PublicItem) -> Bool {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Закрыть доступ по ссылке?"
        a.informativeText = "«\(item.name)» перестанет открываться по этой ссылке. Сам файл останется на Диске."
        a.addButton(withTitle: "Закрыть доступ")
        a.addButton(withTitle: "Отмена")
        return a.runModal() == .alertFirstButtonReturn
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Публичные ссылки").font(.headline)
                Spacer()
                if model.loading { ProgressView().scaleEffect(0.6) }
                if let m = model.message {
                    Text(m).font(.caption).foregroundColor(model.loading ? .secondary : .red).lineLimit(1)
                }
                Button("Создать ссылку…") {
                    LinkService.chooseAndCreate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.reload() }
                }
                Button("Обновить") { model.reload() }.disabled(model.loading)
            }
            .padding(12)
            Divider()

            if model.items.isEmpty && !model.loading {
                Spacer()
                Text("Публичных ссылок пока нет").foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.items) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.isDir ? "folder" : "doc")
                                    .foregroundColor(.secondary).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(item.url).font(.system(size: 11)).foregroundColor(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 8)
                                Button("Копировать") { LinkService.copy(item.url) }
                                Button("Открыть") {
                                    if let u = URL(string: item.url) { NSWorkspace.shared.open(u) }
                                }
                                Button("Закрыть доступ") { if confirm(item) { model.unpublish(item) } }
                                    .disabled(model.loading)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
            }
            Divider()
            Text("Ссылку можно создать и из Finder: правый клик по файлу → «Службы» → «Ссылка Яндекс Диска».")
                .font(.caption).foregroundColor(.secondary).padding(10)
        }
        .frame(minWidth: 680, minHeight: 420)
    }
}

final class LinksWindowController {
    private var window: NSWindow?

    func show() {
        window?.close()
        let model = LinksModel()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Публичные ссылки"
        w.contentView = NSHostingView(rootView: LinksView(model: model))
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        model.reload()
    }
}

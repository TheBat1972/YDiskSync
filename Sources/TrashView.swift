import SwiftUI
import Cocoa

final class TrashModel: ObservableObject {
    @Published var items: [TrashItem] = []
    @Published var selected: Set<String> = []
    @Published var loading = false
    @Published var message: String? = nil
    var onChanged: (() -> Void)?

    func reload() { perform("Загрузка списка…", changed: false) { _ in } }

    func restoreSelected() {
        let paths = Array(selected)
        perform("Восстановление…", changed: true) { api in
            for p in paths { try api.restoreFromTrash(p) }
        }
        ActivityLog.shared.add(.info, "Восстановлено из корзины Диска: \(paths.count)", "Файлы вернутся и в папку на Маке")
    }

    func deleteSelected() {
        let paths = Array(selected)
        perform("Удаление навсегда…", changed: false) { api in
            for p in paths { try api.deleteFromTrash(p) }
        }
        ActivityLog.shared.add(.delete, "Удалено из корзины Диска навсегда: \(paths.count)")
    }

    func clearAll() {
        perform("Очистка корзины…", changed: false) { api in try api.deleteFromTrash(nil) }
        ActivityLog.shared.add(.delete, "Корзина Диска очищена")
    }

    private func perform(_ busy: String, changed: Bool, _ work: @escaping (YandexAPI) throws -> Void) {
        guard let token = Settings.shared.token else { message = "Аккаунт не подключён"; return }
        loading = true
        message = busy
        DispatchQueue.global(qos: .userInitiated).async {
            var err: String?
            var list: [TrashItem]?
            do {
                let api = YandexAPI(token: token)
                try work(api)
                list = try api.listTrash()
            } catch {
                err = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.loading = false
                if let l = list {
                    self.items = l
                    self.selected = self.selected.filter { id in l.contains { $0.id == id } }
                    self.message = nil
                    if changed { self.onChanged?() }
                } else {
                    self.message = err
                }
            }
        }
    }
}

struct TrashView: View {
    @ObservedObject var model: TrashModel

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy HH:mm"; return f
    }()

    private func sizeText(_ i: TrashItem) -> String {
        i.isDir ? "" : ByteCountFormatter.string(fromByteCount: i.size, countStyle: .file)
    }

    private func confirm(_ title: String, _ text: String, _ button: String) -> Bool {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Отмена")
        return a.runModal() == .alertFirstButtonReturn
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Корзина Яндекс Диска").font(.headline)
                Spacer()
                if model.loading { ProgressView().scaleEffect(0.6) }
                if let m = model.message {
                    Text(m).font(.caption).foregroundColor(model.loading ? .secondary : .red).lineLimit(1)
                }
                Button("Обновить") { model.reload() }.disabled(model.loading)
            }
            .padding(12)
            Divider()

            if model.items.isEmpty && !model.loading {
                Spacer()
                Text("Корзина пуста").foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.items) { item in
                            HStack(spacing: 8) {
                                Toggle("", isOn: Binding(
                                    get: { model.selected.contains(item.id) },
                                    set: { on in
                                        if on { model.selected.insert(item.id) } else { model.selected.remove(item.id) }
                                    }))
                                    .labelsHidden()
                                Image(systemName: item.isDir ? "folder" : "doc")
                                    .foregroundColor(.secondary).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(item.originPath.isEmpty ? "—" : "Было: " + item.originPath)
                                        .font(.system(size: 11)).foregroundColor(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 8)
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(TrashView.dateFormat.string(from: item.deleted)).font(.system(size: 11))
                                    Text(sizeText(item)).font(.system(size: 11)).foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            Divider()
                        }
                    }
                }
            }

            Divider()
            HStack {
                Text("Всего: \(model.items.count), выбрано: \(model.selected.count)").font(.caption)
                Spacer()
                Button(model.selected.count == model.items.count && !model.items.isEmpty ? "Снять выбор" : "Выбрать все") {
                    if model.selected.count == model.items.count { model.selected = [] }
                    else { model.selected = Set(model.items.map { $0.id }) }
                }
                .disabled(model.items.isEmpty)
                Button("Восстановить") { model.restoreSelected() }
                    .disabled(model.selected.isEmpty || model.loading)
                Button("Удалить навсегда") {
                    if confirm("Удалить выбранное навсегда?",
                               "Выбрано объектов: \(model.selected.count). Восстановить их будет нельзя.", "Удалить навсегда") {
                        model.deleteSelected()
                    }
                }
                .disabled(model.selected.isEmpty || model.loading)
                Button("Очистить корзину") {
                    if confirm("Очистить корзину Диска?",
                               "Все объекты в корзине (\(model.items.count)) будут удалены навсегда. Это нельзя отменить.", "Очистить") {
                        model.clearAll()
                    }
                }
                .disabled(model.items.isEmpty || model.loading)
            }
            .padding(12)
        }
        .frame(minWidth: 620, minHeight: 440)
    }
}

final class TrashWindowController {
    private var window: NSWindow?

    func show(onChanged: @escaping () -> Void) {
        window?.close()
        let model = TrashModel()
        model.onChanged = onChanged
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Корзина Яндекс Диска"
        w.contentView = NSHostingView(rootView: TrashView(model: model))
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        model.reload()
    }
}

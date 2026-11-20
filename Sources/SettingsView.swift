import SwiftUI
import Cocoa
import ServiceManagement

// MARK: - Дерево папок Диска

/// Цвета подписей: подбираются отдельно для светлой и тёмной темы, чтобы текст читался (контраст не ниже ~4.5:1).
enum TagColor {
    static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static let mac = dyn(NSColor(srgbRed: 0.00, green: 0.45, blue: 0.14, alpha: 1),
                         NSColor(srgbRed: 0.38, green: 0.86, blue: 0.48, alpha: 1))
    static let cloud = dyn(NSColor(srgbRed: 0.00, green: 0.34, blue: 0.78, alpha: 1),
                           NSColor(srgbRed: 0.45, green: 0.72, blue: 1.00, alpha: 1))
    static let warn = dyn(NSColor(srgbRed: 0.70, green: 0.33, blue: 0.00, alpha: 1),
                          NSColor(srgbRed: 1.00, green: 0.72, blue: 0.32, alpha: 1))
}

final class FolderNode: ObservableObject, Identifiable {
    let name: String
    let path: String
    @Published var children: [FolderNode]? = nil
    @Published var expanded = false
    @Published var loading = false
    @Published var error: String? = nil
    /// Папка есть только на Маке, в хранилище её ещё нет (появится после отметки галочкой).
    var localOnly = false
    /// Папка есть в хранилище, но на Маке её нет.
    var cloudOnly = false
    var id: String { path }

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

final class FolderTreeModel: ObservableObject {
    let root = FolderNode(name: "Диск", path: "/")
    /// Отмеченные пути. "/" — корень, то есть весь Диск.
    @Published var selected: Set<String>
    /// Исключения: папки внутри выбранной, которые синхронизировать не нужно.
    @Published var excluded: Set<String>

    init() {
        let st = Settings.shared
        selected = st.selectionConfirmed ? Set(st.selectedFolders) : []
        excluded = st.selectionConfirmed ? Set(st.excludedFolders) : []
    }

    var result: [String] { Settings.normalize(Array(selected)) }
    var excludedResult: [String] { Settings.normalize(Array(excluded)) }

    var baseSummary: String {
        if selected.contains("/") { return "Весь Диск" }
        if selected.isEmpty { return "Ничего не выбрано" }
        let names = selected.sorted().map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
        let shown = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? "\(shown) и ещё \(names.count - 3)" : shown
    }

    var summary: String {
        if selected.isEmpty { return "Ничего не выбрано" }
        if excluded.isEmpty { return baseSummary }
        let names = excluded.sorted().map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
        let shown = names.prefix(3).joined(separator: ", ")
        return baseSummary + "; кроме: " + (names.count > 3 ? "\(shown) и ещё \(names.count - 3)" : shown)
    }

    /// Правило, действующее для пути: ближайшее (самое глубокое) из выбранных или исключённых.
    private func nearestRule(_ path: String, ignoring: String? = nil) -> (len: Int, included: Bool)? {
        var best: (len: Int, included: Bool)? = nil
        func consider(_ r: String, _ inc: Bool) {
            if r == ignoring { return }
            guard r == "/" || path == r || path.hasPrefix(r + "/") else { return }
            let len = r == "/" ? 0 : r.count
            if let b = best, b.len > len { return }
            best = (len, inc)
        }
        for r in selected { consider(r, true) }
        for r in excluded { consider(r, false) }
        return best
    }

    /// Синхронизируется ли папка (выбрана сама или внутри выбранной и не исключена).
    func isIncluded(_ path: String) -> Bool { nearestRule(path)?.included ?? false }

    /// Внутри папки есть правила, отличающиеся от её собственного состояния («выбрано частично»).
    func isPartial(_ path: String) -> Bool {
        let prefix = path == "/" ? "/" : path + "/"
        if isIncluded(path) { return excluded.contains { $0.hasPrefix(prefix) } }
        return selected.contains { $0.hasPrefix(prefix) }
    }

    /// Папка показывается отмеченной, если синхронизируется сама или хотя бы что-то внутри неё.
    func isChecked(_ path: String) -> Bool { isIncluded(path) || isPartial(path) }

    func toggle(_ path: String, on: Bool) {
        if path == "/" {
            selected = on ? ["/"] : []
            excluded = []
            return
        }
        let prefix = path + "/"
        selected = selected.filter { $0 != path && !$0.hasPrefix(prefix) }
        excluded = excluded.filter { $0 != path && !$0.hasPrefix(prefix) }
        // Старые записи, сохранённые без пробела в конце имени, убираем, чтобы они не висели лишними исключениями.
        let alt = path.trimmingCharacters(in: .whitespaces)
        if alt != path {
            selected = selected.filter { $0 != alt && !$0.hasPrefix(alt + "/") }
            excluded = excluded.filter { $0 != alt && !$0.hasPrefix(alt + "/") }
        }
        let inherited = nearestRule(path)?.included ?? false
        if on && !inherited { selected.insert(path) }
        if !on && inherited { excluded.insert(path) }
        prune()
    }

    /// Убирает лишние правила: выбранную папку внутри уже выбранной и исключение вне выбранного.
    private func prune() {
        var changed = true
        while changed {
            changed = false
            for r in selected where nearestRule(r, ignoring: r)?.included == true {
                selected.remove(r); changed = true; break
            }
            if changed { continue }
            for r in excluded where nearestRule(r, ignoring: r)?.included != true {
                excluded.remove(r); changed = true; break
            }
        }
    }

    func load(_ node: FolderNode) {
        guard node.children == nil, !node.loading else { return }
        let token = Settings.shared.token
        if token == nil && !node.localOnly { return }
        node.loading = true
        node.error = nil
        let localRoot = Settings.shared.localFolder
        DispatchQueue.global(qos: .userInitiated).async {
            var cloudNames: [String] = []
            var err: String? = nil
            if !node.localOnly, let token = token {
                do { cloudNames = try YandexAPI(token: token).listDirs(node.path) }
                catch { err = error.localizedDescription }
            }
            // Папки, которые есть на Маке, но ещё нет в хранилище, тоже показываем: их можно отметить и выгрузить.
            var localNames: [String] = []
            if !localRoot.isEmpty {
                let rel = node.path == "/" ? "" : (String(node.path.dropFirst()))
                var url = URL(fileURLWithPath: localRoot)
                if !rel.isEmpty { url = url.appendingPathComponent(rel) }
                if let items = try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                    localNames = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                        .map { $0.lastPathComponent.precomposedStringWithCanonicalMapping }
                }
            }
            DispatchQueue.main.async {
                let base = node.path == "/" ? "" : node.path
                var nodes = cloudNames.map { FolderNode(name: $0, path: base + "/" + $0) }
                if !localRoot.isEmpty && !node.cloudOnly {
                    let localPaths = Set(localNames.map { base + "/" + ($0) })
                    for n in nodes where !localPaths.contains(n.path) { n.cloudOnly = true }
                }
                let known = Set(nodes.map { $0.path })
                for n in localNames {
                    let path = base + "/" + (n)
                    if known.contains(path) { continue }
                    let ln = FolderNode(name: n, path: path)
                    ln.localOnly = true
                    nodes.append(ln)
                }
                nodes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                node.children = nodes
                node.error = err
                if err == nil && node.path == "/" && !node.localOnly && cloudNames.isEmpty && !localNames.isEmpty {
                    node.error = "Список с сервера пришёл пустым — нажмите «Обновить список»."
                }
                node.loading = false
            }
        }
    }

    func reload() {
        root.children = nil
        load(root)
    }
}

struct FolderList: View {
    @ObservedObject var node: FolderNode
    @ObservedObject var model: FolderTreeModel
    let level: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let err = node.error {
                Text(err).font(.caption).foregroundColor(.red)
                    .padding(.leading, CGFloat(level) * 18)
            }
            if let ch = node.children {
                if ch.isEmpty && node.error == nil {
                    Text("Вложенных папок нет").font(.caption).foregroundColor(.secondary)
                        .padding(.leading, CGFloat(level) * 18 + 18)
                }
                ForEach(ch) { FolderRow(node: $0, model: model, level: level) }
            } else if node.loading {
                Text("Загрузка списка папок…").font(.caption).foregroundColor(.secondary)
                    .padding(.leading, CGFloat(level) * 18 + 18)
            }
        }
    }
}

struct FolderRow: View {
    @ObservedObject var node: FolderNode
    @ObservedObject var model: FolderTreeModel
    let level: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Button(action: {
                    node.expanded.toggle()
                    if node.expanded { model.load(node) }
                }) {
                    Image(systemName: node.expanded ? "chevron.down" : "chevron.right").frame(width: 14)
                }
                .buttonStyle(PlainButtonStyle())
                Toggle(isOn: Binding(
                    get: { model.isChecked(node.path) },
                    set: { model.toggle(node.path, on: $0) })) {
                    Label(node.name, systemImage: "folder")
                }
                if node.localOnly {
                    Text("только на Маке").font(.caption.weight(.medium)).foregroundColor(TagColor.mac)
                }
                if node.cloudOnly {
                    Text("только в облаке").font(.caption.weight(.medium)).foregroundColor(TagColor.cloud)
                }
                if model.isPartial(node.path) {
                    Text("выбрано частично").font(.caption.weight(.medium)).foregroundColor(TagColor.warn)
                }
            }
            .padding(.leading, CGFloat(level) * 18)
            if node.expanded {
                FolderList(node: node, model: model, level: level + 1)
            }
        }
    }
}

// MARK: - Окно выбора папок

struct FolderPickerView: View {
    @ObservedObject var model: FolderTreeModel
    var onDone: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Что синхронизировать").font(.headline)
            Text("Отметьте корень «Весь Диск», чтобы синхронизировать всё, или выберите отдельные папки. "
                 + "Если снять галочку с папки, её копия на Маке удалится (в Корзину), а на Диске ничего не изменится.")
                .font(.caption).foregroundColor(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(
                        get: { model.isChecked("/") },
                        set: { model.toggle("/", on: $0) })) {
                        HStack(spacing: 4) {
                            Label("Весь Диск (корень)", systemImage: "externaldrive")
                            if model.isPartial("/") {
                                Text("выбрано частично").font(.caption.weight(.medium)).foregroundColor(TagColor.warn)
                            }
                        }
                    }
                    FolderList(node: model.root, model: model, level: 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .border(Color.gray.opacity(0.4))
            HStack {
                Text("Выбрано: " + model.summary).font(.caption)
                Spacer()
                Button("Обновить список") { model.reload() }
                Button("Отмена") { onCancel() }
                Button("Готово") { onDone() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 460, minHeight: 440)
    }
}

final class PickerWindowController {
    static let shared = PickerWindowController()
    private var window: NSWindow?

    func show(model: FolderTreeModel) {
        window?.close()
        let snapshot = model.selected
        let exSnapshot = model.excluded
        let view = FolderPickerView(
            model: model,
            onDone: { [weak self] in self?.window?.close() },
            onCancel: { [weak self] in model.selected = snapshot; model.excluded = exSnapshot; self?.window?.close() })
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Что синхронизировать"
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        model.load(model.root)
    }
}

// MARK: - Окно настроек

struct SettingsView: View {
    @State private var clientID = Settings.shared.clientID
    @State private var manualToken = ""
    @State private var localFolder = Settings.shared.localFolder
    @State private var interval = Settings.shared.intervalMinutes
    @State private var loggedIn = Settings.shared.token != nil
    @State private var launchAtLogin = false
    @StateObject private var model = FolderTreeModel()

    var onApply: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Аккаунт
            Text("1. Аккаунт").font(.headline)
            HStack {
                Text(loggedIn ? "✅ Подключено" : "Не подключено")
                Spacer()
                if loggedIn {
                    Button("Отключить аккаунт") {
                        Settings.shared.token = nil
                        loggedIn = false
                        model.root.children = nil
                    }
                }
            }
            HStack {
                TextField("ID приложения (Client ID)", text: $clientID)
                Button("Открыть страницу входа") {
                    Settings.shared.clientID = clientID
                    if let url = OAuth.authorizeURL(clientID: clientID) { NSWorkspace.shared.open(url) }
                }
                .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                SecureField("Вставьте токен со страницы входа", text: $manualToken)
                Button("Подключить") {
                    let t = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    Settings.shared.token = t
                    manualToken = ""
                    loggedIn = true
                    NotificationCenter.default.post(name: .tokenChanged, object: nil)
                }
            }

            Divider()

            // Папка на Маке
            Text("2. Папка на этом Маке").font(.headline)
            HStack {
                Text(localFolder.isEmpty ? "Не выбрана" : localFolder)
                    .foregroundColor(localFolder.isEmpty ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Выбрать…") { chooseFolder() }
            }

            Divider()

            // Что синхронизировать
            Text("3. Что синхронизировать").font(.headline)
            HStack {
                Text(loggedIn ? model.summary : "Сначала подключите аккаунт")
                    .foregroundColor(loggedIn ? .primary : .secondary)
                    .lineLimit(1)
                Spacer()
                Button("Выбрать папки Диска…") { PickerWindowController.shared.show(model: model) }
                    .disabled(!loggedIn)
            }

            Divider()

            HStack {
                Text("Проверять Диск раз в")
                Picker("", selection: $interval) {
                    ForEach([1, 5, 15, 30, 60], id: \.self) { Text("\($0) мин").tag($0) }
                }
                .labelsHidden().frame(width: 90)
                Text("(изменения на Маке отправляются сразу)").font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            HStack {
                Button("Включить «Ссылка Яндекс Диска» в меню Finder") {
                    ServiceSetup.enableWithGuide()
                }
                Text("правый клик → Службы").font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            if #available(macOS 13.0, *) {
                Toggle("Запускать при входе в систему", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        if on { try? SMAppService.mainApp.register() }
                        else { try? SMAppService.mainApp.unregister() }
                    }
            }

            HStack {
                Spacer()
                Button("Закрыть") { onClose() }
                Button("Сохранить и синхронизировать") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 580)
        .onAppear {
            if #available(macOS 13.0, *) { launchAtLogin = (SMAppService.mainApp.status == .enabled) }
            if loggedIn { model.load(model.root) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tokenChanged)) { _ in
            let nowIn = Settings.shared.token != nil
            loggedIn = nowIn
            guard nowIn else { return }
            model.reload()
            // После подключения сразу открываем окно выбора папок
            if !Settings.shared.selectionConfirmed && model.selected.isEmpty {
                PickerWindowController.shared.show(model: model)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.message = "Выберите (или создайте) папку, в которую будут скачиваться файлы с Диска"
        if panel.runModal() == .OK, let url = panel.url { localFolder = url.path }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    private func save() {
        let home = NSHomeDirectory()
        if localFolder.isEmpty {
            alert("Выберите папку на Маке", "Укажите папку, в которую будут скачиваться файлы.")
            return
        }
        if localFolder == "/" || localFolder == home {
            alert("Выберите отдельную папку",
                  "Нельзя синхронизировать с корнем диска или всей домашней папкой — создайте для этого свою папку, например «Яндекс Диск».")
            return
        }
        let t = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { Settings.shared.token = t; manualToken = "" }
        if Settings.shared.token == nil {
            alert("Аккаунт не подключён", "Вставьте токен и нажмите «Подключить».")
            return
        }
        if model.selected.isEmpty {
            alert("Выберите, что синхронизировать", "Откройте «Выбрать папки Диска…» и отметьте корень или нужные папки.")
            return
        }
        Settings.shared.clientID = clientID
        Settings.shared.localFolder = localFolder
        Settings.shared.selectedFolders = model.result
        Settings.shared.excludedFolders = model.excludedResult
        Settings.shared.selectionConfirmed = true
        Settings.shared.intervalMinutes = interval
        onApply()
        onClose()
    }
}

final class SettingsWindowController {
    private var window: NSWindow?

    func show(onApply: @escaping () -> Void) {
        window?.close()
        let view = SettingsView(onApply: onApply, onClose: { [weak self] in self?.window?.close() })
        let host = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Синхронизация Яндекс Диска"
        w.contentView = host
        w.setContentSize(host.fittingSize)
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

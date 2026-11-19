import SwiftUI
import Cocoa

struct ActivityView: View {
    @ObservedObject var log = ActivityLog.shared
    var onSyncNow: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header.padding(16)
            Divider()
            if log.events.isEmpty {
                Spacer()
                Text("Событий пока нет. Здесь появится всё, что скачивается, загружается и удаляется.")
                    .foregroundColor(.secondary).multilineTextAlignment(.center).padding(30)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(log.events) { TimelineRow(event: $0) }
                    }
                    .padding(.vertical, 12).padding(.horizontal, 16)
                }
            }
            Divider()
            HStack {
                Button("Очистить журнал") { log.clear() }
                Spacer()
                Button("Синхронизировать сейчас") { onSyncNow() }.disabled(log.isSyncing)
            }
            .padding(10)
        }
        .frame(minWidth: 480, minHeight: 440)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: log.isSyncing ? "arrow.triangle.2.circlepath"
                  : (log.hasError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"))
                .font(.system(size: 30))
                .foregroundColor(log.isSyncing ? .blue : (log.hasError ? .orange : .green))
            VStack(alignment: .leading, spacing: 6) {
                Text(log.headline).font(.headline)
                if log.isSyncing {
                    if let p = log.progress {
                        ProgressView(value: p)
                    } else {
                        ProgressView().progressViewStyle(LinearProgressViewStyle())
                    }
                    Text(log.step).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    if !log.speed.isEmpty {
                        Text(log.speed).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                } else {
                    if !log.step.isEmpty {
                        Text(log.step).font(.caption).foregroundColor(.secondary).lineLimit(2)
                    }
                    if let d = log.lastCheck {
                        Text("Последняя проверка: \(Self.timeFormat.string(from: d))")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
        }
    }

    static let timeFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
}

struct TimelineRow: View {
    let event: SyncEvent

    private var symbol: String {
        switch event.kind {
        case .download: return "arrow.down"
        case .upload: return "arrow.up"
        case .delete: return "trash"
        case .conflict: return "exclamationmark.2"
        case .folder: return "folder"
        case .info: return "info"
        case .error: return "exclamationmark"
        case .done: return "checkmark"
        }
    }

    private var color: Color {
        switch event.kind {
        case .download: return .blue
        case .upload: return .green
        case .delete: return .gray
        case .conflict: return .orange
        case .folder: return Color(red: 0.2, green: 0.6, blue: 0.7)
        case .info: return .secondary
        case .error: return .red
        case .done: return .green
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(ActivityView.timeFormat.string(from: event.date))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 62, alignment: .trailing)
                .padding(.top, 2)
            ZStack(alignment: .top) {
                Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 2).frame(maxHeight: .infinity)
                ZStack {
                    Circle().fill(color)
                    Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                }
                .frame(width: 20, height: 20)
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: 12, weight: .medium))
                if !event.detail.isEmpty {
                    Text(event.detail).font(.system(size: 11)).foregroundColor(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                }
            }
            .padding(.bottom, 12)
            Spacer(minLength: 0)
        }
    }
}

final class ActivityWindowController {
    private var window: NSWindow?

    func show(onSyncNow: @escaping () -> Void) {
        if let w = window, w.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingView(rootView: ActivityView(onSyncNow: onSyncNow))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Журнал синхронизации"
        w.contentView = host
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

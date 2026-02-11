import Foundation
import OSLog

enum AppLogLevel: String, CaseIterable, Codable {
    case debug
    case info
    case warn
    case error
}

struct AppLogEntry: Identifiable, Hashable, Codable {
    let id: UUID
    let timestamp: Date
    let level: AppLogLevel
    let category: String
    let message: String
}

extension Notification.Name {
    static let climateAppLog = Notification.Name("climate.app.log")
}

enum AppLog {
    private static let logger = Logger(subsystem: "ai.umate.climate.ios", category: "app")

    static func debug(_ message: String, category: String = "app") {
        post(level: .debug, category: category, message: message)
    }

    static func info(_ message: String, category: String = "app") {
        post(level: .info, category: category, message: message)
    }

    static func warn(_ message: String, category: String = "app") {
        post(level: .warn, category: category, message: message)
    }

    static func error(_ message: String, category: String = "app") {
        post(level: .error, category: category, message: message)
    }

    static func post(level: AppLogLevel, category: String, message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return
        }

        switch level {
        case .debug:
            logger.debug("[\(category)] \(trimmed, privacy: .public)")
        case .info:
            logger.info("[\(category)] \(trimmed, privacy: .public)")
        case .warn:
            logger.warning("[\(category)] \(trimmed, privacy: .public)")
        case .error:
            logger.error("[\(category)] \(trimmed, privacy: .public)")
        }

        NotificationCenter.default.post(
            name: .climateAppLog,
            object: nil,
            userInfo: [
                "timestamp": Date(),
                "level": level.rawValue,
                "category": category,
                "message": trimmed,
            ]
        )
    }
}

@MainActor
final class AppLogStore: ObservableObject {
    @Published private(set) var entries: [AppLogEntry] = []
    @Published private(set) var exportedText: String = ""

    var maxEntries: Int = 1500

    private var observer: NSObjectProtocol?
    private var pending: [AppLogEntry] = []
    private var flushTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .climateAppLog,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }

            let timestamp = note.userInfo?["timestamp"] as? Date ?? Date()
            let levelRaw = note.userInfo?["level"] as? String ?? AppLogLevel.info.rawValue
            let level = AppLogLevel(rawValue: levelRaw) ?? .info
            let category = note.userInfo?["category"] as? String ?? "app"
            let message = note.userInfo?["message"] as? String ?? "<missing>"

            let entry = AppLogEntry(
                id: UUID(),
                timestamp: timestamp,
                level: level,
                category: category,
                message: message
            )
            Task { @MainActor [weak self] in
                self?.enqueue(entry)
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        exportTask?.cancel()
    }

    func clear() {
        entries.removeAll()
        pending.removeAll()
        flushTask?.cancel()
        flushTask = nil

        exportTask?.cancel()
        exportTask = nil
        exportedText = ""
    }

    func exportText() -> String {
        exportedText
    }

    func exportTextNow() -> String {
        Self.exportText(entries: entries)
    }

    nonisolated static func exportText(entries: [AppLogEntry]) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        return entries
            .map { entry in
                "\(df.string(from: entry.timestamp)) [\(entry.level.rawValue.uppercased())] [\(entry.category)] \(entry.message)"
            }
            .joined(separator: "\n")
    }

    private func enqueue(_ entry: AppLogEntry) {
        pending.append(entry)
        if flushTask != nil { return }

        flushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 120 * NSEC_PER_MSEC)
            self.flushPending()
        }
    }

    private func flushPending() {
        flushTask = nil
        guard !pending.isEmpty else { return }

        entries.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
        if maxEntries > 0, entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        scheduleExportRebuild(entriesSnapshot: entries)
    }

    private func scheduleExportRebuild(entriesSnapshot: [AppLogEntry]) {
        exportTask?.cancel()
        exportTask = Task.detached(priority: .utility) { [weak self] in
            let text = Self.exportText(entries: entriesSnapshot)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                self?.exportedText = text
            }
        }
    }
}

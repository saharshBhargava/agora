import Foundation

/// Only lifecycle metadata is durable. Page contents, prompts and credentials are never journaled.
@MainActor
final class TaskRepository {
    struct Event: Codable { let time: Date; let task: UUID; let operation: String; let phase: String }
    private let file: URL
    private var events: [Event] = []
    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Agora", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("task-events.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Event].self, from: data) { events = saved }
    }
    var needsRecovery: Bool {
        guard let last = events.last else { return false }
        return !events.contains { $0.task == last.task && $0.operation == "task" && ["complete", "failed", "stopped"].contains($0.phase) }
    }
    func record(task: UUID, operation: String, phase: String) throws {
        events.append(Event(time: Date(), task: task, operation: operation, phase: phase))
        events = Array(events.suffix(200))
        do {
            try JSONEncoder().encode(events).write(to: file, options: [.atomic, .completeFileProtection])
        } catch {
            AppLog.failure(.storage, "journal.write_failed", error: error)
            throw error
        }
    }
}

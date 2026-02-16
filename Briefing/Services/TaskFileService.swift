import Foundation

// Errors specific to task file operations
enum TaskFileError: Error, LocalizedError {
    case directoryNotFound(String)
    case fileNotFound(String)
    case readError(String)
    case writeError(String)

    var errorDescription: String? {
        switch self {
        case .directoryNotFound(let path): return "Task directory not found: \(path)"
        case .fileNotFound(let path): return "File not found: \(path)"
        case .readError(let msg): return "Read error: \(msg)"
        case .writeError(let msg): return "Write error: \(msg)"
        }
    }
}

// Reads and writes todo.md and todo-log.md from the configurable
// iCloud Drive directory. Uses NSFileCoordinator for iCloud safety —
// avoids reading a partially-synced file.
actor TaskFileService {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Directory Access

    /// The configured task directory URL, validated to exist.
    private func taskDirectoryURL() throws -> URL {
        let path = settings.taskDirectoryPath
        let url = URL(fileURLWithPath: path)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw TaskFileError.directoryNotFound(path)
        }
        return url
    }

    // MARK: - todo.md

    /// Read and parse todo.md into a TodoDocument.
    func readTodoFile() throws -> TodoDocument {
        let dir = try taskDirectoryURL()
        let fileURL = dir.appendingPathComponent("todo.md")
        let content = try readFileCoordinated(at: fileURL)
        return MarkdownParser.parse(content)
    }

    /// Write a TodoDocument back to todo.md.
    func writeTodoFile(_ document: TodoDocument) throws {
        let dir = try taskDirectoryURL()
        let fileURL = dir.appendingPathComponent("todo.md")
        let content = MarkdownWriter.write(document)
        try writeFileCoordinated(content, to: fileURL)
    }

    // MARK: - todo-log.md

    /// Read the last N lines of todo-log.md for context.
    func readLogTail(lines lineCount: Int = 50) throws -> String {
        let dir = try taskDirectoryURL()
        let fileURL = dir.appendingPathComponent("todo-log.md")

        // If the log doesn't exist yet, that's fine — return empty
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ""
        }

        let content = try readFileCoordinated(at: fileURL)
        let allLines = content.components(separatedBy: "\n")

        if allLines.count <= lineCount {
            return content
        }

        let tail = allLines.suffix(lineCount)
        return tail.joined(separator: "\n")
    }

    /// Append a dated entry to todo-log.md.
    func appendToLog(_ entry: String) throws {
        let dir = try taskDirectoryURL()
        let fileURL = dir.appendingPathComponent("todo-log.md")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd h:mm a zzz"
        let timestamp = formatter.string(from: Date())

        let logEntry = "\n---\n\n### \(timestamp)\n\n\(entry)\n"

        // Read existing content (or start fresh) and append
        var existing = ""
        if FileManager.default.fileExists(atPath: fileURL.path) {
            existing = try readFileCoordinated(at: fileURL)
        }

        let updated = existing + logEntry
        try writeFileCoordinated(updated, to: fileURL)
    }

    // MARK: - File I/O with Coordination

    /// Read a file using NSFileCoordinator for iCloud Drive safety.
    /// This ensures we don't read a half-synced file.
    private func readFileCoordinated(at url: URL) throws -> String {
        var coordinatorError: NSError?
        var readResult: Result<String, Error>?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { coordinatedURL in
            do {
                let data = try Data(contentsOf: coordinatedURL)
                guard let content = String(data: data, encoding: .utf8) else {
                    readResult = .failure(TaskFileError.readError("File is not valid UTF-8"))
                    return
                }
                readResult = .success(content)
            } catch {
                readResult = .failure(error)
            }
        }

        if let coordError = coordinatorError {
            throw TaskFileError.readError(coordError.localizedDescription)
        }

        switch readResult {
        case .success(let content):
            return content
        case .failure(let error):
            throw error
        case .none:
            throw TaskFileError.readError("Coordinator returned without calling handler")
        }
    }

    /// Write a file using NSFileCoordinator for iCloud Drive safety.
    private func writeFileCoordinated(_ content: String, to url: URL) throws {
        var coordinatorError: NSError?
        var writeError: Error?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { coordinatedURL in
            do {
                guard let data = content.data(using: .utf8) else {
                    writeError = TaskFileError.writeError("Failed to encode content as UTF-8")
                    return
                }
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                writeError = error
            }
        }

        if let coordError = coordinatorError {
            throw TaskFileError.writeError(coordError.localizedDescription)
        }
        if let error = writeError {
            throw error
        }
    }
}

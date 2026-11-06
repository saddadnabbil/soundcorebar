import Foundation

/// Appends timestamped lines to ~/Library/Logs/SoundcoreBar.log (also mirrored to stderr).
/// The file is kept open, and rotated to SoundcoreBar.log.1 once it passes 1 MB.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SoundcoreBar.log")
    private static let maxBytes: UInt64 = 1_000_000
    private static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static var handle: FileHandle?

    static func write(_ msg: String) {
        let data = Data("\(fmt.string(from: Date())) \(msg)\n".utf8)
        FileHandle.standardError.write(data)
        guard let h = openHandle() else { return }
        h.write(data)
        if h.offsetInFile > maxBytes { rotate() }
    }

    private static func openHandle() -> FileHandle? {
        if let h = handle { return h }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        return handle
    }

    private static func rotate() {
        try? handle?.close()
        handle = nil
        let old = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
}

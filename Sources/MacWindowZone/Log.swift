import Foundation

/// File-backed log. Survives across launches, viewable from the menu or
/// directly from `~/Library/Application Support/MacWindowZone/debug.log`.
/// We mirror to NSLog so messages also show up in Console.app.
enum Log {
    static let url: URL = Persistence.supportDirectory.appendingPathComponent("debug.log")

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let queue = DispatchQueue(label: "MWZ.log")

    static func line(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        NSLog("[MWZ] \(message)")
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                    return
                }
            }
            try? data.write(to: url, options: .atomic)
        }
    }

    static func reset() {
        queue.sync {
            try? "".data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }
}

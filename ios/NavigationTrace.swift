import Foundation

/// Append-only session trace for diagnosing guidance against the capture that
/// produced it.
///
/// The mapping walk and the guidance walk over the same aisle land in one
/// file, in the same coordinate frame, so what the navigator *believed* can be
/// read line for line against what was actually *recorded*. Every spoken cue
/// carries the function that emitted it plus the full navigator state at that
/// instant, which is what separates "the route graph is wrong" from "the route
/// graph is right and something downstream overrode it".
///
/// Written as JSONL — one object per line, cheap to append at 50 Hz and
/// trivial to parse afterwards.
final class NavigationTrace {
    static let shared = NavigationTrace()

    /// Keep the trace small enough to AirDrop out of a store aisle. Ticks stop
    /// once this is passed; decisions and cues keep recording, because losing
    /// those is losing the whole point of the file.
    private let softLimitBytes = 8 * 1024 * 1024
    private let hardLimitBytes = 24 * 1024 * 1024
    private let keepPreviousSessions = 8

    private let queue = DispatchQueue(label: "shelfscout.navigation-trace", qos: .utility)
    private let launchedAt = Date()
    private var handle: FileHandle?
    private var fileURL: URL?
    private var pending = Data()
    private var bytesWritten = 0
    private var droppedTicks = 0
    private var flushScheduled = false

    private init() {}

    // MARK: - Writing

    /// `fields` values must be JSON-representable scalars, arrays or
    /// dictionaries; anything else is stringified rather than dropped, so a
    /// bad field can never cost us the event.
    func log(_ event: String, _ fields: [String: Any] = [:]) {
        let elapsed = Date().timeIntervalSince(launchedAt)
        queue.async { [weak self] in
            self?.write(event: event, fields: fields, elapsed: elapsed, isTick: false)
        }
    }

    /// High-rate state samples. Dropped once the soft limit is reached so the
    /// decision record survives a very long session.
    func tick(_ event: String, _ fields: [String: Any] = [:]) {
        let elapsed = Date().timeIntervalSince(launchedAt)
        queue.async { [weak self] in
            self?.write(event: event, fields: fields, elapsed: elapsed, isTick: true)
        }
    }

    private func write(event: String, fields: [String: Any], elapsed: TimeInterval, isTick: Bool) {
        guard bytesWritten < hardLimitBytes else { return }
        if isTick, bytesWritten >= softLimitBytes {
            droppedTicks += 1
            return
        }
        ensureFileOpen()

        var payload: [String: Any] = ["t": (elapsed * 1000).rounded() / 1000, "e": event]
        for (key, value) in fields {
            payload[key] = Self.jsonSafe(value)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        pending.append(data)
        pending.append(0x0A)
        bytesWritten += data.count + 1

        // Batch the 50 Hz traffic instead of hitting the filesystem per line,
        // but never leave the tail unflushed for long: a session that ends by
        // the app being killed still has to hand over what it saw.
        if pending.count >= 32 * 1024 {
            flush()
        } else if !flushScheduled {
            flushScheduled = true
            queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.flushScheduled = false
                self?.flush()
            }
        }
    }

    private func flush() {
        guard !pending.isEmpty, let handle else { return }
        try? handle.write(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
    }

    private func ensureFileOpen() {
        guard handle == nil else { return }
        let directory = Self.logDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("session-\(formatter.string(from: launchedAt)).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        fileURL = url

        let header: [String: Any] = [
            "t": 0,
            "e": "session.open",
            "startedAt": ISO8601DateFormatter().string(from: launchedAt),
            "device": Self.deviceDescription()
        ]
        if let data = try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]) {
            pending.append(data)
            pending.append(0x0A)
        }
        pruneOldSessions(in: directory, keeping: url)
    }

    private func pruneOldSessions(in directory: URL, keeping current: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let sessions = files
            .filter { $0.pathExtension == "jsonl" && $0 != current }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
        for stale in sessions.dropFirst(keepPreviousSessions) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    // MARK: - Export

    /// Concatenates every retained session, newest last, into one shareable
    /// file. Mapping and guidance are usually separate app runs, so exporting
    /// only the live session would hand over half the story.
    func exportURL() -> URL? {
        queue.sync { flush() }
        let directory = Self.logDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        let sessions = files
            .filter { $0.pathExtension == "jsonl" }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left < right
            }
        guard !sessions.isEmpty else { return nil }

        var combined = Data()
        for session in sessions {
            guard let data = try? Data(contentsOf: session) else { continue }
            combined.append(data)
        }
        guard !combined.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelfscout-navigation-trace-\(formatter.string(from: Date())).jsonl")
        try? combined.write(to: out, options: [.atomic])
        return out
    }

    var hasRecordedSessions: Bool {
        if queue.sync(execute: { bytesWritten > 0 }) { return true }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.logDirectory(),
            includingPropertiesForKeys: nil
        )) ?? []
        return files.contains { $0.pathExtension == "jsonl" }
    }

    var sessionSummary: String {
        queue.sync {
            let kilobytes = bytesWritten / 1024
            let name = fileURL?.lastPathComponent ?? "not started"
            return "\(name) · \(kilobytes) KB\(droppedTicks > 0 ? " · \(droppedTicks) ticks dropped" : "")"
        }
    }

    // MARK: - Helpers

    private static func logDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("navigation-traces", isDirectory: true)
    }

    private static func deviceDescription() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine
    }

    private static func jsonSafe(_ value: Any) -> Any {
        // A nil optional boxed into `Any` would otherwise stringify as "nil",
        // and an explicit NSNull as the literal "<null>". Both must reach the
        // file as JSON null or every reader has to special-case them.
        if case Optional<Any>.none = value { return NSNull() }
        if value is NSNull { return NSNull() }
        switch value {
        case let number as Double:
            guard number.isFinite else { return String(describing: number) }
            return (number * 1000).rounded() / 1000
        case let number as Float:
            return jsonSafe(Double(number))
        case is Int, is Bool, is String:
            return value
        case let array as [Any]:
            return array.map { jsonSafe($0) }
        case let dictionary as [String: Any]:
            return dictionary.mapValues { jsonSafe($0) }
        default:
            return String(describing: value)
        }
    }
}

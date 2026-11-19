import Foundation

/// One parsed SSE frame: the `event:` name (nil when the frame carries
/// only data, the OpenAI-compatible spelling), the joined `data:`
/// lines and the lines themselves — a frame whose first data line is
/// mangled can still yield a decodable later line.
struct SSEFrame: Equatable, Sendable {
    var event: String?
    var data: String
    var dataLines: [String]
}

/// Incremental server-sent-events splitter (SPEC §5.15 F-AI-1). Feed raw
/// text as it arrives; a frame dispatches on the first empty line —
/// `AsyncBytes.lines` yields "" for the separators. Malformed lines
/// (bad prefixes, garbage bytes) are skipped, never fatal: a truncated
/// or mangled line must not lose the rest of the stream. The final
/// unterminated frame is flushed by `finish()` when the transport ends.
struct SSEStreamParser {
    private var pendingEvent: String?
    private var pendingData: [String] = []
    private var sawData = false

    /// Feeds one complete line (as `AsyncBytes.lines` yields them) and
    /// returns the frame it dispatched, if any.
    mutating func feed(line: String) -> SSEFrame? {
        if line.isEmpty {
            return flush()
        }
        if line.hasPrefix("event:") {
            pendingEvent = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            // One leading space after the colon is legal SSE.
            var payload = String(line.dropFirst("data:".count))
            if payload.hasPrefix(" ") {
                payload.removeFirst()
            }
            pendingData.append(payload)
            sawData = true
        }
        // `id:`, `retry:`, comments (:) and anything else: ignored.
        return nil
    }

    /// Dispatches the buffered frame; call at end of stream.
    mutating func finish() -> SSEFrame? {
        guard sawData else {
            pendingEvent = nil
            return nil
        }
        return flush()
    }

    private mutating func flush() -> SSEFrame? {
        defer {
            pendingEvent = nil
            pendingData = []
            sawData = false
        }
        guard sawData else {
            return nil
        }
        return SSEFrame(event: pendingEvent, data: pendingData.joined(separator: "\n"), dataLines: pendingData)
    }
}

/// Reassembles SSE `data:` JSON payloads into typed events.
enum SSEJSON {
    /// Decodes a frame's data as `T`, defensively: a payload that is not
    /// valid JSON for `T` yields nil instead of throwing — providers
    /// keep streaming past malformed frames. A multi-line frame tries
    /// every line, so one mangled line never poisons the rest.
    static func decode<T: Decodable>(_ type: T.Type, from frame: SSEFrame) -> T? {
        for candidate in frame.dataLines {
            if let raw = candidate.data(using: .utf8),
                let decoded = try? JSONDecoder().decode(T.self, from: raw)
            {
                return decoded
            }
        }
        return nil
    }
}

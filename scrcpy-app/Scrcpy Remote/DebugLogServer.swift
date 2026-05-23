//
//  DebugLogServer.swift
//  Scrcpy Remote
//
//  DEBUG-only HTTP endpoint on port 4321 that exposes the running app's
//  stdout / stderr line stream for live debugging from a host machine
//  (browser, curl, scripted poller).
//
//  Design goals:
//    - Capture without disturbing the existing AppLogManager file
//      pipeline: we splice into stdout / stderr via pipe(2) + dup2(),
//      tee bytes back to the original fds, and into an in-memory ring
//      buffer keyed by monotonic line number.
//    - Self-describing root endpoint so future endpoints can be added
//      without breaking callers (progressive disclosure).
//    - Single TCP listener via Network.framework; no third-party deps.
//
//  Created 2026-05 for the v4.0 upgrade touch-event debugging.
//

#if DEBUG

import Foundation
import Network

private let kDebugLogServerPort: NWEndpoint.Port = 4321
private let kDebugLogRingCapacity = 5000   // lines
private let kDebugLogMaxLineBytes = 8192   // truncate longer lines

/// One captured log line with its monotonic sequence number and capture
/// timestamp (ms since 1970).
struct DebugLogLine: Codable {
    let seq: UInt64       // monotonic, never resets
    let ts: UInt64        // ms since 1970 (UTC)
    let stream: String    // "stdout" | "stderr"
    let line: String
}

final class DebugLogServer {
    static let shared = DebugLogServer()

    private let queue = DispatchQueue(label: "scrcpy.debuglog.server")
    private let ringQueue = DispatchQueue(label: "scrcpy.debuglog.ring",
                                          attributes: .concurrent)

    // Ring buffer of captured lines.
    private var ring: [DebugLogLine] = []
    private var nextSeq: UInt64 = 0

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]

    // Splicing state.
    private var stdoutTeeFd: Int32 = -1
    private var stderrTeeFd: Int32 = -1
    private var stdoutReadSrc: DispatchSourceRead?
    private var stderrReadSrc: DispatchSourceRead?

    private init() {}

    /// Heap-allocated holder for the per-stream pending byte buffer so an
    /// @escaping dispatch event handler can mutate it across firings.
    private final class DataBox {
        var data = Data()
    }

    /// Start capture + HTTP listener. Idempotent.
    func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard self.listener == nil else { return }
            self.installStdoutCapture()
            self.startHTTPListener()
        }
    }

    // MARK: - stdout / stderr splicing

    private func installStdoutCapture() {
        if let s = installSplice(forFd: STDOUT_FILENO, streamLabel: "stdout") {
            self.stdoutTeeFd = s.teeFd
            self.stdoutReadSrc = s.src
        }
        if let s = installSplice(forFd: STDERR_FILENO, streamLabel: "stderr") {
            self.stderrTeeFd = s.teeFd
            self.stderrReadSrc = s.src
        }
    }

    private struct SpliceHandles {
        let teeFd: Int32
        let src: DispatchSourceRead
    }

    /// Replace `targetFd` with a pipe writer. A reader thread drains the
    /// pipe, splits on \n, appends to ring, and forwards bytes verbatim
    /// to the original fd (saved via dup) so the existing
    /// AppLogManager-style file redirection still sees them.
    private func installSplice(forFd targetFd: Int32,
                               streamLabel: String) -> SpliceHandles?
    {
        // Dup the original fd so we can tee bytes back to it after
        // capturing them.
        let originalFd = dup(targetFd)
        if originalFd < 0 {
            return nil
        }

        // Create a pipe; writes to targetFd now flow into pipefd[0].
        var pipefd: [Int32] = [-1, -1]
        if pipe(&pipefd) != 0 {
            close(originalFd)
            return nil
        }
        // Redirect targetFd to the pipe's write end.
        if dup2(pipefd[1], targetFd) < 0 {
            close(pipefd[0]); close(pipefd[1]); close(originalFd)
            return nil
        }
        close(pipefd[1])

        let readFd = pipefd[0]

        // Non-blocking on the read side.
        let flags = fcntl(readFd, F_GETFL, 0)
        _ = fcntl(readFd, F_SETFL, flags | O_NONBLOCK)

        let src = DispatchSource.makeReadSource(fileDescriptor: readFd, queue: queue)

        // Pending buffer per stream lives in a class-scoped box so the
        // closure can mutate it across event firings without capturing
        // a non-escaping parameter.
        let pendingBox = DataBox()
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                    return read(readFd, ptr.baseAddress, ptr.count)
                }
                if n <= 0 { break }
                let chunk = Data(bytes: buf, count: n)
                // Tee to the original fd so file logging still works.
                chunk.withUnsafeBytes { raw in
                    var remaining = n
                    var base = raw.baseAddress!
                    while remaining > 0 {
                        let w = write(originalFd, base, remaining)
                        if w <= 0 { break }
                        remaining -= w
                        base = base.advanced(by: w)
                    }
                }
                pendingBox.data.append(chunk)
                self.flushLines(from: &pendingBox.data, stream: streamLabel)
            }
        }
        src.setCancelHandler {
            close(readFd)
            close(originalFd)
        }
        src.resume()
        return SpliceHandles(teeFd: originalFd, src: src)
    }

    private func flushLines(from buf: inout Data, stream: String) {
        while let nlIdx = buf.firstIndex(of: 0x0A /* \n */) {
            let lineBytes = buf.prefix(upTo: nlIdx)
            let truncated = lineBytes.count > kDebugLogMaxLineBytes
                ? lineBytes.prefix(kDebugLogMaxLineBytes)
                : lineBytes
            let line = String(decoding: truncated, as: UTF8.self)
            appendLine(line, stream: stream)
            buf.removeSubrange(buf.startIndex...nlIdx)
        }
    }

    private func appendLine(_ line: String, stream: String) {
        ringQueue.async(flags: .barrier) {
            let entry = DebugLogLine(
                seq: self.nextSeq,
                ts: UInt64(Date().timeIntervalSince1970 * 1000),
                stream: stream,
                line: line)
            self.nextSeq &+= 1
            self.ring.append(entry)
            if self.ring.count > kDebugLogRingCapacity {
                self.ring.removeFirst(self.ring.count - kDebugLogRingCapacity)
            }
        }
    }

    // MARK: - HTTP listener

    private func startHTTPListener() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let lst = try NWListener(using: params, on: kDebugLogServerPort)
            lst.newConnectionHandler = { [weak self] conn in
                self?.handle(connection: conn)
            }
            lst.start(queue: queue)
            self.listener = lst
            // Tee directly to original stdout so this message survives our
            // own splice (write to teeFd, not stdout, to avoid recursion).
            let msg = "🛰️ DebugLogServer listening on http://0.0.0.0:4321/\n"
            if let data = msg.data(using: .utf8) {
                data.withUnsafeBytes { raw in
                    _ = write(self.stdoutTeeFd >= 0 ? self.stdoutTeeFd : STDERR_FILENO,
                              raw.baseAddress, raw.count)
                }
            }
        } catch {
            // Fail silently — DEBUG-only convenience.
        }
    }

    private func handle(connection conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        clients[id] = conn
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            defer { self?.clients.removeValue(forKey: id) }
            guard let self = self, let data = data, !data.isEmpty, error == nil else {
                conn.cancel(); return
            }
            self.respond(to: data, on: conn)
        }
    }

    private func respond(to requestData: Data, on conn: NWConnection) {
        guard let req = String(data: requestData, encoding: .utf8),
              let firstLine = req.split(separator: "\r\n").first else {
            sendError(conn, status: 400, message: "Bad Request"); return
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendError(conn, status: 400, message: "Bad Request"); return
        }
        let target = String(parts[1])

        let (path, query) = splitPathQuery(target)

        switch path {
        case "/":
            sendIndex(conn)
        case "/v1/logs/info":
            sendInfo(conn)
        case "/v1/logs/tail":
            sendTail(conn, query: query)
        case "/v1/logs/since":
            sendSince(conn, query: query)
        case "/v1/logs/page":
            sendPage(conn, query: query)
        default:
            sendError(conn, status: 404, message: "Not Found: \(path)")
        }
    }

    // MARK: - endpoint handlers

    private func sendIndex(_ conn: NWConnection) {
        let body: [String: Any] = [
            "service": "scrcpy-mobile DebugLogServer",
            "version": "v1",
            "build": "DEBUG",
            "port": 4321,
            "endpoints": [
                [
                    "method": "GET",
                    "path": "/",
                    "desc": "This index. Self-describing list of endpoints."
                ],
                [
                    "method": "GET",
                    "path": "/v1/logs/info",
                    "desc": "Buffer capacity, current line count, earliest/latest seq+ts.",
                    "params": [:]
                ],
                [
                    "method": "GET",
                    "path": "/v1/logs/tail",
                    "desc": "Most recent N captured lines (oldest first in result).",
                    "params": [
                        "n": "int, default 200, max = ring capacity"
                    ]
                ],
                [
                    "method": "GET",
                    "path": "/v1/logs/since",
                    "desc": "Lines captured at or after a given monotonic seq OR ms-epoch timestamp.",
                    "params": [
                        "seq": "uint64, return lines where seq >= value",
                        "t":   "uint64 ms-since-epoch, return lines where ts >= value",
                        "limit": "int, default 1000, max = ring capacity",
                        "note": "exactly one of seq / t is required"
                    ]
                ],
                [
                    "method": "GET",
                    "path": "/v1/logs/page",
                    "desc": "Page through the ring. offset is a seq number; next_offset is returned for the following page.",
                    "params": [
                        "offset": "uint64 seq, default = earliest available",
                        "limit":  "int, default 500, max = ring capacity"
                    ]
                ]
            ],
            "response_format": [
                "tail": "{ count: int, lines: [DebugLogLine] }",
                "since": "{ count: int, lines: [DebugLogLine] }",
                "page": "{ count: int, lines: [DebugLogLine], next_offset: uint64|null }",
                "DebugLogLine": "{ seq: uint64, ts: uint64 (ms epoch), stream: 'stdout'|'stderr', line: string }"
            ]
        ]
        sendJSON(conn, status: 200, object: body)
    }

    private func sendInfo(_ conn: NWConnection) {
        ringQueue.sync {
            let info: [String: Any] = [
                "capacity": kDebugLogRingCapacity,
                "count": ring.count,
                "next_seq": nextSeq,
                "earliest_seq": ring.first?.seq ?? NSNull(),
                "earliest_ts": ring.first?.ts ?? NSNull(),
                "latest_seq": ring.last?.seq ?? NSNull(),
                "latest_ts": ring.last?.ts ?? NSNull()
            ]
            sendJSON(conn, status: 200, object: info)
        }
    }

    private func sendTail(_ conn: NWConnection, query: [String: String]) {
        let n = clampLimit(query["n"], defaultValue: 200)
        ringQueue.sync {
            let slice = Array(ring.suffix(n))
            sendJSONLines(conn, lines: slice)
        }
    }

    private func sendSince(_ conn: NWConnection, query: [String: String]) {
        let limit = clampLimit(query["limit"], defaultValue: 1000)
        let predicate: (DebugLogLine) -> Bool
        if let s = query["seq"], let seq = UInt64(s) {
            predicate = { $0.seq >= seq }
        } else if let s = query["t"], let ts = UInt64(s) {
            predicate = { $0.ts >= ts }
        } else {
            sendError(conn, status: 400, message: "missing 'seq' or 't'"); return
        }
        ringQueue.sync {
            let filtered = ring.filter(predicate).prefix(limit)
            sendJSONLines(conn, lines: Array(filtered))
        }
    }

    private func sendPage(_ conn: NWConnection, query: [String: String]) {
        let limit = clampLimit(query["limit"], defaultValue: 500)
        ringQueue.sync {
            let offset = UInt64(query["offset"] ?? "") ?? (ring.first?.seq ?? 0)
            let slice = ring.drop(while: { $0.seq < offset }).prefix(limit)
            let arr = Array(slice)
            let nextOffset: Any = (arr.count == limit && arr.last != nil)
                ? (arr.last!.seq &+ 1) as Any
                : NSNull()
            let body: [String: Any] = [
                "count": arr.count,
                "next_offset": nextOffset,
                "lines": arr.map(serializeLine)
            ]
            sendJSON(conn, status: 200, object: body)
        }
    }

    // MARK: - helpers

    private func clampLimit(_ raw: String?, defaultValue: Int) -> Int {
        let parsed = raw.flatMap { Int($0) } ?? defaultValue
        return max(1, min(parsed, kDebugLogRingCapacity))
    }

    private func serializeLine(_ l: DebugLogLine) -> [String: Any] {
        [
            "seq": l.seq,
            "ts": l.ts,
            "stream": l.stream,
            "line": l.line
        ]
    }

    private func sendJSONLines(_ conn: NWConnection, lines: [DebugLogLine]) {
        let body: [String: Any] = [
            "count": lines.count,
            "lines": lines.map(serializeLine)
        ]
        sendJSON(conn, status: 200, object: body)
    }

    private func sendJSON(_ conn: NWConnection, status: Int, object: Any) {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys])
        } catch {
            sendError(conn, status: 500, message: "serialize: \(error)"); return
        }
        sendResponse(conn, status: status,
                     contentType: "application/json; charset=utf-8",
                     body: data)
    }

    private func sendError(_ conn: NWConnection, status: Int, message: String) {
        let body = "{\"error\":\(jsonEscape(message))}".data(using: .utf8) ?? Data()
        sendResponse(conn, status: status,
                     contentType: "application/json; charset=utf-8",
                     body: body)
    }

    private func sendResponse(_ conn: NWConnection, status: Int,
                              contentType: String, body: Data) {
        let reason = HTTPStatus.reason(for: status)
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        conn.send(content: payload, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func splitPathQuery(_ target: String) -> (String, [String: String]) {
        guard let q = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[..<q])
        let qs = target[target.index(after: q)...]
        var out: [String: String] = [:]
        for pair in qs.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                out[String(kv[0])] = String(kv[1])
                    .removingPercentEncoding ?? String(kv[1])
            }
        }
        return (path, out)
    }

    private func jsonEscape(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
           let str = String(data: data, encoding: .utf8) {
            // [".."] -> ".."
            let trimmed = str.dropFirst().dropLast()
            return String(trimmed)
        }
        return "\"\""
    }
}

private enum HTTPStatus {
    static func reason(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default:  return "Status"
        }
    }
}

#endif // DEBUG

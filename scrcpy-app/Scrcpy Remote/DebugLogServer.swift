//
//  DebugLogServer.swift
//  Scrcpy Remote
//
//  DEBUG-only HTTP endpoint on port 4321 that exposes the running app's
//  log files for live debugging from a host machine.
//
//  Design v2 (file-backed):
//    - The previous in-memory ring buffer fed by stdout/stderr splicing
//      collided with AppLogManager's freopen()-based file redirection:
//      whichever one ran second won the fd, and the other got nothing.
//      The new design reads straight from AppLogManager's on-disk files,
//      which is what the rest of the app already trusts as the source of
//      truth for runtime logs.
//    - When no file path is specified, the "current" / newest file is
//      used. Endpoints accept a file= query (by name) to target older
//      files.
//    - Self-describing root endpoint so future endpoints can be added
//      without breaking callers.
//
//  Note: DebugLogServer only forces AppLogManager.shared to start
//  logging on app launch (otherwise no file exists to read from).
//

#if DEBUG

import Foundation
import Network

private let kDebugLogServerPort: NWEndpoint.Port = 4321
private let kMaxLines = 50000
private let kMaxByteWindow = 8 * 1024 * 1024  // 8 MB tail window

final class DebugLogServer {
    static let shared = DebugLogServer()

    private let queue = DispatchQueue(label: "scrcpy.debuglog.server")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]

    private init() {}

    /// Start the HTTP listener and ensure file logging is on so there's
    /// something to read.
    func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard self.listener == nil else { return }

            // Force AppLogManager on so log files exist for us to read.
            let mgr = AppLogManager.shared
            if !mgr.isLoggingEnabled {
                DispatchQueue.main.async { mgr.toggleLogging(true) }
            }

            self.startHTTPListener()
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
            NSLog("🛰️ DebugLogServer listening on http://0.0.0.0:4321/")
        } catch {
            NSLog("🛰️ DebugLogServer failed to start: \(error)")
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
        case "/v1/files":
            sendFilesList(conn)
        case "/v1/logs/info":
            sendInfo(conn, query: query)
        case "/v1/logs/tail":
            sendTail(conn, query: query)
        case "/v1/logs/grep":
            sendGrep(conn, query: query)
        case "/v1/logs/raw":
            sendRaw(conn, query: query)
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
            "data_source": "AppLogManager on-disk log files",
            "endpoints": [
                [
                    "method": "GET",
                    "path": "/",
                    "desc": "Self-describing list of endpoints + params."
                ],
                [
                    "method": "GET",
                    "path": "/v1/files",
                    "desc": "List all known log files. Identifies the current one.",
                ],
                [
                    "method": "GET",
                    "path": "/v1/logs/info",
                    "desc": "Stats for a log file: path, size, mtime, line count (approx).",
                    "params": [
                        "file": "string, log file name (e.g. Scrcpy_Remote_4.4.4_2026-05-23.log); defaults to newest"
                    ]
                ],
                [
                    "method": "GET",
                    "path": "/v1/logs/tail",
                    "desc": "Last N lines of a log file.",
                    "params": [
                        "n": "int, default 500, max \(kMaxLines)",
                        "file": "string, log file name; defaults to newest"
                    ]
                ],
                [
                    "method": "GET",
                    "path": "/v1/logs/grep",
                    "desc": "Lines matching a substring in a log file's tail window (last \(kMaxByteWindow/1024/1024) MB).",
                    "params": [
                        "q": "string, substring to match (required)",
                        "n": "int, default 500, max \(kMaxLines)",
                        "case_sensitive": "bool, default false",
                        "file": "string, log file name; defaults to newest"
                    ]
                ],
                [
                    "method": "GET",
                    "path": "/v1/logs/raw",
                    "desc": "Raw text dump of the file's tail window (no line truncation). Streams text/plain.",
                    "params": [
                        "file": "string, log file name; defaults to newest"
                    ]
                ]
            ]
        ]
        sendJSON(conn, status: 200, object: body)
    }

    private func sendFilesList(_ conn: NWConnection) {
        let mgr = AppLogManager.shared
        let files = mgr.getLogFilesList()
        let body: [String: Any] = [
            "logging_enabled": mgr.isLoggingEnabled,
            "current_file": (files.first { $0.isCurrentLog }?.fileName) ?? NSNull(),
            "current_path": mgr.getCurrentLogFilePath(),
            "count": files.count,
            "files": files.map { f -> [String: Any] in
                [
                    "name": f.fileName,
                    "path": f.filePath,
                    "size": f.fileSize,
                    "modified_ms": Int64(f.modificationDate.timeIntervalSince1970 * 1000),
                    "is_current": f.isCurrentLog
                ]
            }
        ]
        sendJSON(conn, status: 200, object: body)
    }

    private func sendInfo(_ conn: NWConnection, query: [String: String]) {
        guard let resolved = resolveFile(query) else {
            sendError(conn, status: 404, message: "No log file available"); return
        }
        // Flush stdio so we get the latest bytes before reading.
        fflush(stdout); fflush(stderr)
        let attrs = (try? FileManager.default.attributesOfItem(atPath: resolved.path)) ?? [:]
        let size = (attrs[.size] as? Int64) ?? 0
        let mtime = (attrs[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        // Line count: only meaningful for the last window — counting all
        // bytes of a 100 MB file would be too expensive.
        let window = readTailWindow(path: resolved.path, maxBytes: kMaxByteWindow)
        let approxLines = window.reduce(into: 0) { acc, b in if b == 0x0A { acc += 1 } }
        let body: [String: Any] = [
            "file": resolved.name,
            "path": resolved.path,
            "size": size,
            "modified_ms": mtime,
            "window_bytes_read": window.count,
            "window_lines_approx": approxLines,
            "tail_window_bytes": kMaxByteWindow
        ]
        sendJSON(conn, status: 200, object: body)
    }

    private func sendTail(_ conn: NWConnection, query: [String: String]) {
        guard let resolved = resolveFile(query) else {
            sendError(conn, status: 404, message: "No log file available"); return
        }
        let n = max(1, min(Int(query["n"] ?? "") ?? 500, kMaxLines))
        fflush(stdout); fflush(stderr)
        let lines = readTailLines(path: resolved.path, n: n)
        let body: [String: Any] = [
            "file": resolved.name,
            "count": lines.count,
            "lines": lines
        ]
        sendJSON(conn, status: 200, object: body)
    }

    private func sendGrep(_ conn: NWConnection, query: [String: String]) {
        guard let q = query["q"], !q.isEmpty else {
            sendError(conn, status: 400, message: "missing 'q'"); return
        }
        guard let resolved = resolveFile(query) else {
            sendError(conn, status: 404, message: "No log file available"); return
        }
        let n = max(1, min(Int(query["n"] ?? "") ?? 500, kMaxLines))
        let caseSensitive = (query["case_sensitive"] ?? "false").lowercased() == "true"
        fflush(stdout); fflush(stderr)
        let needle = caseSensitive ? q : q.lowercased()
        let allLines = readTailLines(path: resolved.path, n: kMaxLines)
        var matches: [String] = []
        for line in allLines {
            let hay = caseSensitive ? line : line.lowercased()
            if hay.contains(needle) {
                matches.append(line)
                if matches.count >= n { break }
            }
        }
        let body: [String: Any] = [
            "file": resolved.name,
            "q": q,
            "case_sensitive": caseSensitive,
            "count": matches.count,
            "lines": matches
        ]
        sendJSON(conn, status: 200, object: body)
    }

    private func sendRaw(_ conn: NWConnection, query: [String: String]) {
        guard let resolved = resolveFile(query) else {
            sendError(conn, status: 404, message: "No log file available"); return
        }
        fflush(stdout); fflush(stderr)
        let window = readTailWindow(path: resolved.path, maxBytes: kMaxByteWindow)
        sendResponse(conn, status: 200,
                     contentType: "text/plain; charset=utf-8",
                     body: window)
    }

    // MARK: - file resolution + reading

    private struct ResolvedFile {
        let name: String
        let path: String
    }

    /// If the caller passed file=NAME, look it up in AppLogManager's list.
    /// Otherwise return the newest file (which is also the current one if
    /// logging is on).
    private func resolveFile(_ query: [String: String]) -> ResolvedFile? {
        let mgr = AppLogManager.shared
        let list = mgr.getLogFilesList()
        if let name = query["file"], !name.isEmpty {
            if let hit = list.first(where: { $0.fileName == name }) {
                return ResolvedFile(name: hit.fileName, path: hit.filePath)
            }
            return nil
        }
        // Default: newest (the list is sorted by modificationDate desc).
        if let newest = list.first {
            return ResolvedFile(name: newest.fileName, path: newest.filePath)
        }
        // Fall back to current-path even if file doesn't exist yet.
        let cur = mgr.getCurrentLogFilePath()
        return ResolvedFile(name: (cur as NSString).lastPathComponent, path: cur)
    }

    /// Read at most `maxBytes` from the tail of `path` and return the
    /// bytes verbatim (UTF-8 boundary safe because we only chop at
    /// LF boundaries below in readTailLines).
    private func readTailWindow(path: String, maxBytes: Int) -> Data {
        guard let handle = FileHandle(forReadingAtPath: path) else { return Data() }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
            try handle.seek(toOffset: start)
            return (try handle.readToEnd()) ?? Data()
        } catch {
            return Data()
        }
    }

    /// Read tail and return last n lines (oldest first in result).
    private func readTailLines(path: String, n: Int) -> [String] {
        let window = readTailWindow(path: path, maxBytes: kMaxByteWindow)
        guard !window.isEmpty else { return [] }
        // Split on LF, drop a possible empty trailing slot.
        let text = String(decoding: window, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last == "" { lines.removeLast() }
        // Drop the first chunk (it may have started mid-line due to the
        // tail-window cut).
        if lines.count > 1 { lines.removeFirst() }
        if lines.count > n {
            lines = Array(lines.suffix(n))
        }
        return lines
    }

    // MARK: - HTTP helpers

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

//
//  DebugHarnessServer.swift
//  Scrcpy Remote
//
//  DEBUG-only JSON-RPC harness on port 6321 for driving the app from a host
//  machine: read logs, dump the view tree, create/modify Sessions and
//  Actions. Replaces the old read-only DebugLogServer on port 4321 — log
//  access now lives here as logs.* methods.
//
//  Protocol (JSON-RPC 2.0 flavored):
//    POST /  {"method":"sessions.create","params":{...},"id":1}
//      → {"id":1,"result":{...}}
//      → {"id":1,"error":{"code":-32602,"message":"...","data":{hint,...}}}
//    GET  /              → service overview: every method + one-line summary
//    GET  /help/<method> → full parameter spec + example for one method
//
//  Progressive disclosure: the root overview only names methods; the full
//  parameter table is revealed per-method (GET /help/<m> or the "help"
//  method), and validation failures return the spec for exactly the
//  offending parameter plus a working example — so a caller can start from
//  zero knowledge and be guided to a correct call.
//

#if DEBUG

import Foundation
import Network
import UIKit

private let kHarnessPort: NWEndpoint.Port = 6321
private let kMaxRequestBytes = 1 * 1024 * 1024      // 1 MB request cap
private let kMaxLogLines = 50000
private let kMaxLogByteWindow = 8 * 1024 * 1024     // 8 MB tail window
private let kMaxViewNodes = 4000

// MARK: - Method registry types

private struct HarnessParam {
    let name: String
    let type: String            // "string" | "int" | "bool" | "uuid"
    let required: Bool
    let desc: String
    var allowed: [String]? = nil
    var defaultValue: String? = nil

    var spec: [String: Any] {
        var d: [String: Any] = ["type": type, "required": required, "desc": desc]
        if let allowed = allowed { d["allowed"] = allowed }
        if let dv = defaultValue { d["default"] = dv }
        return d
    }
}

private struct HarnessMethod {
    let name: String
    let summary: String
    let params: [HarnessParam]
    let example: [String: Any]
    let handler: ([String: Any]) throws -> Any

    /// Level-2 help: the full spec, revealed per-method.
    var helpSpec: [String: Any] {
        var paramSpecs: [String: Any] = [:]
        for p in params { paramSpecs[p.name] = p.spec }
        return [
            "method": name,
            "summary": summary,
            "params": paramSpecs.isEmpty ? "none" : paramSpecs,
            "example": ["method": name, "params": example, "id": 1],
        ]
    }
}

private struct HarnessError: Error {
    let code: Int
    let message: String
    var data: [String: Any]? = nil

    static func invalidParams(_ message: String, method: HarnessMethod?,
                              param: HarnessParam? = nil) -> HarnessError {
        var data: [String: Any] = [:]
        if let p = param {
            data["param"] = p.name
            data["expected"] = p.spec
        }
        if let m = method {
            data["hint"] = "GET /help/\(m.name) for the full parameter spec"
            data["example"] = ["method": m.name, "params": m.example, "id": 1]
        }
        return HarnessError(code: -32602, message: message, data: data)
    }
}

// MARK: - Server

final class DebugHarnessServer {
    static let shared = DebugHarnessServer()

    private let queue = DispatchQueue(label: "scrcpy.debugharness.server")
    private var listener: NWListener?
    private var methods: [String: HarnessMethod] = [:]
    private let startedAt = Date()

    private init() {}

    func start() {
        queue.async { [weak self] in
            guard let self = self, self.listener == nil else { return }

            // Force file logging on so logs.* has something to read.
            let mgr = AppLogManager.shared
            if !mgr.isLoggingEnabled {
                DispatchQueue.main.async { mgr.toggleLogging(true) }
            }

            self.registerMethods()
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let lst = try NWListener(using: params, on: kHarnessPort)
                lst.newConnectionHandler = { [weak self] conn in
                    self?.handle(connection: conn)
                }
                lst.start(queue: self.queue)
                self.listener = lst
                NSLog("🧰 DebugHarnessServer listening on http://0.0.0.0:6321/ (JSON-RPC)")
            } catch {
                NSLog("🧰 DebugHarnessServer failed to start: \(error)")
            }
        }
    }

    // MARK: - HTTP plumbing

    private func handle(connection conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn, buffer: Data())
    }

    /// Accumulate until we have full headers AND the Content-Length body.
    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { conn.cancel(); return }
            var buf = buffer
            if let data = data { buf.append(data) }

            if buf.count > kMaxRequestBytes {
                self.sendJSON(conn, status: 413, object: ["error": "request too large"])
                return
            }
            if error != nil {
                conn.cancel(); return
            }

            if let request = Self.parseHTTPRequest(buf) {
                if let need = request.missingBodyBytes, need > 0, !isComplete {
                    self.receiveRequest(conn, buffer: buf)   // body incomplete, keep reading
                    return
                }
                self.route(request, on: conn)
                return
            }
            if isComplete {
                self.sendJSON(conn, status: 400, object: ["error": "bad request"])
                return
            }
            self.receiveRequest(conn, buffer: buf)           // headers incomplete
        }
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let body: Data
        let missingBodyBytes: Int?
    }

    private static func parseHTTPRequest(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.split(separator: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "content-length" {
                contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = data[headerEnd.upperBound...]
        let missing = contentLength - body.count
        return HTTPRequest(method: String(parts[0]),
                           path: String(parts[1]),
                           body: Data(body.prefix(contentLength)),
                           missingBodyBytes: missing > 0 ? missing : nil)
    }

    private func route(_ req: HTTPRequest, on conn: NWConnection) {
        let path = req.path.split(separator: "?").first.map(String.init) ?? req.path

        switch (req.method, path) {
        case ("OPTIONS", _):
            sendResponse(conn, status: 204, contentType: "text/plain", body: Data())
        case ("GET", "/"):
            sendJSON(conn, status: 200, object: overviewHelp())
        case ("GET", let p) where p.hasPrefix("/help/"):
            let name = String(p.dropFirst("/help/".count))
            if let m = methods[name] {
                sendJSON(conn, status: 200, object: m.helpSpec)
            } else {
                sendJSON(conn, status: 404, object: [
                    "error": "unknown method '\(name)'",
                    "available": methods.keys.sorted(),
                ])
            }
        case ("POST", "/"):
            handleRPC(req.body, on: conn)
        default:
            sendJSON(conn, status: 404, object: [
                "error": "not found: \(req.method) \(path)",
                "hint": "GET / for the method overview; POST / with {\"method\":...,\"params\":...,\"id\":...} to call",
            ])
        }
    }

    // MARK: - JSON-RPC dispatch

    private func handleRPC(_ body: Data, on conn: NWConnection) {
        let id: Any
        let parsed = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        id = parsed?["id"] ?? NSNull()

        guard let obj = parsed else {
            sendRPCError(conn, id: NSNull(), code: -32700,
                         message: "parse error: body must be JSON like {\"method\":\"app.info\",\"params\":{},\"id\":1}")
            return
        }
        guard let methodName = obj["method"] as? String, !methodName.isEmpty else {
            sendRPCError(conn, id: id, code: -32600,
                         message: "missing 'method'",
                         data: ["available": methods.keys.sorted(),
                                "hint": "GET / for summaries, GET /help/<method> for the full spec"])
            return
        }
        guard let method = methods[methodName] else {
            sendRPCError(conn, id: id, code: -32601,
                         message: "method not found: '\(methodName)'",
                         data: ["available": methods.keys.sorted(),
                                "hint": "GET / for summaries"])
            return
        }
        let params = (obj["params"] as? [String: Any]) ?? [:]

        do {
            try validate(params, for: method)
            let result = try method.handler(params)
            sendJSON(conn, status: 200, object: ["id": id, "result": result])
        } catch let e as HarnessError {
            sendRPCError(conn, id: id, code: e.code, message: e.message, data: e.data)
        } catch {
            sendRPCError(conn, id: id, code: -32000, message: "\(error)")
        }
    }

    /// Required-param presence + simple type checks, with guided errors.
    private func validate(_ params: [String: Any], for method: HarnessMethod) throws {
        for p in method.params {
            let value = params[p.name]
            if value == nil {
                if p.required {
                    throw HarnessError.invalidParams(
                        "missing required param '\(p.name)' (\(p.type)): \(p.desc)",
                        method: method, param: p)
                }
                continue
            }
            switch p.type {
            case "int":
                if !(value is Int) && Int("\(value!)") == nil {
                    throw HarnessError.invalidParams(
                        "param '\(p.name)' must be an int, got: \(value!)",
                        method: method, param: p)
                }
            case "bool":
                if !(value is Bool) {
                    let s = "\(value!)".lowercased()
                    if s != "true" && s != "false" {
                        throw HarnessError.invalidParams(
                            "param '\(p.name)' must be a bool (true/false), got: \(value!)",
                            method: method, param: p)
                    }
                }
            case "uuid":
                guard let s = value as? String, UUID(uuidString: s) != nil else {
                    throw HarnessError.invalidParams(
                        "param '\(p.name)' must be a UUID string, got: \(value!)",
                        method: method, param: p)
                }
            default:  // string
                guard let s = value as? String else {
                    throw HarnessError.invalidParams(
                        "param '\(p.name)' must be a string, got: \(value!)",
                        method: method, param: p)
                }
                if let allowed = p.allowed, !allowed.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) {
                    throw HarnessError.invalidParams(
                        "param '\(p.name)' must be one of \(allowed), got: '\(s)'",
                        method: method, param: p)
                }
            }
        }
    }

    // MARK: - Help (level 1: overview only)

    private func overviewHelp() -> [String: Any] {
        var groups: [String: [[String: String]]] = [:]
        for m in methods.values.sorted(by: { $0.name < $1.name }) {
            let group = String(m.name.split(separator: ".").first ?? "misc")
            groups[group, default: []].append(["method": m.name, "summary": m.summary])
        }
        return [
            "service": "scrcpy-mobile DebugHarnessServer",
            "build": "DEBUG",
            "port": 6321,
            "protocol": "JSON-RPC over HTTP: POST / {\"method\":\"<name>\",\"params\":{...},\"id\":1}",
            "method_help": "GET /help/<method> reveals the full parameter spec + example for that method",
            "methods": groups,
            "uptime_s": Int(Date().timeIntervalSince(startedAt)),
        ]
    }

    // MARK: - Method registration

    private func registerMethods() {
        var list: [HarnessMethod] = []

        // ----- app -----
        list.append(HarnessMethod(
            name: "app.info",
            summary: "App/bundle/version/uptime info.",
            params: [],
            example: [:],
            handler: { [weak self] _ in
                let info = Bundle.main.infoDictionary ?? [:]
                return [
                    "bundle_id": Bundle.main.bundleIdentifier ?? "",
                    "version": info["CFBundleShortVersionString"] as? String ?? "",
                    "build": info["CFBundleVersion"] as? String ?? "",
                    "uptime_s": Int(Date().timeIntervalSince(self?.startedAt ?? Date())),
                    "pid": ProcessInfo.processInfo.processIdentifier,
                    "os": ProcessInfo.processInfo.operatingSystemVersionString,
                ]
            }))

        // ----- logs -----
        list.append(HarnessMethod(
            name: "logs.files",
            summary: "List log files; identifies the current one.",
            params: [],
            example: [:],
            handler: { _ in
                let mgr = AppLogManager.shared
                let files = mgr.getLogFilesList()
                return [
                    "logging_enabled": mgr.isLoggingEnabled,
                    "current_file": (files.first { $0.isCurrentLog }?.fileName) ?? NSNull(),
                    "files": files.map { [
                        "name": $0.fileName,
                        "size": $0.fileSize,
                        "modified_ms": Int64($0.modificationDate.timeIntervalSince1970 * 1000),
                        "is_current": $0.isCurrentLog,
                    ] as [String: Any] },
                ]
            }))

        let fileParam = HarnessParam(name: "file", type: "string", required: false,
                                     desc: "log file name from logs.files; defaults to newest")
        list.append(HarnessMethod(
            name: "logs.tail",
            summary: "Last N lines of a log file.",
            params: [
                HarnessParam(name: "n", type: "int", required: false,
                             desc: "line count", defaultValue: "500"),
                fileParam,
            ],
            example: ["n": 200],
            handler: { [weak self] p in
                guard let resolved = self?.resolveLogFile(p) else {
                    throw HarnessError(code: -32000, message: "no log file available")
                }
                let n = max(1, min(Self.intParam(p, "n") ?? 500, kMaxLogLines))
                fflush(stdout); fflush(stderr)
                let lines = Self.readTailLines(path: resolved.path, n: n)
                return ["file": resolved.name, "count": lines.count, "lines": lines]
            }))

        list.append(HarnessMethod(
            name: "logs.grep",
            summary: "Lines matching a substring in the log tail window.",
            params: [
                HarnessParam(name: "q", type: "string", required: true,
                             desc: "substring to match"),
                HarnessParam(name: "n", type: "int", required: false,
                             desc: "max matches", defaultValue: "500"),
                HarnessParam(name: "case_sensitive", type: "bool", required: false,
                             desc: "match case", defaultValue: "false"),
                fileParam,
            ],
            example: ["q": "SDL Hijacked", "n": 50],
            handler: { [weak self] p in
                guard let resolved = self?.resolveLogFile(p) else {
                    throw HarnessError(code: -32000, message: "no log file available")
                }
                let q = p["q"] as! String
                let n = max(1, min(Self.intParam(p, "n") ?? 500, kMaxLogLines))
                let caseSensitive = Self.boolParam(p, "case_sensitive") ?? false
                fflush(stdout); fflush(stderr)
                let needle = caseSensitive ? q : q.lowercased()
                var matches: [String] = []
                for line in Self.readTailLines(path: resolved.path, n: kMaxLogLines) {
                    let hay = caseSensitive ? line : line.lowercased()
                    if hay.contains(needle) {
                        matches.append(line)
                        if matches.count >= n { break }
                    }
                }
                return ["file": resolved.name, "q": q, "count": matches.count, "lines": matches]
            }))

        // ----- views -----
        list.append(HarnessMethod(
            name: "views.tree",
            summary: "Dump the UIView hierarchy of connected windows as JSON.",
            params: [
                HarnessParam(name: "depth", type: "int", required: false,
                             desc: "max recursion depth", defaultValue: "12"),
            ],
            example: ["depth": 8],
            handler: { p in
                let depth = max(1, min(Self.intParam(p, "depth") ?? 12, 50))
                var result: [[String: Any]] = []
                DispatchQueue.main.sync {
                    var nodeBudget = kMaxViewNodes
                    let windows = UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }
                        .flatMap { $0.windows }
                    for w in windows {
                        result.append(Self.viewNode(w, depth: depth, budget: &nodeBudget))
                    }
                }
                return ["windows": result.count, "tree": result]
            }))

        // ----- sessions -----
        list.append(HarnessMethod(
            name: "sessions.list",
            summary: "List saved sessions (id, host, port, name, type).",
            params: [],
            example: [:],
            handler: { _ in
                SessionManager.shared.loadSessions().map { $0.toDict() }
            }))

        let vncOptionParams = [
            HarnessParam(name: "vncPassword", type: "string", required: false,
                         desc: "VNC auth password (deviceType=vnc)"),
            HarnessParam(name: "vncUser", type: "string", required: false,
                         desc: "VNC auth username, rarely needed (deviceType=vnc)"),
            HarnessParam(name: "enableAudio", type: "bool", required: false,
                         desc: "enable the VNC companion audio stream", defaultValue: "false"),
            HarnessParam(name: "audioPort", type: "string", required: false,
                         desc: "audio stream port; empty = default 4901"),
            HarnessParam(name: "audioBufferMs", type: "int", required: false,
                         desc: "audio buffer in ms", defaultValue: "100"),
        ]

        list.append(HarnessMethod(
            name: "sessions.create",
            summary: "Create and persist a session.",
            params: [
                HarnessParam(name: "host", type: "string", required: true,
                             desc: "host/IP; optional scheme prefix vnc:// or adb:// forces device type"),
                HarnessParam(name: "port", type: "string", required: true,
                             desc: "port; without a scheme prefix, port decides type (590x→vnc, 5555+→adb)"),
                HarnessParam(name: "name", type: "string", required: false,
                             desc: "session display name"),
                HarnessParam(name: "useTailscale", type: "bool", required: false,
                             desc: "route via Tailscale", defaultValue: "false"),
            ] + vncOptionParams,
            example: ["host": "vnc://tokyo.example.com", "port": "5901",
                      "name": "Tokyo", "vncPassword": "secret",
                      "enableAudio": true, "audioPort": "4901"],
            handler: { p in
                let session = ScrcpySessionModel(host: p["host"] as! String,
                                                 port: p["port"] as! String,
                                                 sessionName: (p["name"] as? String) ?? "")
                session.useTailscale = Self.boolParam(p, "useTailscale") ?? false
                Self.applyVNCOptions(p, to: session)
                SessionManager.shared.saveSession(session)
                return session.toDict()
            }))

        list.append(HarnessMethod(
            name: "sessions.update",
            summary: "Update fields of an existing session by id.",
            params: [
                HarnessParam(name: "id", type: "uuid", required: true,
                             desc: "session id from sessions.list"),
                HarnessParam(name: "host", type: "string", required: false, desc: "new host"),
                HarnessParam(name: "port", type: "string", required: false, desc: "new port"),
                HarnessParam(name: "name", type: "string", required: false, desc: "new display name"),
                HarnessParam(name: "useTailscale", type: "bool", required: false, desc: "route via Tailscale"),
            ] + vncOptionParams,
            example: ["id": "<uuid-from-sessions.list>", "name": "Pixel 8"],
            handler: { p in
                let id = UUID(uuidString: p["id"] as! String)!
                guard let session = SessionManager.shared.getSession(id: id) else {
                    throw HarnessError(code: -32000,
                                       message: "session not found: \(id)",
                                       data: ["hint": "call sessions.list for valid ids"])
                }
                if let v = p["host"] as? String { session.host = v }
                if let v = p["port"] as? String { session.port = v }
                if let v = p["name"] as? String { session.sessionName = v }
                if let v = Self.boolParam(p, "useTailscale") { session.useTailscale = v }
                Self.applyVNCOptions(p, to: session)
                SessionManager.shared.saveSession(session)
                return session.toDict()
            }))

        list.append(HarnessMethod(
            name: "sessions.delete",
            summary: "Delete a session by id.",
            params: [
                HarnessParam(name: "id", type: "uuid", required: true,
                             desc: "session id from sessions.list"),
            ],
            example: ["id": "<uuid-from-sessions.list>"],
            handler: { p in
                let id = UUID(uuidString: p["id"] as! String)!
                guard SessionManager.shared.getSession(id: id) != nil else {
                    throw HarnessError(code: -32000,
                                       message: "session not found: \(id)",
                                       data: ["hint": "call sessions.list for valid ids"])
                }
                SessionManager.shared.deleteSession(id: id)
                return ["deleted": id.uuidString]
            }))

        // ----- actions -----
        list.append(HarnessMethod(
            name: "actions.list",
            summary: "List saved actions.",
            params: [],
            example: [:],
            handler: { _ in
                var out: [[String: Any]] = []
                DispatchQueue.main.sync {
                    out = ActionManager.shared.actions.map(Self.actionDict)
                }
                return out
            }))

        let timingParam = HarnessParam(
            name: "executionTiming", type: "string", required: false,
            desc: "when the action runs after connect",
            allowed: ExecutionTiming.allCases.map { $0.rawValue },
            defaultValue: ExecutionTiming.confirmation.rawValue)

        list.append(HarnessMethod(
            name: "actions.create",
            summary: "Create an action (ADB shell/keys or VNC).",
            params: [
                HarnessParam(name: "name", type: "string", required: true,
                             desc: "action display name"),
                HarnessParam(name: "deviceType", type: "string", required: true,
                             desc: "target device type",
                             allowed: SessionDeviceType.allCases.map { $0.rawValue }),
                HarnessParam(name: "adbCommands", type: "string", required: false,
                             desc: "shell commands (deviceType=adb; sets type to Shell Commands)"),
                timingParam,
                HarnessParam(name: "delaySeconds", type: "int", required: false,
                             desc: "delay when executionTiming=delayed", defaultValue: "3"),
                HarnessParam(name: "deviceId", type: "uuid", required: false,
                             desc: "bind to one device: the deviceId field from sessions.list; omit for any device"),
            ],
            example: ["name": "Reboot", "deviceType": "adb", "adbCommands": "reboot"],
            handler: { p in
                let action = ScrcpyAction()
                action.name = p["name"] as! String
                action.deviceType = SessionDeviceType(rawValue: (p["deviceType"] as! String).lowercased()) ?? .adb
                if let cmds = p["adbCommands"] as? String, !cmds.isEmpty {
                    action.adbActionType = .shellCommands
                    action.adbCommands = cmds
                    action.adbShellConfig.commands = cmds
                }
                if let t = p["executionTiming"] as? String,
                   let timing = ExecutionTiming(rawValue: t.lowercased()) {
                    action.executionTiming = timing
                }
                if let d = Self.intParam(p, "delaySeconds") { action.delaySeconds = d }
                if let ds = p["deviceId"] as? String { action.deviceId = UUID(uuidString: ds) }
                Self.upsertActionSync(action)
                return Self.actionDict(action)
            }))

        list.append(HarnessMethod(
            name: "actions.update",
            summary: "Update fields of an existing action by id.",
            params: [
                HarnessParam(name: "id", type: "uuid", required: true,
                             desc: "action id from actions.list"),
                HarnessParam(name: "name", type: "string", required: false, desc: "new name"),
                HarnessParam(name: "adbCommands", type: "string", required: false,
                             desc: "new shell commands"),
                timingParam,
                HarnessParam(name: "delaySeconds", type: "int", required: false,
                             desc: "delay when executionTiming=delayed"),
                HarnessParam(name: "deviceId", type: "uuid", required: false,
                             desc: "rebind to a device (deviceId from sessions.list)"),
            ],
            example: ["id": "<uuid-from-actions.list>", "adbCommands": "input keyevent 26"],
            handler: { p in
                let id = UUID(uuidString: p["id"] as! String)!
                var found: ScrcpyAction?
                DispatchQueue.main.sync {
                    found = ActionManager.shared.actions.first { $0.id == id }
                }
                guard let action = found else {
                    throw HarnessError(code: -32000,
                                       message: "action not found: \(id)",
                                       data: ["hint": "call actions.list for valid ids"])
                }
                if let v = p["name"] as? String { action.name = v }
                if let v = p["adbCommands"] as? String {
                    action.adbActionType = .shellCommands
                    action.adbCommands = v
                    action.adbShellConfig.commands = v
                }
                if let t = p["executionTiming"] as? String,
                   let timing = ExecutionTiming(rawValue: t.lowercased()) {
                    action.executionTiming = timing
                }
                if let d = Self.intParam(p, "delaySeconds") { action.delaySeconds = d }
                if let ds = p["deviceId"] as? String { action.deviceId = UUID(uuidString: ds) }
                Self.upsertActionSync(action)
                return Self.actionDict(action)
            }))

        list.append(HarnessMethod(
            name: "actions.delete",
            summary: "Delete an action by id.",
            params: [
                HarnessParam(name: "id", type: "uuid", required: true,
                             desc: "action id from actions.list"),
            ],
            example: ["id": "<uuid-from-actions.list>"],
            handler: { p in
                let id = UUID(uuidString: p["id"] as! String)!
                var existed = false
                DispatchQueue.main.sync {
                    existed = ActionManager.shared.actions.contains { $0.id == id }
                    if existed { ActionManager.shared.deleteAction(id: id) }
                }
                guard existed else {
                    throw HarnessError(code: -32000,
                                       message: "action not found: \(id)",
                                       data: ["hint": "call actions.list for valid ids"])
                }
                return ["deleted": id.uuidString]
            }))

        // ----- help -----
        list.append(HarnessMethod(
            name: "help",
            summary: "Full spec for one method (same as GET /help/<method>).",
            params: [
                HarnessParam(name: "method", type: "string", required: true,
                             desc: "method name from GET /"),
            ],
            example: ["method": "sessions.create"],
            handler: { [weak self] p in
                let name = p["method"] as! String
                guard let m = self?.methods[name] else {
                    throw HarnessError(code: -32000,
                                       message: "unknown method '\(name)'",
                                       data: ["available": self?.methods.keys.sorted() ?? []])
                }
                return m.helpSpec
            }))

        for m in list { methods[m.name] = m }
    }

    // MARK: - Session option helper

    /// Apply the optional vnc* / audio* params shared by sessions.create and
    /// sessions.update onto a session's VNCSessionOptions.
    private static func applyVNCOptions(_ p: [String: Any], to session: ScrcpySessionModel) {
        if let v = p["vncPassword"] as? String { session.vncOptions.vncPassword = v }
        if let v = p["vncUser"] as? String { session.vncOptions.vncUser = v }
        if let v = boolParam(p, "enableAudio") { session.vncOptions.enableAudio = v }
        if let v = p["audioPort"] as? String { session.vncOptions.audioPort = v }
        if let v = intParam(p, "audioBufferMs") { session.vncOptions.audioBufferMs = v }
    }

    // MARK: - Action persistence helper

    /// Synchronous upsert + save. ActionManager.saveAction defers its mutation
    /// to an async main hop, so a subsequent actions.list over RPC could miss
    /// the write; the harness needs read-your-writes. Mirrors ActionManager's
    /// private saveActions() (same UserDefaults key).
    private static func upsertActionSync(_ action: ScrcpyAction) {
        DispatchQueue.main.sync {
            let mgr = ActionManager.shared
            if let idx = mgr.actions.firstIndex(where: { $0.id == action.id }) {
                mgr.actions[idx] = action
            } else {
                mgr.actions.append(action)
            }
            if let data = try? JSONEncoder().encode(mgr.actions) {
                UserDefaults.standard.set(data, forKey: "ScrcpyActions")
            }
            mgr.objectWillChange.send()
        }
    }

    private static func actionDict(_ a: ScrcpyAction) -> [String: Any] {
        return [
            "id": a.id.uuidString,
            "name": a.name,
            "deviceType": a.deviceType.rawValue,
            "deviceId": a.deviceId?.uuidString ?? NSNull(),
            "adbActionType": a.adbActionType.rawValue,
            "adbCommands": a.adbShellConfig.commands.isEmpty ? a.adbCommands : a.adbShellConfig.commands,
            "executionTiming": a.executionTiming.rawValue,
            "delaySeconds": a.delaySeconds,
            "createdAt_ms": Int64(a.createdAt.timeIntervalSince1970 * 1000),
        ]
    }

    // MARK: - View tree helper

    private static func viewNode(_ view: UIView, depth: Int, budget: inout Int) -> [String: Any] {
        budget -= 1
        var node: [String: Any] = [
            "class": NSStringFromClass(type(of: view)),
            "frame": [
                "x": Int(view.frame.origin.x), "y": Int(view.frame.origin.y),
                "w": Int(view.frame.size.width), "h": Int(view.frame.size.height),
            ],
        ]
        if view.isHidden { node["hidden"] = true }
        if view.alpha < 1.0 { node["alpha"] = Double(view.alpha) }
        if view.tag != 0 { node["tag"] = view.tag }
        if let aid = view.accessibilityIdentifier, !aid.isEmpty { node["a11y_id"] = aid }
        if let label = view as? UILabel, let text = label.text, !text.isEmpty {
            node["text"] = String(text.prefix(120))
        }
        if let button = view as? UIButton, let title = button.currentTitle, !title.isEmpty {
            node["title"] = title
        }
        if let tf = view as? UITextField {
            node["text"] = tf.text ?? ""
            if let ph = tf.placeholder { node["placeholder"] = ph }
        }
        if let win = view as? UIWindow {
            node["is_key_window"] = win.isKeyWindow
        }

        if depth > 1 && budget > 0 && !view.subviews.isEmpty {
            var children: [[String: Any]] = []
            for sub in view.subviews {
                if budget <= 0 {
                    node["truncated"] = "node budget (\(kMaxViewNodes)) exhausted"
                    break
                }
                children.append(viewNode(sub, depth: depth - 1, budget: &budget))
            }
            node["subviews"] = children
        } else if !view.subviews.isEmpty {
            node["subviews_omitted"] = view.subviews.count
        }
        return node
    }

    // MARK: - Log file helpers (carried over from the retired DebugLogServer)

    private struct ResolvedFile { let name: String; let path: String }

    private func resolveLogFile(_ params: [String: Any]) -> ResolvedFile? {
        let mgr = AppLogManager.shared
        let list = mgr.getLogFilesList()
        if let name = params["file"] as? String, !name.isEmpty {
            if let hit = list.first(where: { $0.fileName == name }) {
                return ResolvedFile(name: hit.fileName, path: hit.filePath)
            }
            return nil
        }
        if let newest = list.first {
            return ResolvedFile(name: newest.fileName, path: newest.filePath)
        }
        let cur = mgr.getCurrentLogFilePath()
        return ResolvedFile(name: (cur as NSString).lastPathComponent, path: cur)
    }

    private static func readTailWindow(path: String, maxBytes: Int) -> Data {
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

    private static func readTailLines(path: String, n: Int) -> [String] {
        let window = readTailWindow(path: path, maxBytes: kMaxLogByteWindow)
        guard !window.isEmpty else { return [] }
        let text = String(decoding: window, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last == "" { lines.removeLast() }
        if lines.count > 1 { lines.removeFirst() }   // may start mid-line
        if lines.count > n { lines = Array(lines.suffix(n)) }
        return lines
    }

    // MARK: - param coercion

    private static func intParam(_ p: [String: Any], _ key: String) -> Int? {
        if let v = p[key] as? Int { return v }
        if let v = p[key] { return Int("\(v)") }
        return nil
    }

    private static func boolParam(_ p: [String: Any], _ key: String) -> Bool? {
        if let v = p[key] as? Bool { return v }
        if let v = p[key] as? String { return v.lowercased() == "true" }
        return nil
    }

    // MARK: - HTTP send helpers

    private func sendRPCError(_ conn: NWConnection, id: Any, code: Int,
                              message: String, data: [String: Any]? = nil) {
        var err: [String: Any] = ["code": code, "message": message]
        if let data = data { err["data"] = data }
        sendJSON(conn, status: 200, object: ["id": id, "error": err])
    }

    private func sendJSON(_ conn: NWConnection, status: Int, object: Any) {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys])
        } catch {
            let fallback = Data("{\"error\":\"serialize failed\"}".utf8)
            sendResponse(conn, status: 500,
                         contentType: "application/json; charset=utf-8", body: fallback)
            return
        }
        sendResponse(conn, status: status,
                     contentType: "application/json; charset=utf-8", body: data)
    }

    private func sendResponse(_ conn: NWConnection, status: Int,
                              contentType: String, body: Data) {
        var header = "HTTP/1.1 \(status) \(Self.httpReason(status))\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        header += "Access-Control-Allow-Headers: Content-Type\r\n"
        header += "\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        conn.send(content: payload, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private static func httpReason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        default:  return "Status"
        }
    }
}

#endif // DEBUG

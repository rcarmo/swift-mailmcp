import Foundation
import Network
import CryptoKit
import CoreFoundation

private let separator = Data("\r\n\r\n".utf8)

private struct Request {
    let method: String
    let path: String
    let headers: [String: String]
    let length: Int

    init?(_ data: Data) {
        guard let text = String(data: data, encoding: .ascii) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard start.count == 3, !start[0].isEmpty, !start[1].isEmpty, start[2] == "HTTP/1.1" else { return nil }
        method = String(start[0])
        path = String(start[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty,
                  name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  headers[name] == nil else { return nil }
            let raw = line[line.index(after: colon)...]
            guard raw.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else { return nil }
            headers[name] = raw.trimmingCharacters(in: .whitespaces)
        }
        if let size = headers["content-length"] {
            guard !size.isEmpty, size.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(size) else { return nil }
            length = value
        } else {
            length = 0
        }
        self.headers = headers
    }

    func accepts(_ type: String) -> Bool {
        (headers["accept"] ?? "").split(separator: ",").contains { entry in
            let parts = entry.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard parts.first == type else { return false }
            return parts.dropFirst().allSatisfy { !$0.hasPrefix("q=") || (Double($0.dropFirst(2)) ?? 0) > 0 }
        }
    }
}

private final class Cancellation {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw Failure("Request cancelled.") }
    }
}

final class HTTPServer {
    private let listener: NWListener
    private let network = DispatchQueue(label: "MailMCP.HTTP")
    private let automation: DispatchQueue
    private let operationCalls = DispatchQueue(label: "MailMCP.Operations")
    private let tools: Tools
    private var tokenHash: SHA256.Digest
    private let hosts: Set<String>
    private var clients: [UUID: NWConnection] = [:]
    private var pendingMailCalls = 0

    private static let modern = "2026-07-28"
    private static let legacy = ["2025-11-25", "2025-06-18", "2025-03-26"]
    private static let serverInfo = ["name": "MailMCP", "version": "0.5.0"]
    private static let capabilities: JSON = ["tools": [:] as JSON, "prompts": [:] as JSON]

    init(port: UInt16, token: String, stateDirectory: URL,
         onStatus: ((Result<Void, Error>) -> Void)? = nil) throws {
        let automation = DispatchQueue(label: "MailMCP.Automation", attributes: .concurrent)
        self.automation = automation
        tools = Tools(stateDirectory: stateDirectory)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
        tokenHash = SHA256.hash(data: Data(token.utf8))
        hosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("MailMCP listening at http://127.0.0.1:\(port)/mcp")
                fflush(stdout)
                onStatus?(.success(()))
            case .failed(let error):
                fputs("Listener failed: \(error)\n", stderr)
                if let onStatus { onStatus(.failure(error)) } else { exit(1) }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }

    func start(handoff: [UUID] = []) throws {
        try tools.takeOverMoves(handoff)
        tools.startMaintenance()
        listener.start(queue: network)
    }

    func setToken(_ token: String) {
        let hash = SHA256.hash(data: Data(token.utf8))
        network.sync { tokenHash = hash }
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < 32 else { connection.cancel(); return }
        let id = UUID()
        let cancellation = Cancellation()
        clients[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                cancellation.cancel()
                self?.clients.removeValue(forKey: id)
            default: break
            }
        }
        connection.start(queue: network)
        let deadline = DispatchWorkItem { [weak connection] in connection?.cancel() }
        network.asyncAfter(deadline: .now() + 10, execute: deadline)
        read(connection, buffer: Data(), deadline: deadline, cancellation: cancellation)
    }

    private func read(_ connection: NWConnection, buffer: Data, deadline: DispatchWorkItem, cancellation: Cancellation) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, end, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let delimiter = buffer.range(of: separator), delimiter.lowerBound <= 16_384 {
                guard let request = Request(buffer[..<delimiter.lowerBound]) else {
                    self.respond(connection, "400 Bad Request")
                    return
                }
                guard request.headers["transfer-encoding"] == nil else {
                    self.respond(connection, "501 Not Implemented")
                    return
                }
                guard request.length <= 65_536 else {
                    self.respond(connection, "413 Content Too Large")
                    return
                }
                let available = buffer.count - delimiter.upperBound
                if available >= request.length {
                    deadline.cancel()
                    guard available == request.length else {
                        self.respond(connection, "400 Bad Request")
                        return
                    }
                    self.handle(connection, request, Data(buffer[delimiter.upperBound...]), cancellation, requestEnded: end)
                    return
                }
            } else if buffer.count > 16_387 {
                self.respond(connection, "431 Request Header Fields Too Large")
                return
            }
            guard !end, error == nil else { connection.cancel(); return }
            self.read(connection, buffer: buffer, deadline: deadline, cancellation: cancellation)
        }
    }

    private func authorized(_ header: String?) -> Bool {
        guard let header else { return false }
        let parts = header.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        let providedHash = SHA256.hash(data: Data(parts[1].utf8))
        return zip(providedHash, tokenHash).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func respond(_ connection: NWConnection, _ status: String, extra: String = "", body: Data = Data(), trace: CallTrace? = nil) {
        let header = "HTTP/1.1 \(status)\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\n\(extra)\r\n"
        connection.send(content: Data(header.utf8) + body, contentContext: .finalMessage, completion: .contentProcessed { error in
            trace?.log(error == nil ? "response_sent" : "response_send_failed")
            connection.cancel()
        })
    }

    private func json(_ connection: NWConnection, _ value: JSON, status: String = "200 OK") {
        guard let body = try? JSONSerialization.data(withJSONObject: value) else {
            respond(connection, "500 Internal Server Error")
            return
        }
        respond(connection, status, extra: "Content-Type: application/json\r\n", body: body)
    }

    private func result(_ id: Any, _ value: JSON, modern: Bool = false) -> JSON {
        var value = value
        if modern {
            value["resultType"] = "complete"
            value["_meta"] = ["io.modelcontextprotocol/serverInfo": Self.serverInfo]
        }
        return ["jsonrpc": "2.0", "id": id, "result": value]
    }

    private func rpcError(_ id: Any, _ code: Int, _ message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func handle(_ connection: NWConnection, _ request: Request, _ body: Data, _ cancellation: Cancellation,
                        requestEnded: Bool) {
        guard let host = request.headers["host"]?.lowercased(), hosts.contains(host),
              request.headers["origin"].map({ $0 == "http://\(host)" }) ?? true else {
            respond(connection, "403 Forbidden")
            return
        }
        guard authorized(request.headers["authorization"]) else {
            respond(connection, "401 Unauthorized", extra: "WWW-Authenticate: Bearer realm=\"MailMCP\"\r\n")
            return
        }
        guard request.path == "/mcp" else { respond(connection, "404 Not Found"); return }
        guard request.method == "POST" else {
            respond(connection, "405 Method Not Allowed", extra: "Allow: POST\r\n")
            return
        }
        guard request.headers["content-type"]?.split(separator: ";").first?.lowercased() == "application/json" else {
            respond(connection, "415 Unsupported Media Type")
            return
        }
        guard request.accepts("application/json"), request.accepts("text/event-stream") else {
            respond(connection, "406 Not Acceptable")
            return
        }

        guard let decoded = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
            json(connection, rpcError(NSNull(), -32700, "Parse error"), status: "400 Bad Request")
            return
        }
        guard let rpc = decoded as? JSON, rpc["jsonrpc"] as? String == "2.0",
              let method = rpc["method"] as? String, !method.isEmpty else {
            json(connection, rpcError(NSNull(), -32600, "Invalid request"), status: "400 Bad Request")
            return
        }
        let id = rpc["id"] ?? NSNull()
        if rpc["id"] != nil, !(id is String) {
            guard let number = id as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.rounded(.towardZero) == number.doubleValue else {
                json(connection, rpcError(NSNull(), -32600, "Invalid request ID"), status: "400 Bad Request")
                return
            }
        }
        let params = rpc["params"] as? JSON ?? [:]
        if rpc["params"] != nil && !(rpc["params"] is JSON) {
            json(connection, rpcError(id, -32602, "Expected object params"), status: "400 Bad Request")
            return
        }
        let protocolHeader = request.headers["mcp-protocol-version"]
        let meta = params["_meta"] as? JSON
        let bodyVersion = meta?["io.modelcontextprotocol/protocolVersion"] as? String
        let modern = protocolHeader == Self.modern || bodyVersion == Self.modern
        if modern {
            guard let bodyVersion, meta?["io.modelcontextprotocol/clientCapabilities"] is JSON else {
                json(connection, rpcError(id, -32602, "Missing or invalid MCP request metadata"), status: "400 Bad Request")
                return
            }
            let name = params[method == "resources/read" ? "uri" : "name"] as? String
            let requiresName = ["tools/call", "prompts/get", "resources/read"].contains(method)
            let rawName = request.headers["mcp-name"]
            let headerName: String?
            if let rawName, rawName.hasPrefix("=?base64?"), rawName.hasSuffix("?=") {
                headerName = Data(base64Encoded: String(rawName.dropFirst(9).dropLast(2)))
                    .flatMap { String(data: $0, encoding: .utf8) }
            } else {
                headerName = rawName
            }
            if protocolHeader != Self.modern || bodyVersion != Self.modern ||
                request.headers["mcp-method"] != method ||
                (requiresName && (name == nil || headerName != name)) {
                json(connection, rpcError(id, -32020, "MCP metadata headers do not match the request"), status: "400 Bad Request")
                return
            }
        } else if let protocolHeader, !Self.legacy.contains(protocolHeader), method != "initialize" {
            var response = rpcError(id, -32022, "Unsupported MCP protocol version")
            response["error"] = ["code": -32022, "message": "Unsupported MCP protocol version",
                                 "data": ["supported": [Self.modern] + Self.legacy]]
            json(connection, response, status: "400 Bad Request")
            return
        }

        if rpc["id"] == nil {
            if !modern && (method == "notifications/initialized" || method == "notifications/cancelled") {
                respond(connection, "202 Accepted")
            } else {
                respond(connection, "400 Bad Request")
            }
            return
        }

        switch method {
        case "server/discover" where modern:
            json(connection, result(id, ["supportedVersions": [Self.modern], "capabilities": Self.capabilities], modern: true))
        case "initialize" where !modern:
            guard let requested = params["protocolVersion"] as? String else {
                json(connection, rpcError(id, -32602, "Expected protocolVersion"))
                return
            }
            let agreed = Self.legacy.contains(requested) ? requested : Self.legacy[0]
            json(connection, result(id, ["protocolVersion": agreed, "capabilities": Self.capabilities, "serverInfo": Self.serverInfo]))
        case "ping":
            json(connection, result(id, [:], modern: modern))
        case "tools/list":
            json(connection, result(id, ["tools": Tools.definitions], modern: modern))
        case "prompts/list":
            json(connection, result(id, ["prompts": Prompts.definitions], modern: modern))
        case "prompts/get":
            guard let name = params["name"] as? String,
                  params["arguments"] == nil || params["arguments"] is JSON else {
                json(connection, rpcError(id, -32602, "Expected prompt name and object arguments"))
                return
            }
            do {
                let prompt = try Prompts.get(name, arguments: params["arguments"] as? JSON ?? [:])
                json(connection, result(id, prompt, modern: modern))
            } catch {
                json(connection, rpcError(id, -32602, error.localizedDescription))
            }
        case "tools/call":
            guard let name = params["name"] as? String,
                  params["arguments"] == nil || params["arguments"] is JSON else {
                json(connection, rpcError(id, -32602, "Expected tool name and object arguments"))
                return
            }
            guard Tools.definitions.contains(where: { $0["name"] as? String == name }) else {
                json(connection, rpcError(id, -32602, "Unknown tool"))
                return
            }
            stream(connection, id: id, name: name, arguments: params["arguments"] as? JSON ?? [:],
                   modern: modern, cancellation: cancellation, requestEnded: requestEnded)
        default:
            json(connection, rpcError(id, -32601, "Method not found"), status: modern ? "404 Not Found" : "200 OK")
        }
    }

    private func stream(_ connection: NWConnection, id: Any, name: String, arguments: JSON, modern: Bool,
                        cancellation: Cancellation, requestEnded: Bool) {
        let trace = CallTrace(name)
        trace.log("received")
        let usesMail = Tools.usesMailQueue(name)
        let traceHeader = "X-MailMCP-Trace-ID: \(trace.id.uuidString)\r\n"
        if usesMail {
            guard pendingMailCalls < 8 else {
                trace.log("busy")
                respond(connection, "503 Service Unavailable", extra: traceHeader + "Retry-After: 1\r\n")
                return
            }
            pendingMailCalls += 1
        }

        var heartbeat: DispatchSourceTimer?
        if usesMail {
            let headers = "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nX-Accel-Buffering: no\r\n" + traceHeader + "\r\n: connected\n\n"
            connection.send(content: Data(headers.utf8), completion: .contentProcessed { error in
                if error != nil { cancellation.cancel(); trace.log("header_send_failed") }
            })
            let timer = DispatchSource.makeTimerSource(queue: network)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler {
                connection.send(content: Data(": working\n\n".utf8), completion: .contentProcessed { error in
                    if error != nil { cancellation.cancel(); trace.log("heartbeat_send_failed") }
                })
            }
            timer.resume()
            heartbeat = timer
        }
        if !requestEnded {
            // Only extra request bytes invalidate this POST. Finishing the TCP
            // write stream can also end a pending receive with a read-side error.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, ended, error in
                if let data, !data.isEmpty {
                    trace.log("unexpected_request_bytes")
                    cancellation.cancel()
                    connection.cancel()
                } else if ended || error != nil {
                    trace.log("peer_write_stream_ended")
                }
            }
        }

        let timer = heartbeat
        let queue = usesMail ? automation : operationCalls
        queue.async {
            trace.log("started")
            let response: JSON
            do {
                try cancellation.check()
                let value = try self.tools.call(name, values: arguments, trace: trace, checkCancellation: cancellation.check)
                let text = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                response = self.result(id, ["structuredContent": value,
                                            "content": [["type": "text", "text": String(decoding: text, as: UTF8.self)]],
                                            "isError": false], modern: modern)
                if name == "move_message", let operationID = value["operationId"] as? String {
                    trace.log("operation_id=\(operationID)")
                }
                if name == "move_messages", let operations = value["operations"] as? [JSON] {
                    for operationID in operations.compactMap({ $0["operationId"] as? String }) {
                        trace.log("operation_id=\(operationID)")
                    }
                }
                trace.log("completed")
            } catch {
                trace.log("tool_error")
                response = self.result(id, ["isError": true, "content": [["type": "text", "text": error.localizedDescription]]], modern: modern)
            }
            self.network.async {
                if usesMail { self.pendingMailCalls -= 1 }
                timer?.cancel()
                guard (try? cancellation.check()) != nil,
                      let data = try? JSONSerialization.data(withJSONObject: response) else {
                    trace.log("response_abandoned")
                    connection.cancel()
                    return
                }
                if usesMail {
                    let event = Data("event: message\ndata: ".utf8) + data + Data("\n\n".utf8)
                    connection.send(content: event, contentContext: .finalMessage, completion: .contentProcessed { error in
                        trace.log(error == nil ? "response_sent" : "response_send_failed")
                        connection.cancel()
                    })
                } else {
                    self.respond(connection, "200 OK", extra: traceHeader + "Content-Type: application/json\r\n", body: data, trace: trace)
                }
            }
        }
    }
}

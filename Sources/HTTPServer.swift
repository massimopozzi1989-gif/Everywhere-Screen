import CryptoKit
import Foundation
import Network

struct HTTPRequest {
    let method: String
    let segments: [String]
    let query: [String: String]
    /// Chiavi in minuscolo.
    let headers: [String: String]
    let remoteHost: String

    var cookies: [String: String] {
        var out: [String: String] = [:]
        for part in (headers["cookie"] ?? "").split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    var isWebSocketUpgrade: Bool {
        headers["upgrade"]?.lowercased() == "websocket" && headers["sec-websocket-key"] != nil
    }
}

/// Server HTTP/1.1 minimale su Network.framework: una richiesta per connessione,
/// più l'upgrade a WebSocket.
final class HTTPServer {
    let queue = DispatchQueue(label: "everywhere.server", qos: .userInteractive)
    var onRequest: ((HTTPRequest, HTTPConnection) -> Void)?
    var onStateChanged: ((String?) -> Void)?
    private var listener: NWListener?
    /// Tempo massimo per ricevere gli header: le connessioni che non li completano mai
    /// (client sparito, slowloris) altrimenti resterebbero aperte per sempre.
    private static let headerTimeout: TimeInterval = 10

    func start(port: UInt16) throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // Scopre i tablet spariti senza chiudere la connessione (standby, Wi-Fi perso) anche
        // quando lo schermo è fermo e non si sta inviando nulla.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true

        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onStateChanged?(nil)
            case .failed(let err): self?.onStateChanged?("Server: \(err.localizedDescription)")
            default: break
            }
        }
        l.start(queue: queue)
        listener = l
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        let timeout = DispatchWorkItem { conn.cancel() }
        queue.asyncAfter(deadline: .now() + Self.headerTimeout, execute: timeout)
        read(conn, buffer: Data(), timeout: timeout)
    }

    private func read(_ conn: NWConnection, buffer: Data, timeout: DispatchWorkItem) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                timeout.cancel()
                let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
                guard let request = Self.parse(head, remote: conn.endpoint) else { conn.cancel(); return }
                self.onRequest?(request, HTTPConnection(conn: conn, leftover: Data(buf[end.upperBound...])))
            } else if isComplete || error != nil || buf.count > 65_536 {
                timeout.cancel()
                conn.cancel()
            } else {
                self.read(conn, buffer: buf, timeout: timeout)
            }
        }
    }

    private static func parse(_ head: String, remote: NWEndpoint) -> HTTPRequest? {
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let target = first[1].split(separator: "?", maxSplits: 1).map(String.init)
        let segments = (target.first ?? "/").split(separator: "/").map(String.init)
        var query: [String: String] = [:]
        if target.count > 1 {
            for pair in target[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map {
                    $0.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
                }
                if kv.count == 2 { query[kv[0]] = kv[1] }
            }
        }

        var host = "?"
        if case let .hostPort(h, _) = remote { host = "\(h)" }
        return HTTPRequest(method: String(first[0]), segments: segments, query: query, headers: headers, remoteHost: host)
    }
}

/// Risposta a una singola richiesta.
struct HTTPConnection {
    let conn: NWConnection
    let leftover: Data

    func send(status: String, type: String, body: Data, headers: [String] = []) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n"
        for h in headers { head += h + "\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    func html(_ page: String) {
        send(status: "200 OK", type: "text/html; charset=utf-8", body: Data(page.utf8))
    }

    func json(_ object: [String: Any], status: String = "200 OK", headers: [String] = []) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        send(status: status, type: "application/json", body: body, headers: headers)
    }

    func notFound() {
        send(status: "404 Not Found", type: "text/plain", body: Data("404".utf8))
    }

    func unauthorized() {
        json(["error": "Dispositivo non abbinato"], status: "401 Unauthorized")
    }

    func redirect(_ location: String) {
        send(status: "302 Found", type: "text/plain", body: Data(), headers: ["Location: \(location)"])
    }

    func upgradeToWebSocket(_ request: HTTPRequest) -> WebSocket {
        let key = request.headers["sec-websocket-key"] ?? ""
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let accept = Data(digest).base64EncodedString()
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        return WebSocket(conn: conn, initial: leftover)
    }
}

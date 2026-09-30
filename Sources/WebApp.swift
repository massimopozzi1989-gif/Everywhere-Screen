import Foundation

/// Rotte HTTP dell'app. Tutto ciò che mostra lo schermo o controlla il Mac richiede un
/// dispositivo abbinato (cookie `es_token`).
///
///   /              scelta dello schermo (o redirect se ce n'è uno solo)
///   /N             pagina per il tablet (abbinamento incluso)
///   /api/me        stato dell'abbinamento
///   /api/pair/…    richiesta e conferma del codice
///   /ws/N          WebSocket: video H.264 + input
///   /stream/N      MJPEG di ripiego
final class WebApp {
    let server = HTTPServer()
    let pairing: PairingManager
    var touchIcon: Data?

    private static let cookie = "es_token"
    private let lock = NSLock()
    private var hubs: [Int: StreamHub] = [:]

    var queue: DispatchQueue { server.queue }

    init(pairing: PairingManager = PairingManager()) {
        self.pairing = pairing
    }

    func start(port: UInt16) throws {
        server.onRequest = { [weak self] request, conn in self?.route(request, conn) }
        try server.start(port: port)
    }

    func register(_ hub: StreamHub) {
        lock.lock(); hubs[hub.channel] = hub; lock.unlock()
    }

    func unregister(channel: Int) {
        lock.lock(); hubs[channel] = nil; lock.unlock()
    }

    var allHubs: [StreamHub] {
        lock.lock(); defer { lock.unlock() }
        return Array(hubs.values)
    }

    private func hub(_ segment: String) -> StreamHub? {
        guard let n = Int(segment) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return hubs[n]
    }

    private var channels: [Int] {
        lock.lock(); defer { lock.unlock() }
        return hubs.keys.sorted()
    }

    private func route(_ req: HTTPRequest, _ c: HTTPConnection) {
        let s = req.segments
        let device = req.cookies[Self.cookie].flatMap { pairing.device(forToken: $0) }

        switch s.first ?? "" {
        case "":
            let list = channels
            if list.count == 1 { c.redirect("/\(list[0])") } else { c.html(Page.index(channels: list)) }

        case "apple-touch-icon.png", "apple-touch-icon-precomposed.png":
            if let touchIcon { c.send(status: "200 OK", type: "image/png", body: touchIcon) } else { c.notFound() }

        case "api":
            api(req, c, device: device)

        case "ws":
            guard s.count == 2, let hub = hub(s[1]), req.isWebSocketUpgrade else { return c.notFound() }
            guard let device else { return c.unauthorized() }
            hub.addViewer(c.upgradeToWebSocket(req), deviceID: device.id, control: device.control)

        case "stream":
            guard s.count == 2, let hub = hub(s[1]) else { return c.notFound() }
            guard let device else { return c.unauthorized() }
            hub.addMJPEG(c.conn, deviceID: device.id)

        default:
            if s.count == 1, let n = Int(s[0]), hub(s[0]) != nil { c.html(Page.viewer(channel: n)) } else { c.notFound() }
        }
    }

    private func api(_ req: HTTPRequest, _ c: HTTPConnection, device: PairedDevice?) {
        switch Array(req.segments.dropFirst()) {
        case ["me"]:
            guard let device else { return c.unauthorized() }
            c.json(["ok": true, "name": device.name, "control": device.control && Edition.inputAllowed])

        case ["pair", "start"]:
            let name = req.query["name"].flatMap { $0.isEmpty ? nil : $0 } ?? "Tablet"
            if let request = pairing.startRequest(name: name, host: req.remoteHost) {
                c.json(["id": request.id])
            } else {
                c.json(["error": "Attendi qualche secondo e riprova."], status: "429 Too Many Requests")
            }

        case ["pair", "confirm"]:
            switch pairing.confirm(id: req.query["id"] ?? "", code: req.query["code"] ?? "") {
            case let .paired(token, _):
                c.json(["ok": true], headers: [
                    "Set-Cookie: \(Self.cookie)=\(token); Path=/; Max-Age=315360000; HttpOnly; SameSite=Strict",
                ])
            case let .wrongCode(remaining):
                c.json(["error": "Codice errato. Tentativi rimasti: \(remaining)."], status: "403 Forbidden")
            case .expired:
                c.json(["error": "Richiesta scaduta: premi di nuovo Collega.", "restart": true], status: "410 Gone")
            }

        default:
            c.notFound()
        }
    }
}

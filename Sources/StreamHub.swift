import CoreImage
import CoreMedia
import Foundation
import Network

/// Un canale (uno schermo) e i suoi client: H.264 su WebSocket, oppure MJPEG come ripiego
/// per i browser senza Media Source Extensions.
///
/// Viewer e client MJPEG vivono sulla coda del server; la codifica gira su `encodeQueue`.
final class StreamHub {
    let channel: Int
    var onViewersChanged: ((Int) -> Void)?
    var onInput: ((_ message: [String: Any], _ display: CGDirectDisplayID) -> Void)?
    var onFit: ((_ width: Int, _ height: Int) -> Void)?

    private let queue: DispatchQueue
    private let encodeQueue = DispatchQueue(label: "everywhere.encode", qos: .userInteractive)
    private let encoder = H264Encoder()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private var viewers: [ObjectIdentifier: Viewer] = [:]
    /// Chiede ai tablet di passare a schermo intero al primo tocco (solo sulla coda del server).
    private var autoFullscreen = false
    private var mjpegClients: [ObjectIdentifier: MJPEGClient] = [:]
    private var lastJPEG: Data?

    // Stato condiviso tra le code.
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var lastBuffer: CVPixelBuffer?
    private var drainScheduled = false
    private var h264Count = 0
    private var mjpegCount = 0
    private var _displayID: CGDirectDisplayID = 0
    private var _quality = 0.7
    private var _fps = 30
    /// Riduzione del bitrate quando la rete di un viewer non tiene il passo (1 = nessuna).
    private var _congestion = 1.0

    var displayID: CGDirectDisplayID {
        get { lock.lock(); defer { lock.unlock() }; return _displayID }
        set { lock.lock(); _displayID = newValue; lock.unlock() }
    }

    init(channel: Int, queue: DispatchQueue) {
        self.channel = channel
        self.queue = queue
        encoder.onFrame = { [weak self] frame in
            self?.queue.async { self?.deliver(frame) }
        }
    }

    /// Qualità 0…1: qualità JPEG e bitrate H.264.
    func configure(quality: Double, fps: Int) {
        lock.lock(); _quality = quality; _fps = fps; lock.unlock()
    }

    // MARK: - Frame dalla cattura

    func push(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        latest = pixelBuffer
        lastBuffer = pixelBuffer
        let schedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        // Se l'encoder è indietro si codifica solo il frame più recente.
        if schedule { encodeQueue.async { self.drain() } }
    }

    /// Ricodifica l'ultimo frame (serve ai nuovi client anche quando lo schermo è fermo).
    private func refresh() {
        lock.lock(); let pb = lastBuffer; lock.unlock()
        if let pb { push(pb) }
    }

    private func requestKeyframe() {
        encoder.requestKeyframe()
        refresh()
    }

    private func drain() {
        lock.lock()
        let pb = latest
        latest = nil
        drainScheduled = false
        let wantsH264 = h264Count > 0, wantsJPEG = mjpegCount > 0
        let quality = _quality, fps = _fps, congestion = _congestion
        lock.unlock()
        guard let pb else { return }

        if wantsH264 {
            encoder.fps = fps
            encoder.referenceBitrate = Int(Double(Self.bitrate(forQuality: quality)) * congestion)
            encoder.encode(pb, pts: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        if wantsJPEG {
            let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
            if let jpeg = ciContext.jpegRepresentation(of: CIImage(cvPixelBuffer: pb), colorSpace: sRGB, options: options) {
                queue.async { self.broadcastJPEG(jpeg) }
            }
        }
    }

    private static func bitrate(forQuality q: Double) -> Int {
        switch q {
        case ..<0.6: return 3_000_000
        case ..<0.8: return 6_000_000
        case ..<0.9: return 10_000_000
        default: return 16_000_000
        }
    }

    // MARK: - Client H.264 (WebSocket)

    func addViewer(_ ws: WebSocket, deviceID: String, control: Bool) {
        let viewer = Viewer(ws: ws, deviceID: deviceID, control: control)
        let id = ObjectIdentifier(ws)
        ws.onText = { [weak self] text in self?.handle(text, from: id) }
        // Il client ha smaltito l'arretrato: se aspetta un keyframe lo si chiede ora (anche a
        // schermo fermo, quando non arriverebbero frame nuovi).
        ws.onDrain = { [weak self] in
            guard let self, let viewer = self.viewers[id], viewer.readyForKeyframe else { return }
            self.scheduleKeyframe()
        }
        ws.onClose = { [weak self] in
            self?.viewers[id] = nil
            self?.updateCounts()
        }
        viewers[id] = viewer
        ws.start()
        viewer.sendInfo(fullscreen: autoFullscreen)
        updateCounts()
    }

    private func handle(_ text: String, from id: ObjectIdentifier) {
        guard let viewer = viewers[id],
              let msg = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = msg["t"] as? String
        else { return }

        switch type {
        case "hello":
            viewer.wantsVideo = msg["mse"] as? Bool ?? false
            viewer.needsInit = true
            updateCounts()
            if viewer.wantsVideo { requestKeyframe() }
        case "a":
            // Conferma di ricezione dal browser: misura il ritardo reale, buffer TCP e Wi-Fi compresi.
            if let bytes = (msg["b"] as? NSNumber)?.int64Value, viewer.acknowledge(bytes), viewer.readyForKeyframe {
                scheduleKeyframe()
            }
        case "kf":
            viewer.needsInit = true
            requestKeyframe()
        case "fit":
            if let w = msg["w"] as? Int, let h = msg["h"] as? Int { onFit?(w, h) }
        default:
            if viewer.control, Edition.inputAllowed { onInput?(msg, displayID) }
        }
    }

    /// Un client che non smaltisce nulla per così tanto è sparito (es. tablet in standby):
    /// chiuderlo lo fa riconnettere e libera la memoria.
    private static let stallTimeout: TimeInterval = 10

    private func deliver(_ frame: EncodedFrame) {
        lock.lock(); let fps = _fps; lock.unlock()
        let now = ProcessInfo.processInfo.systemUptime
        var needKey = false, newStall = false, allStalled = true
        var dead: [Viewer] = []
        for viewer in viewers.values where viewer.wantsVideo {
            let wasStalled = viewer.stalledSince != nil
            if viewer.send(frame, fps: fps, now: now) { needKey = true }
            if let since = viewer.stalledSince {
                if !wasStalled { newStall = true; viewer.lastStall = now }
                if now - since > Self.stallTimeout { dead.append(viewer) }
            }
            if now - viewer.lastStall > 5 { allStalled = false }
        }
        dead.forEach { $0.ws.close() }
        if needKey { scheduleKeyframe() }
        adaptBitrate(congested: newStall && allStalled, now: now)
    }

    /// Quando tutti i viewer del canale restano indietro il bitrate scende del 30% (fino al 35%),
    /// così il keyframe per ripartire e i frame successivi passano davvero; poi risale piano se
    /// la rete regge. Un Wi-Fi debole così si stabilizza invece di alternare blocchi e salti.
    /// Un solo tablet in difficoltà (o in standby) non peggiora l'immagine degli altri.
    private var lastCongestion: TimeInterval = 0
    private var lastRaise: TimeInterval = 0
    private func adaptBitrate(congested: Bool, now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if congested {
            _congestion = max(0.35, _congestion * 0.7)
            lastCongestion = now
        } else if _congestion < 1, now - lastCongestion > 4, now - lastRaise > 2 {
            _congestion = min(1, _congestion * 1.15)
            lastRaise = now
        }
    }

    /// Keyframe "ritardato": se lo schermo è fermo non arriverebbero frame nuovi, quindi dopo
    /// un attimo si ricodifica l'ultimo. Il ritardo evita di girare a vuoto se un client è
    /// ancora in arretrato.
    private var keyframeScheduled = false
    private func scheduleKeyframe() {
        encoder.requestKeyframe()
        guard !keyframeScheduled else { return }
        keyframeScheduled = true
        queue.asyncAfter(deadline: .now() + 0.05) {
            self.keyframeScheduled = false
            self.refresh()
        }
    }

    // MARK: - Client MJPEG

    func addMJPEG(_ conn: NWConnection, deviceID: String) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nCache-Control: no-cache, no-store, must-revalidate\r\nPragma: no-cache\r\nConnection: close\r\n\r\n"
        let id = ObjectIdentifier(conn)
        let client = MJPEGClient(conn: conn, deviceID: deviceID) { [weak self] in
            self?.mjpegClients[id] = nil
            self?.updateCounts()
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: client.close()
            default: break
            }
        }
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        watchForClose(conn, client)
        mjpegClients[id] = client
        updateCounts()
        if let lastJPEG { client.send(frame: lastJPEG) } else { refresh() }
    }

    /// Il client MJPEG non invia nulla: si legge solo per accorgersi subito che ha chiuso,
    /// anche a schermo fermo quando non si sta inviando niente.
    private func watchForClose(_ conn: NWConnection, _ client: MJPEGClient) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil { client.close() } else { self?.watchForClose(conn, client) }
        }
    }

    private func broadcastJPEG(_ jpeg: Data) {
        lastJPEG = jpeg
        for client in mjpegClients.values { client.send(frame: jpeg) }
    }

    // MARK: - Gestione dispositivi

    func disconnect(deviceID: String) {
        queue.async {
            self.viewers.values.filter { $0.deviceID == deviceID }.forEach { $0.ws.close() }
            self.mjpegClients.values.filter { $0.deviceID == deviceID }.forEach { $0.close() }
        }
    }

    func setControl(_ allowed: Bool, deviceID: String) {
        queue.async {
            for viewer in self.viewers.values where viewer.deviceID == deviceID {
                viewer.control = allowed
                viewer.sendInfo(fullscreen: self.autoFullscreen)
            }
        }
    }

    func setAutoFullscreen(_ on: Bool) {
        queue.async {
            self.autoFullscreen = on
            self.viewers.values.forEach { $0.sendInfo(fullscreen: on) }
        }
    }

    /// I tablet ricaricano la pagina (es. dopo il cambio di lingua).
    func reloadClients() {
        queue.async { self.viewers.values.forEach { $0.ws.send(json: ["t": "reload"]) } }
    }

    /// Mostra il numero dello schermo sui tablet collegati.
    func identify() {
        queue.async {
            self.viewers.values.forEach { $0.ws.send(json: ["t": "identify", "n": self.channel]) }
        }
    }

    func closeAll() {
        queue.async {
            self.viewers.values.forEach { $0.ws.close() }
            self.mjpegClients.values.forEach { $0.close() }
        }
    }

    private func updateCounts() {
        let h264 = viewers.values.filter(\.wantsVideo).count
        lock.lock()
        h264Count = h264; mjpegCount = mjpegClients.count
        if h264 == 0 { _congestion = 1 }
        lock.unlock()
        onViewersChanged?(viewers.count + mjpegClients.count)
    }
}

/// Un tablet collegato via WebSocket.
private final class Viewer {
    let ws: WebSocket
    let deviceID: String
    var control: Bool
    var wantsVideo = false
    var needsInit = true
    private(set) var waitingForKey = true
    /// Da quando il client è troppo indietro per ricevere frame.
    private(set) var stalledSince: TimeInterval?
    /// Ultima volta che è rimasto indietro (per il bitrate adattivo del canale).
    var lastStall: TimeInterval = -.infinity
    private var sps = Data()
    private var muxer = FMP4Muxer(fps: 30)

    /// Limite di memoria per i dati non ancora consegnati al sistema.
    private static let maxBacklog = 1_000_000
    /// Un invio fermo così a lungo nella coda locale: la rete non tiene il passo.
    private static let maxPendingAge: TimeInterval = 0.25
    /// Ritardo massimo dei frame inviati e non ancora confermati dal browser. È la misura che
    /// conta sul Wi-Fi: comprende i buffer TCP del Mac, la rete e il browser stesso.
    private static let maxInFlightAge: TimeInterval = 0.2
    private var configuredFPS = 0

    /// Conferme dal browser: abilitate dalla prima ricevuta (i client che non le inviano usano
    /// solo la coda locale). Ogni voce: byte binari cumulativi dopo un invio e il suo istante.
    private var acks = false
    private var sentBytes: Int64 = 0
    private var ackedBytes: Int64 = 0
    private var inFlight: [(end: Int64, at: TimeInterval)] = []
    private var inFlightHead = 0

    init(ws: WebSocket, deviceID: String, control: Bool) {
        self.ws = ws
        self.deviceID = deviceID
        self.control = control
    }

    func sendInfo(fullscreen: Bool) {
        ws.send(json: ["t": "info", "control": control && Edition.inputAllowed, "fs": fullscreen])
    }

    /// Il client aspetta un keyframe e non ha più arretrato: è il momento di chiederlo.
    var readyForKeyframe: Bool {
        wantsVideo && waitingForKey && ws.pendingBytes == 0 && inFlightHead == inFlight.count
    }

    /// Registra una conferma; ritorna true se non resta nulla in viaggio.
    func acknowledge(_ bytes: Int64) -> Bool {
        acks = true
        ackedBytes = min(max(ackedBytes, bytes), sentBytes)
        while inFlightHead < inFlight.count, inFlight[inFlightHead].end <= ackedBytes { inFlightHead += 1 }
        if inFlightHead == inFlight.count {
            inFlight.removeAll(keepingCapacity: true); inFlightHead = 0
            return true
        }
        if inFlightHead > 256 { inFlight.removeFirst(inFlightHead); inFlightHead = 0 }
        return false
    }

    private func sendBinary(_ data: Data, now: TimeInterval) {
        sentBytes += Int64(data.count)
        inFlight.append((sentBytes, now))
        ws.send(binary: data)
    }

    private func isBehind(now: TimeInterval) -> Bool {
        if ws.pendingBytes > Self.maxBacklog || ws.pendingAge(now: now) > Self.maxPendingAge { return true }
        return acks && inFlightHead < inFlight.count && now - inFlight[inFlightHead].at > Self.maxInFlightAge
    }

    /// Ritorna true se serve un keyframe per questo client.
    func send(_ frame: EncodedFrame, fps: Int, now: TimeInterval) -> Bool {
        // Rete lenta: invece di accumulare ritardo si saltano i frame. Il keyframe per ripartire
        // si chiede solo quando il client ha smaltito l'arretrato (onDrain o ultima conferma):
        // chiederlo a ogni frame trasformerebbe in keyframe anche lo stream degli altri client.
        if isBehind(now: now) {
            if stalledSince == nil { stalledSince = now }
            waitingForKey = true
            return false
        }
        stalledSince = nil
        if needsInit || frame.sps != sps || configuredFPS != fps {
            guard frame.isKey else { waitingForKey = true; return true }
            ws.send(json: ["t": "init", "codec": frame.codec, "w": frame.width, "h": frame.height, "fps": fps])
            sendBinary(FMP4Muxer.initSegment(for: frame), now: now)
            muxer = FMP4Muxer(fps: fps)
            sps = frame.sps
            configuredFPS = fps
            needsInit = false
            waitingForKey = false
        }
        if waitingForKey {
            guard frame.isKey else { return true }
            waitingForKey = false
        }
        sendBinary(muxer.mediaSegment(for: frame), now: now)
        return false
    }
}

/// Client MJPEG: tiene solo il frame più recente se la rete è più lenta della cattura.
private final class MJPEGClient {
    let deviceID: String
    private let conn: NWConnection
    private let onClose: () -> Void
    private var busy = false
    private var pending: Data?
    private var closed = false

    init(conn: NWConnection, deviceID: String, onClose: @escaping () -> Void) {
        self.conn = conn
        self.deviceID = deviceID
        self.onClose = onClose
    }

    func send(frame: Data) {
        guard !closed else { return }
        if busy { pending = frame; return }
        busy = true
        var part = Data("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(frame.count)\r\n\r\n".utf8)
        part.append(frame)
        part.append(Data("\r\n".utf8))
        conn.send(content: part, completion: .contentProcessed { [self] error in
            busy = false
            if error != nil { close(); return }
            if let next = pending { pending = nil; send(frame: next) }
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        conn.cancel()
        onClose()
    }
}

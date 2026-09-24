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
        let quality = _quality, fps = _fps
        lock.unlock()
        guard let pb else { return }

        if wantsH264 {
            encoder.fps = fps
            encoder.referenceBitrate = Self.bitrate(forQuality: quality)
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
        ws.onClose = { [weak self] in
            self?.viewers[id] = nil
            self?.updateCounts()
        }
        viewers[id] = viewer
        ws.start()
        viewer.sendInfo()
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
        case "kf":
            viewer.needsInit = true
            requestKeyframe()
        case "fit":
            if let w = msg["w"] as? Int, let h = msg["h"] as? Int { onFit?(w, h) }
        default:
            if viewer.control, Edition.inputAllowed { onInput?(msg, displayID) }
        }
    }

    private func deliver(_ frame: EncodedFrame) {
        lock.lock(); let fps = _fps; lock.unlock()
        var needKey = false
        for viewer in viewers.values where viewer.wantsVideo {
            if !viewer.send(frame, fps: fps) { needKey = true }
        }
        if needKey { scheduleKeyframe() }
    }

    /// Keyframe "ritardato": se lo schermo è fermo non arriverebbero frame nuovi, quindi dopo
    /// un attimo si ricodifica l'ultimo. Il ritardo evita di girare a vuoto se un client è
    /// ancora in arretrato.
    private var keyframeScheduled = false
    private func scheduleKeyframe() {
        encoder.requestKeyframe()
        guard !keyframeScheduled else { return }
        keyframeScheduled = true
        queue.asyncAfter(deadline: .now() + 0.25) {
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
        mjpegClients[id] = client
        updateCounts()
        if let lastJPEG { client.send(frame: lastJPEG) } else { refresh() }
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
                viewer.sendInfo()
            }
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
        lock.lock(); h264Count = h264; mjpegCount = mjpegClients.count; lock.unlock()
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
    private var waitingForKey = true
    private var sps = Data()
    private var muxer = FMP4Muxer(fps: 30)

    /// Oltre questa quantità di dati non ancora inviati il client è troppo indietro.
    private static let maxBacklog = 1_500_000

    init(ws: WebSocket, deviceID: String, control: Bool) {
        self.ws = ws
        self.deviceID = deviceID
        self.control = control
    }

    func sendInfo() {
        ws.send(json: ["t": "info", "control": control && Edition.inputAllowed])
    }

    /// Ritorna false se serve un keyframe per questo client.
    func send(_ frame: EncodedFrame, fps: Int) -> Bool {
        if needsInit || frame.sps != sps {
            guard frame.isKey else { waitingForKey = true; return false }
            ws.send(json: ["t": "init", "codec": frame.codec, "w": frame.width, "h": frame.height])
            ws.send(binary: FMP4Muxer.initSegment(for: frame))
            muxer = FMP4Muxer(fps: fps)
            sps = frame.sps
            needsInit = false
            waitingForKey = false
        }
        if waitingForKey {
            guard frame.isKey else { return false }
            waitingForKey = false
        }
        // Rete lenta: invece di accumulare ritardo si salta fino al prossimo keyframe.
        if ws.pendingBytes > Self.maxBacklog {
            waitingForKey = true
            return false
        }
        ws.send(binary: muxer.mediaSegment(for: frame))
        return true
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

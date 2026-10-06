import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Network

// Stress test del server, dello streaming e dell'abbinamento, in-process e senza cattura reale:
// i frame sono sintetici e i client sono socket veri su 127.0.0.1. Non muove il mouse, non crea
// schermi e non chiede permessi. Esegui con: scripts/stress.sh

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)
var fdLimit = rlimit()
getrlimit(RLIMIT_NOFILE, &fdLimit)
fdLimit.rlim_cur = min(10_240, fdLimit.rlim_max)
setrlimit(RLIMIT_NOFILE, &fdLimit)

// Uso: stress-tests <cartella> [scenari…]
//      stress-tests <cartella> --live <porta> <token>   (contro l'app vera già avviata)
let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "build/stress"
let liveIndex = args.firstIndex(of: "--live")
let port: UInt16 = liveIndex.flatMap { UInt16(args[$0 + 1]) } ?? 5098
let liveToken = liveIndex.map { args[$0 + 2] }
/// --serve: server con frame sintetici sul canale 1 per provare la pagina in un browser; gli input
/// vengono stampati, non eseguiti.
let serveMode = args.contains("--serve")
var servedProducer: Producer?
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// MARK: - Report

final class Report {
    private let lock = NSLock()
    private(set) var failures: [String] = []
    private(set) var metrics: [(String, String)] = []

    func check(_ ok: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
        guard !ok else { return }
        let m = message()
        lock.lock(); failures.append(m); lock.unlock()
        print("   ✗ \(m)  (riga \(line))")
    }

    func metric(_ name: String, _ value: String) {
        lock.lock(); metrics.append((name, value)); lock.unlock()
        print("   · \(name): \(value)")
    }
}

let report = Report()
func section(_ title: String) { print("\n▶ \(title)") }
func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
func ms(_ s: Double) -> String { String(format: "%.1f ms", s * 1000) }
func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let s = values.sorted()
    return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
}

func rssMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : .nan
}

func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
}

func openFDs() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
}

/// Thread veri (non concurrentPerform): i client fanno I/O bloccante.
func parallel(_ n: Int, _ body: @escaping (Int) -> Void) {
    let group = DispatchGroup()
    for i in 0..<n {
        group.enter()
        let t = Thread { body(i); group.leave() }
        t.stackSize = 1 << 20
        t.start()
    }
    group.wait()
}

func waitUntil(_ timeout: Double, _ condition: () -> Bool) -> Bool {
    let end = uptime() + timeout
    while uptime() < end {
        if condition() { return true }
        usleep(20_000)
    }
    return condition()
}

final class Counter {
    private let lock = NSLock()
    private var v = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return v }
    func add(_ n: Int = 1) { lock.lock(); v += n; lock.unlock() }
    func set(_ n: Int) { lock.lock(); v = n; lock.unlock() }
}

// MARK: - Socket client

final class Sock {
    let fd: Int32
    private var buf: [UInt8] = []
    private var pos = 0
    private var scratch = [UInt8](repeating: 0, count: 65_536)
    private var closed = false
    private(set) var sawEOF = false

    init?(rcvbuf: Int32? = nil, timeout: Double = 5) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, 4)
        if var rb = rcvbuf { setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rb, 4) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard r == 0 else { Darwin.close(fd); return nil }
        self.fd = fd
        setTimeout(timeout)
    }

    deinit { close() }

    func setTimeout(_ t: Double) {
        var tv = timeval(tv_sec: Int(t), tv_usec: Int32(t.truncatingRemainder(dividingBy: 1) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    @discardableResult
    func write(_ data: [UInt8]) -> Bool {
        var off = 0
        while off < data.count {
            let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + off, data.count - off) }
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    @discardableResult
    func write(_ s: String) -> Bool { write(Array(s.utf8)) }

    private func fill() -> Bool {
        if pos == buf.count { buf.removeAll(keepingCapacity: true); pos = 0 } else if pos > 1 << 20 { buf.removeFirst(pos); pos = 0 }
        let n = scratch.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if n == 0 { sawEOF = true }
        guard n > 0 else { return false }
        buf.append(contentsOf: scratch[0..<n])
        return true
    }

    func read(_ n: Int) -> ArraySlice<UInt8>? {
        while buf.count - pos < n { guard fill() else { return nil } }
        defer { pos += n }
        return buf[pos..<(pos + n)]
    }

    func readUntil(_ sep: [UInt8], limit: Int = 1 << 20) -> [UInt8]? {
        var searched = 0   // relativo a `pos`: fill() può compattare il buffer
        while true {
            let from = pos + searched
            if buf.count - from >= sep.count {
                for i in from...(buf.count - sep.count) where buf[i] == sep[0] && Array(buf[i..<(i + sep.count)]) == sep {
                    let out = Array(buf[pos..<(i + sep.count)])
                    pos = i + sep.count
                    return out
                }
                searched = buf.count - sep.count + 1 - pos
            }
            guard buf.count - pos < limit, fill() else { return nil }
        }
    }

    func readToEOF() -> [UInt8] {
        while fill() {}
        defer { pos = buf.count }
        return Array(buf[pos...])
    }

    /// true se il server chiude la connessione entro `timeout` (scarta i dati in arrivo).
    func waitForClose(timeout: Double) -> Bool {
        setTimeout(timeout)
        let end = uptime() + timeout
        while uptime() < end {
            let n = scratch.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n == 0 { return true }
            if n < 0 { return errno == ECONNRESET }
        }
        return false
    }

    func close() {
        guard !closed else { return }
        closed = true
        // shutdown invia subito il FIN anche se un altro thread è bloccato in read().
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    /// Chiusura brusca (RST).
    func abort() {
        guard !closed else { return }
        closed = true
        var l = linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &l, socklen_t(MemoryLayout<linger>.size))
        Darwin.close(fd)
    }
}

struct Response {
    let status: Int
    let headers: [String: String]
    let body: [UInt8]
}

func parseResponse(_ all: [UInt8]) -> Response? {
    let sep: [UInt8] = [13, 10, 13, 10]
    guard all.count >= 4, let end = (0...(all.count - 4)).first(where: { Array(all[$0..<($0 + 4)]) == sep }) else { return nil }
    let lines = String(decoding: all[..<end], as: UTF8.self).components(separatedBy: "\r\n")
    let parts = lines[0].split(separator: " ")
    guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
    var headers: [String: String] = [:]
    for l in lines.dropFirst() {
        guard let c = l.firstIndex(of: ":") else { continue }
        headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
    }
    return Response(status: status, headers: headers, body: Array(all[(end + 4)...]))
}

func httpGet(_ path: String, cookie: String? = nil, language: String? = nil) -> Response? {
    guard let s = Sock() else { return nil }
    var req = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
    if let language { req += "Accept-Language: \(language)\r\n" }
    if let cookie { req += "Cookie: theme=dark; es_token=\(cookie)\r\n" }
    req += "\r\n"
    guard s.write(req) else { return nil }
    return parseResponse(s.readToEOF())
}

// MARK: - WebSocket client

final class WSClient {
    let sock: Sock

    private init(sock: Sock) { self.sock = sock }

    /// (status HTTP, client se 101).
    static func open(_ path: String, cookie: String?, rcvbuf: Int32? = nil, timeout: Double = 5) -> (Int, WSClient?) {
        guard let s = Sock(rcvbuf: rcvbuf, timeout: timeout) else { return (0, nil) }
        var req = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        req += "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
        if let cookie { req += "Cookie: es_token=\(cookie)\r\n" }
        req += "\r\n"
        guard s.write(req), let head = s.readUntil([13, 10, 13, 10]), let r = parseResponse(head) else { return (0, nil) }
        guard r.status == 101 else { return (r.status, nil) }
        if r.headers["sec-websocket-accept"] != "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" { return (-1, nil) }
        return (101, WSClient(sock: s))
    }

    static func frame(opcode: UInt8, payload: [UInt8], fin: Bool = true) -> [UInt8] {
        var f: [UInt8] = [(fin ? 0x80 : 0) | opcode]
        let n = payload.count
        if n < 126 {
            f.append(0x80 | UInt8(n))
        } else if n <= 0xFFFF {
            f += [0x80 | 126, UInt8(n >> 8), UInt8(n & 0xFF)]
        } else {
            f.append(0x80 | 127)
            for i in (0..<8).reversed() { f.append(UInt8((UInt64(n) >> (UInt64(i) * 8)) & 0xFF)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        f += mask
        f += payload.enumerated().map { $0.element ^ mask[$0.offset & 3] }
        return f
    }

    @discardableResult
    func send(opcode: UInt8, _ payload: [UInt8], fin: Bool = true) -> Bool {
        sock.write(Self.frame(opcode: opcode, payload: payload, fin: fin))
    }

    @discardableResult
    func send(json: [String: Any]) -> Bool {
        send(opcode: 1, Array(try! JSONSerialization.data(withJSONObject: json)))
    }

    /// Frame del server (mai mascherati).
    func readFrame() -> (opcode: UInt8, payload: ArraySlice<UInt8>)? {
        guard let h = sock.read(2) else { return nil }
        let b0 = h[h.startIndex], b1 = h[h.startIndex + 1]
        var len = Int(b1 & 0x7F)
        if len == 126 {
            guard let e = sock.read(2) else { return nil }
            len = Int(e[e.startIndex]) << 8 | Int(e[e.startIndex + 1])
        } else if len == 127 {
            guard let e = sock.read(8) else { return nil }
            len = e.reduce(0) { $0 << 8 | Int($1) }
        }
        guard let p = sock.read(len) else { return nil }
        return (b0 & 0x0F, p)
    }
}

// MARK: - Validazione fMP4

func u32(_ b: ArraySlice<UInt8>, _ at: Int) -> UInt32 {
    let i = b.startIndex + at
    return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
}

func u64(_ b: ArraySlice<UInt8>, _ at: Int) -> UInt64 { UInt64(u32(b, at)) << 32 | UInt64(u32(b, at + 4)) }

func boxes(_ b: ArraySlice<UInt8>) -> [(type: String, body: ArraySlice<UInt8>)]? {
    var out: [(String, ArraySlice<UInt8>)] = []
    var i = 0
    while i < b.count {
        guard b.count - i >= 8 else { return nil }
        let size = Int(u32(b, i))
        guard size >= 8, i + size <= b.count else { return nil }
        let s = b.startIndex + i
        out.append((String(decoding: b[(s + 4)..<(s + 8)], as: UTF8.self), b[(s + 8)..<(s + size)]))
        i += size
    }
    return out
}

struct MediaInfo {
    let sequence: UInt32
    let decodeTime: UInt64
    let duration: UInt32
    let isKey: Bool
}

func parseMedia(_ seg: ArraySlice<UInt8>) -> MediaInfo? {
    guard let top = boxes(seg), top.count == 2, top[0].type == "moof", top[1].type == "mdat",
          let moof = boxes(top[0].body), moof.count == 2, moof[0].type == "mfhd", moof[1].type == "traf",
          let traf = boxes(moof[1].body), traf.map(\.type) == ["tfhd", "tfdt", "trun"]
    else { return nil }
    let trun = traf[2].body
    guard trun.count >= 24, u32(trun, 0) & 0xFFFFFF == 0x000701, u32(trun, 4) == 1 else { return nil }
    let moofSize = top[0].body.count + 8
    let mdat = top[1].body
    guard Int(u32(trun, 8)) == moofSize + 8, Int(u32(trun, 16)) == mdat.count, mdat.count >= 5 else { return nil }
    // Primo NAL: lunghezza AVCC plausibile.
    guard Int(u32(mdat, 0)) + 4 <= mdat.count else { return nil }
    let tfdt = traf[1].body
    guard tfdt.first == 1 else { return nil }
    return MediaInfo(sequence: u32(moof[0].body, 4), decodeTime: u64(tfdt, 4), duration: u32(trun, 12),
                     isKey: u32(trun, 20) == 0x0200_0000)
}

func validInit(_ seg: ArraySlice<UInt8>) -> Bool {
    guard let top = boxes(seg), top.map(\.type) == ["ftyp", "moov"] else { return false }
    let s = Array(seg)
    return s.indices.dropLast(4).contains { s[$0] == 0x61 && s[$0 + 1] == 0x76 && s[$0 + 2] == 0x63 && s[$0 + 3] == 0x43 } // avcC
}

// MARK: - TestViewer

final class TestViewer {
    struct Event { let t: Double; let key: Bool; let size: Int }

    let name: String
    let ws: WSClient
    private let lock = NSLock()
    private(set) var inits: [(w: Int, h: Int)] = []
    private(set) var events: [Event] = []
    private(set) var errors: [String] = []
    private(set) var pongs: [String] = []
    private(set) var infos: [Bool] = []
    private(set) var identifies = 0
    private(set) var reloads = 0
    private(set) var ended = false
    private var expectInit = false
    private var lastSeq: UInt32 = 0
    private var nextDecode: UInt64 = 0
    var record: FileHandle?
    var recordLimit = 0

    init(name: String, ws: WSClient) {
        self.name = name
        self.ws = ws
    }

    static func connect(_ name: String, channel: Int, cookie: String, mse: Bool = true, rcvbuf: Int32? = nil,
                        autostart: Bool = true) -> TestViewer? {
        let (status, ws) = WSClient.open("/ws/\(channel)", cookie: cookie, rcvbuf: rcvbuf)
        guard let ws else { report.check(false, "\(name): handshake WebSocket fallito (HTTP \(status))"); return nil }
        let v = TestViewer(name: name, ws: ws)
        ws.send(json: ["t": "hello", "mse": mse])
        if autostart { v.start() }
        return v
    }

    var segments: Int { lock.lock(); defer { lock.unlock() }; return events.count }

    /// Chiude la registrazione sotto il lock: il thread del client potrebbe star scrivendo.
    func stopRecording() {
        lock.lock(); defer { lock.unlock() }
        try? record?.close()
        record = nil
    }
    var isEnded: Bool { lock.lock(); defer { lock.unlock() }; return ended }

    func snapshot() -> [Event] { lock.lock(); defer { lock.unlock() }; return events }

    func start() {
        let t = Thread { [self] in
            ws.sock.setTimeout(30)
            while let (op, payload) = ws.readFrame() {
                handle(op, payload)
                if op == 8 { break }
            }
            lock.lock(); ended = true; lock.unlock()
        }
        t.stackSize = 1 << 20
        t.start()
    }

    private func fail(_ m: String) {
        if errors.count < 5 { errors.append(m) }
    }

    private func handle(_ op: UInt8, _ payload: ArraySlice<UInt8>) {
        lock.lock(); defer { lock.unlock() }
        switch op {
        case 1:
            guard let m = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any] else { return fail("JSON non valido") }
            switch m["t"] as? String {
            case "init":
                inits.append((m["w"] as? Int ?? 0, m["h"] as? Int ?? 0))
                expectInit = true
            case "info": infos.append(m["control"] as? Bool ?? false)
            case "identify": identifies += 1
            case "reload": reloads += 1
            default: break
            }
        case 2:
            if expectInit {
                expectInit = false
                if !validInit(payload) { fail("init segment non valido") }
                lastSeq = 0
                nextDecode = 0
                if let record { record.write(Data(payload)) }
                return
            }
            guard !inits.isEmpty else { return fail("media segment prima dell'init") }
            guard let m = parseMedia(payload) else { return fail("media segment malformato (\(payload.count) byte)") }
            if m.sequence != lastSeq + 1 { fail("sequenza \(m.sequence) dopo \(lastSeq)") }
            if m.decodeTime != nextDecode { fail("decodeTime \(m.decodeTime), atteso \(nextDecode)") }
            if lastSeq == 0 && !m.isKey { fail("il primo segmento dopo l'init non è un keyframe") }
            lastSeq = m.sequence
            nextDecode = m.decodeTime + UInt64(m.duration)
            events.append(Event(t: uptime(), key: m.isKey, size: payload.count))
            if let record, recordLimit > 0 {
                record.write(Data(payload))
                recordLimit -= 1
                if recordLimit == 0 { try? record.close(); self.record = nil }
            }
        case 0xA:
            pongs.append(String(decoding: payload, as: UTF8.self))
        default:
            break
        }
    }
}

func stats(_ events: [TestViewer.Event], from: Double, to: Double) -> (n: Int, keys: Int, bytes: Int) {
    let e = events.filter { $0.t >= from && $0.t < to }
    return (e.count, e.filter(\.key).count, e.reduce(0) { $0 + $1.size })
}

// MARK: - Sorgente di frame sintetici

final class Producer {
    let hub: StreamHub
    private(set) var width: Int
    private(set) var height: Int
    let fps: Int
    private var pool: CVPixelBufferPool?
    private var n = 0
    private let queue = DispatchQueue(label: "producer", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var pushes: [Double] = []

    init(hub: StreamHub, width: Int, height: Int, fps: Int) {
        self.hub = hub
        self.width = width
        self.height = height
        self.fps = fps
    }

    var pushTimes: [Double] { lock.lock(); defer { lock.unlock() }; return pushes }

    func resize(width w: Int, height h: Int) {
        queue.sync { width = w; height = h; pool = nil }
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(fps), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.pushOne() }
        t.resume()
        timer = t
    }

    func stop() {
        queue.sync { timer?.cancel(); timer = nil }
    }

    func pushOne() {
        if pool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        var out: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let pb = out else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        // Sfumatura che scorre (movimento) + un blocco di rumore (dettaglio che cambia sempre).
        for row in 0..<height { memset(y + row * ys, Int32(16 + (row + n * 6) % 220), width) }
        for row in 0..<min(160, height - 40) { arc4random_buf(y + (row + 40) * ys + 40, min(160, width - 40)) }
        let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let uvs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for row in 0..<(height / 2) { memset(uv + row * uvs, 128, width) }
        CVPixelBufferUnlockBaseAddress(pb, [])
        n += 1
        lock.lock(); pushes.append(uptime()); lock.unlock()
        hub.push(pb)
    }
}

/// nil se ffmpeg decodifica il file senza errori (o se ffmpeg non c'è), altrimenti l'errore.
func ffmpegErrors(_ path: String) -> String? {
    guard let tool = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: FileManager.default.fileExists) else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = ["-v", "error", "-i", path, "-f", "null", "-"]
    let pipe = Pipe()
    p.standardError = pipe
    p.standardOutput = FileHandle.nullDevice
    try? p.run()
    let err = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return p.terminationStatus == 0 && err.isEmpty ? nil : String(err.prefix(400))
}

func startRecording(_ v: TestViewer, _ name: String, limit: Int) -> String {
    let path = "\(outDir)/\(name).mp4"
    FileManager.default.createFile(atPath: path, contents: nil)
    v.record = FileHandle(forWritingAtPath: path)
    v.recordLimit = limit
    return path
}

// MARK: - Server sotto test

H264Encoder.warmUp()   // come fa l'app all'avvio
let suite = "com.massimopozzi.everywherescreen.stress"
UserDefaults.standard.removePersistentDomain(forName: suite)
let web = WebApp(pairing: PairingManager(defaults: UserDefaults(suiteName: suite)!))
web.touchIcon = Data(repeating: 0x89, count: 5000)

let codeLock = NSLock()
var pairingCodes: [String: String] = [:]
web.pairing.onShowRequest = { r in codeLock.lock(); pairingCodes[r.id] = r.code; codeLock.unlock() }

let inputCount = Counter(), fitCount = Counter()
var viewerCounts: [Int: Counter] = [:]
var hubs: [Int: StreamHub] = [:]
for ch in 1...3 {
    let hub = StreamHub(channel: ch, queue: web.queue)
    hub.configure(quality: 0.7, fps: ch == 1 ? 60 : 30)
    let c = Counter()
    viewerCounts[ch] = c
    hub.onViewersChanged = { c.set($0) }
    hub.onInput = { _, _ in inputCount.add() }
    hub.onFit = { _, _ in fitCount.add() }
    web.register(hub)
    hubs[ch] = hub
}
if liveToken == nil {
    try! web.start(port: port)
    _ = waitUntil(3) { httpGet("/") != nil }
}

// MARK: - Scenari

func pair(name: String) -> String? {
    guard let r = httpGet("/api/pair/start?name=\(name)"),
          let j = try? JSONSerialization.jsonObject(with: Data(r.body)) as? [String: Any], let id = j["id"] as? String
    else { return nil }
    var code: String?
    _ = waitUntil(2) { codeLock.lock(); code = pairingCodes[id]; codeLock.unlock(); return code != nil }
    guard let code, let ok = httpGet("/api/pair/confirm?id=\(id)&code=\(code)"), ok.status == 200,
          let cookie = ok.headers["set-cookie"], let token = cookie.split(separator: ";").first?.split(separator: "=", maxSplits: 1).last
    else { return nil }
    return String(token)
}

func scenarioPairing() -> String {
    section("Abbinamento")
    report.check(httpGet("/api/me")?.status == 401, "/api/me senza token deve dare 401")

    guard let r = httpGet("/api/pair/start?name=Stress%20iPad"),
          let j = try? JSONSerialization.jsonObject(with: Data(r.body)) as? [String: Any], let id = j["id"] as? String
    else { report.check(false, "pair/start fallito"); exit(1) }
    report.check(httpGet("/api/pair/start?name=x")?.status == 429, "seconda richiesta immediata dallo stesso host: attesi 429")
    var code: String?
    _ = waitUntil(2) { codeLock.lock(); code = pairingCodes[id]; codeLock.unlock(); return code != nil }
    guard let code else { report.check(false, "codice non mostrato sul Mac"); exit(1) }
    let wrong = code == "000000" ? "111111" : "000000"
    for i in 1...4 {
        let w = httpGet("/api/pair/confirm?id=\(id)&code=\(wrong)")
        report.check(w?.status == 403, "tentativo errato \(i): attesi 403, ottenuto \(w?.status ?? 0)")
    }
    guard let ok = httpGet("/api/pair/confirm?id=\(id)&code=\(code.prefix(3))%20\(code.suffix(3))"), ok.status == 200,
          let cookie = ok.headers["set-cookie"], cookie.contains("HttpOnly"),
          let token = cookie.split(separator: ";").first?.split(separator: "=", maxSplits: 1).last.map(String.init)
    else { report.check(false, "conferma con codice giusto fallita"); exit(1) }
    let me = httpGet("/api/me", cookie: token)
    report.check(me?.status == 200 && String(decoding: me?.body ?? [], as: UTF8.self).contains("\"control\":true"), "/api/me con token")
    report.check(httpGet("/api/pair/confirm?id=\(id)&code=\(code)")?.status == 410, "richiesta già usata: attesi 410")

    // Blocco dopo 5 tentativi errati.
    sleep(3)
    if let r2 = httpGet("/api/pair/start?name=Bruteforce"),
       let j2 = try? JSONSerialization.jsonObject(with: Data(r2.body)) as? [String: Any], let id2 = j2["id"] as? String {
        var c2: String?
        _ = waitUntil(2) { codeLock.lock(); c2 = pairingCodes[id2]; codeLock.unlock(); return c2 != nil }
        var statuses: [Int] = []
        for _ in 1...5 { statuses.append(httpGet("/api/pair/confirm?id=\(id2)&code=\(c2 == "123456" ? "654321" : "123456")")?.status ?? 0) }
        report.check(statuses == [403, 403, 403, 403, 410], "5 tentativi errati: attesi 4×403 e 410, ottenuto \(statuses)")
        report.check(httpGet("/api/pair/confirm?id=\(id2)&code=\(c2 ?? "")")?.status == 410, "dopo il blocco anche il codice giusto deve dare 410")
    } else {
        report.check(false, "seconda richiesta di abbinamento fallita")
    }
    info("abbinamento OK, token ricevuto")
    return token
}

func info(_ s: String) { print("   · \(s)") }

func scenarioHTTPFlood(token: String) {
    section("Flood HTTP: 48 client × 250 richieste")
    let cases: [(String, String?, Int)] = [
        ("/", nil, 200), ("/1", nil, 200), ("/2", token, 200), ("/7", nil, 404), ("/api/me", nil, 401),
        ("/api/me", token, 200), ("/apple-touch-icon.png", nil, 200), ("/ws/1", token, 404), ("/stream/1", nil, 401),
        ("/api/nope", token, 404), ("/1?x=%zz&y", nil, 200),
    ]
    let lock = NSLock()
    var latencies: [Double] = []
    let errors = Counter(), wrong = Counter()
    let start = uptime()
    parallel(48) { i in
        var local: [Double] = []
        for k in 0..<250 {
            let (path, cookie, expected) = cases[(i * 7 + k) % cases.count]
            let t0 = uptime()
            guard let r = httpGet(path, cookie: cookie) else { errors.add(); continue }
            local.append(uptime() - t0)
            if r.status != expected { wrong.add() }
        }
        lock.lock(); latencies += local; lock.unlock()
    }
    let elapsed = uptime() - start
    report.check(errors.value == 0, "\(errors.value) richieste senza risposta")
    report.check(wrong.value == 0, "\(wrong.value) risposte con stato inatteso")
    report.metric("HTTP richieste/s", String(format: "%.0f", Double(latencies.count) / elapsed))
    report.metric("HTTP latenza p50 / p99", "\(ms(percentile(latencies, 0.5))) / \(ms(percentile(latencies, 0.99)))")
}

func scenarioMalformed(token: String) {
    section("Richieste malformate e fuzz")
    var fixed: [[UInt8]] = [
        Array("\r\n\r\n".utf8),
        Array("GARBAGE\r\n\r\n".utf8),
        Array("GET\r\n\r\n".utf8),
        Array("GET / HTTP/1.1\r\nNoColonHeader\r\n: empty\r\n\r\n".utf8),
        Array("GET /%%%/..//?a=%zz&&=&b HTTP/1.1\r\n\r\n".utf8),
        Array("GET /ws/1 HTTP/1.1\r\nUpgrade: websocket\r\n\r\n".utf8),
        Array("GET /ws/99 HTTP/1.1\r\nUpgrade: websocket\r\nSec-WebSocket-Key: x\r\nCookie: es_token=\(token)\r\n\r\n".utf8),
        Array("GET /ws/1 HTTP/1.1\r\nUpgrade: websocket\r\nSec-WebSocket-Key: x\r\nCookie: es_token=bogus\r\n\r\n".utf8),
        Array("GET /api/pair/confirm?id=&code= HTTP/1.1\r\n\r\n".utf8),
        Array("GET /\u{1F600}/é HTTP/1.1\r\nCookie: ;;;=;es_token\r\n\r\n".utf8),
        [0xFF, 0xFE, 0x00, 13, 10, 13, 10],
    ]
    fixed.append(Array("GET / HTTP/1.1\r\nX: ".utf8) + [UInt8](repeating: 65, count: 70_000))   // header oltre 64 KB
    var hung = 0
    for payload in fixed {
        guard let s = Sock(timeout: 3) else { hung += 1; continue }
        s.write(payload)
        if !s.waitForClose(timeout: 3) { hung += 1 }
    }
    report.check(hung == 0, "\(hung) richieste malformate complete lasciate aperte dal server")

    // Fuzz: righe e header casuali con terminatore, e spazzatura binaria chiusa subito.
    let alphabet = Array("GETPOST /?&=%+:;\r\nabc123/\\\"'<>é😀\t".unicodeScalars.map(String.init).joined().utf8)
    let noResponse = Counter()
    parallel(16) { i in
        for _ in 0..<120 {
            guard let s = Sock(timeout: 3) else { noResponse.add(); continue }
            if Bool.random() {
                var junk = (0..<Int.random(in: 1...600)).map { _ in alphabet.randomElement()! }
                junk += [13, 10, 13, 10]
                s.write(junk)
                if !s.waitForClose(timeout: 3) { noResponse.add() }
            } else {
                s.write((0..<Int.random(in: 1...4096)).map { _ in UInt8.random(in: 0...255) })
                if Bool.random() { s.abort() } else { s.close() }
            }
        }
    }
    report.check(noResponse.value == 0, "\(noResponse.value) connessioni fuzz senza risposta/chiusura")
    // Connessioni aperte e chiuse subito.
    parallel(8) { _ in for _ in 0..<150 { Sock()?.abort() } }
    report.check(httpGet("/")?.status == 200, "server non risponde dopo il fuzz")
    info("fuzz completato, server ancora attivo")
}

func scenarioSlowloris() {
    section("Slowloris: 400 connessioni con header incompleti")
    let fds0 = openFDs()
    var socks: [Sock] = []
    for _ in 0..<400 {
        guard let s = Sock(timeout: 20) else { continue }
        s.write("GET / HTTP/1.1\r\nHost: x\r\n")
        socks.append(s)
    }
    var lat: [Double] = []
    for _ in 0..<50 {
        let t0 = uptime()
        if httpGet("/1")?.status == 200 { lat.append(uptime() - t0) }
    }
    report.check(lat.count == 50, "richieste normali fallite durante lo slowloris: \(50 - lat.count)")
    report.metric("latenza p99 durante slowloris", ms(percentile(lat, 0.99)))
    let closed = Counter()
    sleep(16)
    parallel(20) { i in
        for s in socks[(i * 20)..<min(socks.count, i * 20 + 20)] where s.waitForClose(timeout: 0.05) { closed.add() }
    }
    report.check(closed.value == socks.count, "il server tiene aperte \(socks.count - closed.value)/\(socks.count) connessioni inattive (header mai completati)")
    socks.forEach { $0.close() }
    _ = waitUntil(3) { openFDs() <= fds0 + 5 }
    report.metric("descrittori aperti prima/dopo", "\(fds0)/\(openFDs())")
}

func scenarioAuth(token: String) {
    section("Autorizzazione WebSocket / MJPEG")
    report.check(WSClient.open("/ws/1", cookie: nil).0 == 401, "WS senza token: attesi 401")
    report.check(WSClient.open("/ws/1", cookie: "bogus").0 == 401, "WS con token falso: attesi 401")
    report.check(WSClient.open("/ws/9", cookie: token).0 == 404, "WS canale inesistente: attesi 404")
    report.check(httpGet("/stream/1", cookie: "bogus")?.status == 401, "MJPEG con token falso: attesi 401")
}

/// Stream di più viewer con validazione del formato, client lento, churn.
func scenarioStreaming(token: String) {
    section("Streaming H.264: 8 viewer a 60 fps (2160×1620) + 4 viewer a 30 fps (1620×2160)")
    let p1 = Producer(hub: hubs[1]!, width: 2160, height: 1620, fps: 60)
    let p2 = Producer(hub: hubs[2]!, width: 1620, height: 2160, fps: 30)
    let rss0 = rssMB(), cpu0 = cpuSeconds()
    let v1 = (0..<8).compactMap { TestViewer.connect("ch1-v\($0)", channel: 1, cookie: token) }
    let v2 = (0..<4).compactMap { TestViewer.connect("ch2-v\($0)", channel: 2, cookie: token) }
    let recordPath = startRecording(v1[0], "ch1", limit: 300)
    p1.start(); p2.start()

    let t0 = uptime()
    sleep(8)
    let t1 = uptime()
    let cpu1 = cpuSeconds()
    for v in v1 + v2 {
        report.check(v.inits.count == 1, "\(v.name): init ricevuti \(v.inits.count)")
        report.check(v.errors.isEmpty, "\(v.name): \(v.errors)")
    }
    let fps1 = v1.map { Double(stats($0.snapshot(), from: t0 + 2, to: t1).n) / (t1 - t0 - 2) }
    let fps2 = v2.map { Double(stats($0.snapshot(), from: t0 + 2, to: t1).n) / (t1 - t0 - 2) }
    report.check((fps1.min() ?? 0) > 50, "ch1: fps minimo per viewer \(fps1.min() ?? 0) (attesi ≥ 50 su 60)")
    report.check((fps2.min() ?? 0) > 25, "ch2: fps minimo per viewer \(fps2.min() ?? 0) (attesi ≥ 25 su 30)")
    let s0 = stats(v1[0].snapshot(), from: t0 + 2, to: t1)
    report.metric("ch1 fps per viewer (min/max)", String(format: "%.1f / %.1f", fps1.min() ?? 0, fps1.max() ?? 0))
    report.metric("ch2 fps per viewer (min/max)", String(format: "%.1f / %.1f", fps2.min() ?? 0, fps2.max() ?? 0))
    report.metric("ch1 bitrate per viewer", String(format: "%.1f Mbit/s", Double(s0.bytes) * 8 / (t1 - t0 - 2) / 1e6))
    report.metric("CPU processo (server+encoder+client+generatore)", String(format: "%.0f%%", (cpu1 - cpu0) / (t1 - t0) * 100))
    report.check(viewerCounts[1]!.value == 8 && viewerCounts[2]!.value == 4, "conteggio viewer: ch1=\(viewerCounts[1]!.value) ch2=\(viewerCounts[2]!.value)")

    // --- Client lento (non legge) ---
    section("Client lento: un viewer smette di leggere per 8 s")
    let before = v1.dropFirst().map { stats($0.snapshot(), from: uptime() - 4, to: uptime()) }
    let keyBefore = Double(before.reduce(0) { $0 + $1.keys }) / Double(max(1, before.reduce(0) { $0 + $1.n }))
    guard let slow = TestViewer.connect("lento", channel: 1, cookie: token, rcvbuf: 4096, autostart: false) else { return }
    let slowPath = startRecording(slow, "lento", limit: 1_000_000)
    let rssStall0 = rssMB()
    let ts = uptime()
    sleep(8)
    let te = uptime()
    let during = v1.dropFirst().map { stats($0.snapshot(), from: ts + 2, to: te) }
    let keyDuring = Double(during.reduce(0) { $0 + $1.keys }) / Double(max(1, during.reduce(0) { $0 + $1.n }))
    let fpsDuring = during.map { Double($0.n) / (te - ts - 2) }
    let mbitDuring = Double(during.reduce(0) { $0 + $1.bytes }) / Double(during.count) * 8 / (te - ts - 2) / 1e6
    report.metric("keyframe sui viewer sani prima / durante lo stallo", String(format: "%.1f%% / %.1f%%", keyBefore * 100, keyDuring * 100))
    report.metric("bitrate viewer sani durante lo stallo", String(format: "%.1f Mbit/s", mbitDuring))
    report.metric("memoria durante lo stallo", String(format: "%+.1f MB", rssMB() - rssStall0))
    report.check(keyDuring < 0.1, String(format: "un client lento fa diventare keyframe il %.0f%% dei frame degli altri viewer", keyDuring * 100))
    report.check((fpsDuring.min() ?? 0) > 50, "viewer sani rallentati dal client lento: \(fpsDuring.min() ?? 0) fps")
    report.check(rssMB() - rssStall0 < 60, "memoria cresciuta di \(rssMB() - rssStall0) MB durante lo stallo")

    // Riprende a leggere: deve ripartire da un keyframe (lo stream registrato si deve decodificare).
    slow.start()
    let resumed = uptime()
    sleep(3)
    let after = stats(slow.snapshot(), from: uptime() - 1.5, to: uptime())
    report.check(after.n > 60, "client lento dopo la ripresa: \(after.n) frame in 1,5 s")
    report.check(slow.errors.isEmpty, "client lento: \(slow.errors)")
    report.metric("client lento: keyframe ricevuti dopo la ripresa", "\(slow.snapshot().filter { $0.t > resumed && $0.key }.count)")
    slow.stopRecording()
    if let err = ffmpegErrors(slowPath) { report.check(false, "stream del client lento non decodificabile: \(err)") }
    else { info("ffmpeg decodifica senza errori lo stream del client lento (salto + ripresa)") }

    // Client morto: non legge più. Il server deve chiuderlo invece di tenerlo in stallo per sempre.
    section("Client morto: un viewer non legge mai")
    guard let dead = TestViewer.connect("morto", channel: 1, cookie: token, rcvbuf: 4096, autostart: false) else { return }
    let deadCount = viewerCounts[1]!.value
    let droppped = waitUntil(25) { viewerCounts[1]!.value < deadCount }
    report.check(droppped, "il server non chiude un client che non legge da 25 s")
    dead.ws.sock.close()
    _ = waitUntil(5) { viewerCounts[1]!.value == 9 }

    // --- Churn ---
    section("Churn: 320 connessioni WebSocket aperte e chiuse in modi diversi")
    let baseline = 9   // 8 viewer + quello lento
    let rssChurn0 = rssMB()
    parallel(8) { i in
        for k in 0..<40 {
            switch (i + k) % 6 {
            case 0:
                WSClient.open("/ws/1", cookie: token).1?.sock.abort()
            case 1:
                if let v = TestViewer.connect("c", channel: 1, cookie: token, autostart: false) {
                    _ = v.ws.readFrame(); _ = v.ws.readFrame()
                    v.ws.send(opcode: 8, [3, 232]); v.ws.sock.close()
                }
            case 2:
                if let v = TestViewer.connect("c", channel: 1, cookie: token, autostart: false) { usleep(30_000); v.ws.sock.abort() }
            case 3:
                if let s = Sock() { s.write("GET /ws/1 HTTP/1.1\r\nUpgrade: web"); s.abort() }
            case 4:
                // Frame con lunghezza enorme: il server deve chiudere.
                if let ws = WSClient.open("/ws/1", cookie: token).1 {
                    ws.sock.write([0x81, 0xFF, 0, 0, 0, 1, 0, 0, 0, 0, 1, 2, 3, 4])
                    if !ws.sock.waitForClose(timeout: 3) { report.check(false, "frame da 4 GB non rifiutato") }
                }
            default:
                if let v = TestViewer.connect("c", channel: 1, cookie: token, mse: false, autostart: false) { v.ws.sock.close() }
            }
        }
    }
    let settled = waitUntil(5) { viewerCounts[1]!.value == baseline }
    report.check(settled, "dopo il churn ch1 ha \(viewerCounts[1]!.value) viewer, attesi \(baseline)")
    report.metric("memoria dopo il churn", String(format: "%+.1f MB", rssMB() - rssChurn0))
    for v in v1 { report.check(!v.isEnded && v.errors.isEmpty, "\(v.name) disturbato dal churn: \(v.errors)") }

    // --- Cambio risoluzione (rotazione del tablet) ---
    section("Rotazione: ch2 passa da 1620×2160 a 2160×1620")
    p2.resize(width: 2160, height: 1620)
    let rotated = waitUntil(3) { v2.allSatisfy { $0.inits.last.map { $0 == (2160, 1620) } ?? false } }
    report.check(rotated, "i viewer di ch2 non ricevono il nuovo init 2160×1620: \(v2.map { $0.inits.map { "\($0.w)×\($0.h)" } })")
    sleep(1)
    for v in v2 { report.check(v.errors.isEmpty, "\(v.name) dopo la rotazione: \(v.errors)") }

    // --- MJPEG ---
    section("MJPEG: 3 client su ch2")
    let jpegCounts = (0..<3).map { _ in Counter() }
    let jpegErrors = Counter()
    parallel(3) { i in
        guard let s = Sock(timeout: 5) else { return jpegErrors.add() }
        s.write("GET /stream/2 HTTP/1.1\r\nCookie: es_token=\(token)\r\n\r\n")
        guard let head = s.readUntil([13, 10, 13, 10]), parseResponse(head)?.status == 200 else { return jpegErrors.add() }
        let end = uptime() + 3
        while uptime() < end {
            guard let part = s.readUntil([13, 10, 13, 10]),
                  let len = String(decoding: part, as: UTF8.self).components(separatedBy: "\r\n")
                      .first(where: { $0.hasPrefix("Content-Length:") }).flatMap({ Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) }),
                  let jpeg = s.read(len + 2)
            else { jpegErrors.add(); break }
            let j = Array(jpeg)
            if j.count > 4, j[0] == 0xFF, j[1] == 0xD8, j[len - 2] == 0xFF, j[len - 1] == 0xD9 { jpegCounts[i].add() } else {
                if jpegErrors.value < 3 { print("     JPEG non valido: \(len) byte, inizio \(j.prefix(4)), fine \(j.suffix(4))") }
                jpegErrors.add()
            }
        }
        s.close()
    }
    report.check(jpegErrors.value == 0, "\(jpegErrors.value) errori MJPEG")
    report.check(jpegCounts.allSatisfy { $0.value > 30 }, "MJPEG: frame in 3 s \(jpegCounts.map(\.value))")
    report.metric("MJPEG fps per client", jpegCounts.map { String(format: "%.0f", Double($0.value) / 3) }.joined(separator: ", "))
    for v in v2 { report.check(v.errors.isEmpty, "\(v.name) con MJPEG attivo: \(v.errors)") }

    p1.stop(); p2.stop()
    report.metric("memoria totale dopo lo streaming", String(format: "%+.1f MB", rssMB() - rss0))
    for v in v1 + v2 + [slow] { v.ws.sock.close() }
    _ = waitUntil(3) { viewerCounts[1]!.value == 0 && viewerCounts[2]!.value == 0 }
    report.check(viewerCounts[1]!.value == 0 && viewerCounts[2]!.value == 0, "viewer rimasti dopo la chiusura: ch1=\(viewerCounts[1]!.value) ch2=\(viewerCounts[2]!.value)")

    // Il file registrato deve essere decodificabile da ffmpeg.
    v1.first?.stopRecording()
    if let err = ffmpegErrors(recordPath) { report.check(false, "ffmpeg non decodifica lo stream registrato: \(err)") }
    else { info("ffmpeg decodifica senza errori 300 frame dello stream registrato") }
}

func scenarioLatency(token: String) {
    section("Latenza frame → client (1280×800, un frame ogni 150 ms)")
    let p = Producer(hub: hubs[3]!, width: 1280, height: 800, fps: 1)
    guard let v = TestViewer.connect("latenza", channel: 3, cookie: token) else { return }
    usleep(200_000)
    // Il primo frame crea la sessione VideoToolbox: si misura a parte.
    let first = uptime()
    p.pushOne()
    _ = waitUntil(3) { v.segments > 0 }
    report.metric("primo frame a un nuovo viewer (creazione encoder)", ms(uptime() - first))
    usleep(300_000)
    let warm = v.segments
    for _ in 0..<40 { p.pushOne(); usleep(150_000) }
    usleep(300_000)
    let pushes = p.pushTimes, events = Array(v.snapshot().dropFirst(warm))
    report.check(events.count == 40, "segmenti ricevuti \(events.count) su 40 frame")
    let lat = events.map { e in e.t - (pushes.last { $0 <= e.t } ?? e.t) }
    report.metric("latenza encode+mux+rete p50 / p99", "\(ms(percentile(lat, 0.5))) / \(ms(percentile(lat, 0.99)))")
    report.check(percentile(lat, 0.99) < 0.05, "latenza p99 \(ms(percentile(lat, 0.99)))")
    v.ws.sock.close()
}

func scenarioInput(token: String) {
    section("Input: 13.000 messaggi, frammentati, byte per byte, ping, messaggio gigante")
    guard let v = TestViewer.connect("input", channel: 2, cookie: token) else { return }
    _ = waitUntil(2) { !v.infos.isEmpty }
    report.check(v.infos.first == true, "info.control iniziale")
    let base = inputCount.value, fitBase = fitCount.value
    var expected = 0
    let t0 = uptime()
    for i in 0..<13_000 {
        let msg: [String: Any]
        switch i % 26 {
        case 0: msg = ["t": "s", "dx": 3, "dy": -4]
        case 1: msg = ["t": "txt", "s": "ciao è 😀 \(i)"]
        case 2: msg = ["t": "k", "c": "KeyC", "m": 8]
        case 3: msg = ["t": "p", "k": "d", "x": 0.5, "y": 0.5, "b": 0, "c": 2]
        default: msg = ["t": "p", "k": "m", "x": Double(i % 100) / 100, "y": 0.5]
        }
        let data = Array(try! JSONSerialization.data(withJSONObject: msg))
        if i % 97 == 0 {
            // Tre frammenti con un ping in mezzo (i controlli possono intercalarsi).
            let a = data.count / 3
            v.ws.send(opcode: 1, Array(data[..<a]), fin: false)
            v.ws.send(opcode: 9, Array("ping-\(i)".utf8))
            v.ws.send(opcode: 0, Array(data[a..<(2 * a)]), fin: false)
            v.ws.send(opcode: 0, Array(data[(2 * a)...]))
        } else if i % 1000 == 1 {
            for b in WSClient.frame(opcode: 1, payload: data) { v.ws.sock.write([b]) }
        } else {
            v.ws.send(opcode: 1, data)
        }
        expected += 1
    }
    for _ in 0..<50 { v.ws.send(json: ["t": "fit", "w": 1080, "h": 810]) }
    v.ws.send(opcode: 1, Array("{non json".utf8))
    let done = waitUntil(10) { inputCount.value - base >= expected }
    let elapsed = uptime() - t0
    report.check(done && inputCount.value - base == expected, "input ricevuti \(inputCount.value - base) su \(expected)")
    _ = waitUntil(3) { fitCount.value - fitBase >= 50 }
    report.check(fitCount.value - fitBase == 50, "fit ricevuti \(fitCount.value - fitBase) su 50")
    let pings = (0..<13_000).filter { $0 % 97 == 0 }.count
    _ = waitUntil(2) { v.pongs.count == pings }
    report.check(v.pongs.count == pings, "pong \(v.pongs.count) su \(pings)")
    report.metric("input al secondo", String(format: "%.0f", Double(expected) / elapsed))

    // Dispositivo senza controllo: gli input vanno ignorati.
    if let device = web.pairing.devices.first {
        web.pairing.setControl(false, deviceID: device.id)
        hubs[2]!.setControl(false, deviceID: device.id)
        _ = waitUntil(2) { v.infos.last == false }
        let b = inputCount.value
        for _ in 0..<200 { v.ws.send(json: ["t": "p", "k": "m", "x": 0.1, "y": 0.1]) }
        usleep(500_000)
        report.check(inputCount.value == b, "input accettati da un dispositivo senza controllo: \(inputCount.value - b)")
        web.pairing.setControl(true, deviceID: device.id)
        hubs[2]!.setControl(true, deviceID: device.id)
    }

    // Messaggio da 2 MB: oltre il limite, il server chiude.
    v.ws.send(opcode: 1, [UInt8](repeating: 0x20, count: 2 << 20))
    report.check(waitUntil(3) { v.isEnded }, "messaggio da 2 MB non rifiutato")
}

func scenarioRevoke() {
    section("Revoca di un dispositivo con viewer collegati")
    sleep(3)   // limite di una richiesta di abbinamento ogni 3 s per host
    guard let token = pair(name: "Da%20revocare"), let device = web.pairing.devices.last else {
        return report.check(false, "abbinamento del secondo dispositivo fallito")
    }
    let p = Producer(hub: hubs[3]!, width: 1280, height: 800, fps: 30)
    p.start()
    let vs = (0..<3).compactMap { TestViewer.connect("revoca\($0)", channel: 3, cookie: token) }
    _ = waitUntil(3) { vs.allSatisfy { $0.segments > 5 } }
    web.pairing.remove(deviceID: device.id)
    web.allHubs.forEach { $0.disconnect(deviceID: device.id) }
    report.check(waitUntil(3) { vs.allSatisfy(\.isEnded) }, "viewer del dispositivo revocato ancora collegati")
    report.check(httpGet("/api/me", cookie: token)?.status == 401, "token revocato ancora valido")

    section("Rimozione di uno schermo con viewer collegati")
    sleep(3)
    guard let t2 = pair(name: "Altro") else { return report.check(false, "abbinamento fallito") }
    let vs2 = (0..<3).compactMap { TestViewer.connect("rimozione\($0)", channel: 3, cookie: t2) }
    _ = waitUntil(3) { vs2.allSatisfy { $0.segments > 3 } }
    web.unregister(channel: 3)
    hubs[3]!.closeAll()
    p.stop()
    report.check(waitUntil(3) { vs2.allSatisfy(\.isEnded) }, "viewer dello schermo rimosso ancora collegati")
    report.check(WSClient.open("/ws/3", cookie: t2).0 == 404 && httpGet("/3")?.status == 404, "schermo rimosso ancora raggiungibile")
    report.check(waitUntil(3) { viewerCounts[3]!.value == 0 }, "ch3 ha ancora \(viewerCounts[3]!.value) viewer")
}

/// Fino a 8 schermi: 8 canali Retina a 30 fps, ognuno col suo encoder e un tablet.
func scenarioEightScreens(token: String) {
    let rate = Int(ProcessInfo.processInfo.environment["EIGHT_FPS"] ?? "") ?? 30
    section("8 schermi insieme: 8 canali Retina a \(rate) fps, un tablet ciascuno + 2 in più sul primo")
    var extra: [StreamHub] = []
    var producers: [Producer] = []
    for ch in 11...18 {
        let hub = StreamHub(channel: ch, queue: web.queue)
        hub.configure(quality: 0.7, fps: rate)
        web.register(hub)
        extra.append(hub)
        producers.append(Producer(hub: hub, width: ch % 2 == 0 ? 2160 : 1620, height: ch % 2 == 0 ? 1620 : 2160, fps: rate))
    }
    let rss0 = rssMB(), cpu0 = cpuSeconds()
    var viewers = (11...18).compactMap { TestViewer.connect("s\($0)", channel: $0, cookie: token) }
    viewers += (0..<2).compactMap { TestViewer.connect("s11-extra\($0)", channel: 11, cookie: token) }
    producers.forEach { $0.start() }
    let t0 = uptime()
    sleep(8)
    let t1 = uptime()
    let fps = viewers.map { Double(stats($0.snapshot(), from: t0 + 2, to: t1).n) / (t1 - t0 - 2) }
    report.check(viewers.count == 10, "tablet collegati \(viewers.count) su 10")
    report.check((fps.min() ?? 0) >= Double(rate) * 0.9, "fps minimo con 8 schermi: \(fps.min() ?? 0) (attesi ≥ 90% di \(rate))")
    for v in viewers { report.check(v.inits.count == 1 && v.errors.isEmpty, "\(v.name): init \(v.inits.count), errori \(v.errors)") }
    report.metric("fps per tablet con 8 schermi (min/max)", String(format: "%.1f / %.1f", fps.min() ?? 0, fps.max() ?? 0))
    report.metric("CPU con 8 schermi", String(format: "%.0f%%", (cpuSeconds() - cpu0) / (t1 - t0) * 100))
    report.metric("memoria con 8 schermi", String(format: "%+.0f MB", rssMB() - rss0))
    producers.forEach { $0.stop() }
    viewers.forEach { $0.ws.sock.close() }
    for (i, hub) in extra.enumerated() { web.unregister(channel: 11 + i); hub.closeAll() }
}

func scenarioLanguage(token: String) {
    section("Lingua: pagina e messaggi secondo il browser o la scelta sul Mac")
    let saved = Language.preference
    defer { Language.preference = saved }
    Language.preference = nil
    func page(_ lang: String?) -> String { String(decoding: httpGet("/1", language: lang)?.body ?? [], as: UTF8.self) }
    let en = page("en-US,en;q=0.9"), it = page("it-IT,it;q=0.9,en;q=0.8"), de = page("de-DE,de;q=0.9")
    report.check(en.contains("<html lang=\"en\"") && en.contains(">Connect<") && en.contains("\"labelOn\":\"Control on\""), "pagina inglese per Accept-Language en")
    report.check(it.contains("<html lang=\"it\"") && it.contains(">Collega<") && it.contains("\"labelOn\":\"Controllo attivo\""), "pagina italiana per Accept-Language it")
    report.check(de.contains("<html lang=\"en\""), "lingua non supportata: attesa l'inglese")
    let italianUI = [">Collega<", "Inserisci il codice", "Tocca per", "Connessione…", "Solo schermo", "\"Tastiera\""]
    report.check(italianUI.allSatisfy { !en.contains($0) }, "testi italiani visibili nella pagina inglese: \(italianUI.filter { en.contains($0) })")
    let err = String(decoding: httpGet("/api/me", language: "en")?.body ?? [], as: UTF8.self)
    report.check(err.contains("Device not paired"), "errore API in inglese: \(err)")
    let index = String(decoding: httpGet("/", language: "en")?.body ?? [], as: UTF8.self)
    report.check(index.contains(">Screen 1<") && index.contains("Which screen"), "pagina di scelta dello schermo in inglese")

    // Scelta esplicita sul Mac: vale per tutti i tablet, qualunque sia la lingua del browser.
    Language.preference = .it
    report.check(page("en-US").contains(">Collega<"), "con l'italiano scelto sul Mac la pagina deve essere italiana")
    report.check(tr("Aggiungi schermo", "Add screen") == "Aggiungi schermo", "menu del Mac in italiano")
    Language.preference = .en
    report.check(page("it-IT").contains(">Connect<"), "con l'inglese scelto sul Mac la pagina deve essere inglese")

    // Cambio di lingua: i tablet collegati ricaricano la pagina.
    guard let v = TestViewer.connect("lingua", channel: 2, cookie: token) else { return }
    _ = waitUntil(2) { !v.infos.isEmpty }
    hubs[2]!.reloadClients()
    report.check(waitUntil(2) { v.reloads > 0 }, "il tablet non riceve la richiesta di ricaricare la pagina")
    v.ws.sock.close()
    info("pagina, errori e menu nella lingua giusta; i tablet ricaricano al cambio")
}

func scenarioPairingConcurrency() {
    section("Abbinamento concorrente: 16 thread × 400 operazioni")
    let suite2 = suite + ".concurrency"
    UserDefaults.standard.removePersistentDomain(forName: suite2)
    let pm = PairingManager(defaults: UserDefaults(suiteName: suite2)!)
    let paired = Counter(), tokens = NSMutableArray()
    let t0 = uptime()
    parallel(16) { i in
        for k in 0..<400 {
            switch k % 5 {
            case 0:
                if let r = pm.startRequest(name: "T\(i)", host: "10.0.\(i).\(k)") {
                    _ = pm.confirm(id: r.id, code: "999999x")
                    if case let .paired(token, _) = pm.confirm(id: r.id, code: r.code) {
                        paired.add()
                        objc_sync_enter(tokens); tokens.add(token); objc_sync_exit(tokens)
                    }
                }
            case 1:
                _ = pm.device(forToken: "nope\(k)")
            case 2:
                if let d = pm.devices.randomElement() { pm.setControl(Bool.random(), deviceID: d.id) }
            case 3:
                if k % 20 == 3, let d = pm.devices.randomElement() { pm.remove(deviceID: d.id) }
            default:
                _ = pm.confirm(id: "missing", code: "000000")
            }
        }
    }
    report.metric("abbinamenti concorrenti completati", "\(paired.value) in \(ms(uptime() - t0))")
    // Al massimo 3 richieste in attesa: con 16 thread alcune vengono sostituite prima della conferma.
    report.check(paired.value > 0, "nessun abbinamento riuscito")
    let ids = pm.devices.map(\.id)
    report.check(Set(ids).count == ids.count, "id dispositivo duplicati")
    let reloaded = PairingManager(defaults: UserDefaults(suiteName: suite2)!)
    report.check(reloaded.devices.count == pm.devices.count, "dispositivi salvati \(reloaded.devices.count) ≠ in memoria \(pm.devices.count)")
    UserDefaults.standard.removePersistentDomain(forName: suite2)
}

func scenarioMicro() {
    section("Micro-benchmark")
    // Muxer: 20.000 segmenti da 60 KB.
    let sps: [UInt8] = [0x67, 0x64, 0x00, 0x33, 0xAC, 0x1B], pps: [UInt8] = [0x68, 0xEE, 0x3C, 0x80]
    let frame = EncodedFrame(data: Data([0, 0, 0xEA, 0x5C] + [UInt8](repeating: 7, count: 60_000)), isKey: false,
                             sps: Data(sps), pps: Data(pps), width: 2160, height: 1620)
    var mux = FMP4Muxer(fps: 60)
    var total = 0
    var t0 = uptime()
    for _ in 0..<20_000 { total += mux.mediaSegment(for: frame).count }
    let muxTime = uptime() - t0
    report.metric("muxer fMP4 (60 KB/frame)", String(format: "%.1f µs/segmento, %.1f GB/s", muxTime / 20_000 * 1e6, Double(total) / muxTime / 1e9))
    var mux2 = FMP4Muxer(fps: 60)
    let seg = mux2.mediaSegment(for: frame)
    report.check(parseMedia(ArraySlice([UInt8](seg))) != nil, "segmento del muxer non valido")
    report.check(validInit(ArraySlice([UInt8](FMP4Muxer.initSegment(for: frame)))), "init segment del muxer non valido")

    // Parser WebSocket: 30.000 messaggi piccoli arrivati in un unico buffer.
    let msg = Array(#"{"t":"p","k":"m","x":0.5,"y":0.25}"#.utf8)
    var blob: [UInt8] = []
    for _ in 0..<30_000 { blob += WSClient.frame(opcode: 1, payload: msg) }
    let ws = WebSocket(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), initial: Data(blob))
    var parsed = 0
    ws.onText = { _ in parsed += 1 }
    t0 = uptime()
    ws.start()
    let parseTime = uptime() - t0
    ws.close()
    report.check(parsed == 30_000, "parser WebSocket: \(parsed) messaggi su 30000")
    report.metric("parser WebSocket (30.000 msg, \(blob.count / 1024) KB in un buffer)", String(format: "%.1f ms", parseTime * 1000))

    t0 = uptime()
    var chars = 0
    for i in 0..<5_000 { chars += Page.viewer(channel: i % 3 + 1, lang: .it).utf8.count }
    report.metric("pagina del tablet generata", String(format: "%.1f µs (%d KB)", (uptime() - t0) / 5_000 * 1e6, chars / 5_000 / 1024))
}

// MARK: - Main

// MARK: - App vera

func processStats(_ pid: String) -> (rssMB: Double, cpu: Double) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-o", "rss=,%cpu=", "-p", pid]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    p.waitUntilExit()
    let f = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
    return f.count == 2 ? (f[0] / 1024, f[1]) : (.nan, .nan)
}

func appPID() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-x", "EverywhereScreen"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
}

func runLive(token: String) {
    let pid = appPID()
    report.check(!pid.isEmpty, "Everywhere Screen non è in esecuzione")
    let s0 = processStats(pid)
    report.metric("app: memoria / CPU a riposo", String(format: "%.0f MB / %.1f%%", s0.rssMB, s0.cpu))

    section("App vera: pagine e autorizzazione")
    let root = httpGet("/")
    report.check(root?.status == 302 || root?.status == 200, "/ → \(root?.status ?? 0)")
    report.check(httpGet("/1")?.status == 200, "/1 non risponde 200")
    report.check(httpGet("/api/me")?.status == 401, "/api/me senza token deve dare 401")
    let me = httpGet("/api/me", cookie: token)
    report.check(me?.status == 200 && String(decoding: me?.body ?? [], as: UTF8.self).contains("\"control\":false"),
                 "/api/me del dispositivo di test (sola visione): \(me?.status ?? 0)")
    report.check(WSClient.open("/ws/1", cookie: nil).0 == 401, "WS senza token deve dare 401")

    section("App vera: 6 viewer sullo schermo 1 (cattura reale)")
    let t0 = uptime()
    let viewers = (0..<6).compactMap { TestViewer.connect("live\($0)", channel: 1, cookie: token) }
    let path = startRecording(viewers[0], "live", limit: 1000)
    let gotFrames = waitUntil(5) { viewers.allSatisfy { $0.segments > 0 } }
    report.check(gotFrames, "viewer senza immagine dopo 5 s: \(viewers.filter { $0.segments == 0 }.map(\.name))")
    report.metric("primo frame (6 viewer)", ms(uptime() - t0))
    if let first = viewers.first?.inits.first { report.metric("risoluzione stream", "\(first.w)×\(first.h)") }
    for v in viewers {
        report.check(v.inits.count == 1 && v.errors.isEmpty, "\(v.name): init \(v.inits.count), errori \(v.errors)")
        report.check(v.infos.last == false, "\(v.name): il dispositivo di sola visione riceve control=true")
    }

    section("App vera: flood HTTP, churn e slowloris con i viewer collegati")
    let errors = Counter()
    parallel(16) { _ in for k in 0..<120 { if httpGet(k % 2 == 0 ? "/1" : "/api/me", cookie: token)?.status != 200 { errors.add() } } }
    report.check(errors.value == 0, "\(errors.value) richieste fallite durante il flood")
    parallel(8) { i in
        for k in 0..<25 {
            if (i + k) % 2 == 0 { WSClient.open("/ws/1", cookie: token).1?.sock.abort() }
            else if let v = TestViewer.connect("c", channel: 1, cookie: token, autostart: false) { _ = v.ws.readFrame(); v.ws.sock.close() }
        }
    }
    var loris: [Sock] = []
    for _ in 0..<200 { if let s = Sock(timeout: 15) { s.write("GET / HTTP/1.1\r\n"); loris.append(s) } }
    report.check(httpGet("/1")?.status == 200, "l'app non risponde durante lo slowloris")
    sleep(12)
    let closed = Counter()
    parallel(10) { i in for s in loris[(i * 20)..<min(loris.count, i * 20 + 20)] where s.waitForClose(timeout: 0.05) { closed.add() } }
    report.check(closed.value == loris.count, "connessioni inattive ancora aperte: \(loris.count - closed.value)/\(loris.count)")
    loris.forEach { $0.close() }
    for v in viewers { report.check(!v.isEnded && v.errors.isEmpty, "\(v.name) disturbato: \(v.errors)") }

    section("App vera: un tablet su ogni schermo")
    let index = String(decoding: httpGet("/")?.body ?? [], as: UTF8.self)
    let channels = index.components(separatedBy: "href=\"/").dropFirst().compactMap { Int($0.prefix { $0.isNumber }) }
    report.metric("schermi attivi nell'app", channels.isEmpty ? "1" : channels.map(String.init).joined(separator: ", "))
    let perScreen = (channels.isEmpty ? [1] : channels).compactMap { TestViewer.connect("schermo\($0)", channel: $0, cookie: token) }
    let allFrames = waitUntil(8) { perScreen.allSatisfy { $0.segments > 0 } }
    report.check(allFrames, "schermi senza immagine: \(perScreen.filter { $0.segments == 0 }.map(\.name))")
    for v in perScreen {
        report.check(v.errors.isEmpty, "\(v.name): \(v.errors)")
        if let i = v.inits.first { info("\(v.name): \(i.w)×\(i.h), \(v.segments) frame") }
    }
    let busy = processStats(pid)
    report.metric("app: memoria / CPU con tutti gli schermi collegati", String(format: "%.0f MB / %.1f%%", busy.rssMB, busy.cpu))
    perScreen.forEach { $0.ws.sock.close() }

    viewers[0].stopRecording()
    if let err = ffmpegErrors(path) { report.check(false, "stream reale non decodificabile: \(err)") }
    else { info("ffmpeg decodifica senza errori lo stream reale (\(viewers[0].segments) frame)") }
    viewers.forEach { $0.ws.sock.close() }
    sleep(2)
    let s1 = processStats(pid)
    report.check(appPID() == pid, "l'app si è riavviata o è terminata durante il test")
    report.metric("app: memoria dopo il test", String(format: "%.0f MB (%+.0f MB)", s1.rssMB, s1.rssMB - s0.rssMB))
}

// Argomenti dopo la cartella: solo gli scenari indicati (es. "streaming latency").
let only = Set(args.dropFirst(2))
func run(_ name: String, _ body: () -> Void) { if only.isEmpty || only.contains(name) { body() } }

Thread {
    let wall = uptime()
    if serveMode {
        let pm = web.pairing
        let r = pm.startRequest(name: "Browser di prova", host: "serve")!
        guard case let .paired(token, _) = pm.confirm(id: r.id, code: r.code) else { exit(1) }
        hubs[1]!.onInput = { msg, _ in
            if let d = try? JSONSerialization.data(withJSONObject: msg, options: .sortedKeys) { print("INPUT " + String(decoding: d, as: UTF8.self)) }
        }
        hubs[1]!.setAutoFullscreen(args.contains("--fs"))
        web.pairing.onShowRequest = { print("CODE \($0.name): \($0.code)") }
        servedProducer = Producer(hub: hubs[1]!, width: 1620, height: 1214, fps: 30)
        servedProducer?.start()
        print("SERVE http://127.0.0.1:\(port)/1 token=\(token)")
        return
    }
    if let liveToken {
        runLive(token: liveToken)
        print(report.failures.isEmpty ? "\n✓ app vera: tutti i controlli passati" : "\n✗ \(report.failures.count) controlli falliti")
        report.failures.forEach { print("  - \($0)") }
        exit(report.failures.isEmpty ? 0 : 1)
    }
    let token = scenarioPairing()
    run("auth") { scenarioAuth(token: token) }
    run("http") { scenarioHTTPFlood(token: token) }
    run("fuzz") { scenarioMalformed(token: token) }
    run("input") { scenarioInput(token: token) }
    run("latency") { scenarioLatency(token: token) }
    run("streaming") { scenarioStreaming(token: token) }
    run("revoke") { scenarioRevoke() }
    run("screens8") { scenarioEightScreens(token: token) }
    run("lang") { scenarioLanguage(token: token) }
    run("pairing") { scenarioPairingConcurrency() }
    run("micro") { scenarioMicro() }
    run("slowloris") { scenarioSlowloris() }
    UserDefaults.standard.removePersistentDomain(forName: suite)

    print("\n══════════════════════════════════════════")
    print(String(format: "Durata: %.0f s — memoria finale %.0f MB", uptime() - wall, rssMB()))
    if report.failures.isEmpty {
        print("✓ tutti gli stress test passati")
        exit(0)
    }
    print("✗ \(report.failures.count) controlli falliti:")
    report.failures.forEach { print("  - \($0)") }
    exit(1)
}.start()

dispatchMain()

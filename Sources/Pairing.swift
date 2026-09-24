import CryptoKit
import Foundation

struct PairedDevice: Codable {
    let id: String
    var name: String
    let tokenHash: String
    var control: Bool
    let created: Date
    var lastSeen: Date
}

/// Abbinamento dei tablet: il Mac mostra un codice a 6 cifre, il tablet lo inserisce e riceve
/// un token personale. Sul Mac si conserva solo l'hash del token.
final class PairingManager {
    struct Request {
        let id: String
        let code: String
        let name: String
        let host: String
        let expires: Date
        var attempts = 0
    }

    enum ConfirmResult {
        case paired(token: String, device: PairedDevice)
        case wrongCode(remaining: Int)
        case expired
    }

    /// Chiamati sul main thread.
    var onShowRequest: ((Request) -> Void)?
    var onHideRequest: ((String) -> Void)?
    var onDevicesChanged: (() -> Void)?

    private static let maxAttempts = 5
    private static let lifetime: TimeInterval = 120
    private let lock = NSLock()
    private var requests: [String: Request] = [:]
    private var lastRequestByHost: [String: Date] = [:]
    private var devicesByHash: [String: PairedDevice] = [:]
    private let defaultsKey = "pairedDevices"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let list = try? JSONDecoder().decode([PairedDevice].self, from: data) {
            for d in list { devicesByHash[d.tokenHash] = d }
        }
    }

    // MARK: - Richieste

    /// Nil se lo stesso host ha appena fatto una richiesta (evita di inondare il Mac di pannelli).
    func startRequest(name: String, host: String) -> Request? {
        lock.lock()
        let now = Date()
        requests = requests.filter { $0.value.expires > now }
        if let last = lastRequestByHost[host], now.timeIntervalSince(last) < 3 { lock.unlock(); return nil }
        lastRequestByHost[host] = now
        // Una richiesta per host alla volta, al massimo 3 in totale.
        let replaced = requests.values.filter { $0.host == host }.map(\.id)
        replaced.forEach { requests[$0] = nil }
        if requests.count >= 3, let oldest = requests.values.min(by: { $0.expires < $1.expires }) {
            requests[oldest.id] = nil
        }
        let request = Request(id: Self.randomToken(bytes: 12),
                              code: String(format: "%06d", Int.random(in: 0..<1_000_000)),
                              name: String(name.prefix(40)),
                              host: host,
                              expires: now.addingTimeInterval(Self.lifetime))
        requests[request.id] = request
        lock.unlock()

        DispatchQueue.main.async {
            replaced.forEach { self.onHideRequest?($0) }
            self.onShowRequest?(request)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime) { self.onHideRequest?(request.id) }
        return request
    }

    func confirm(id: String, code: String) -> ConfirmResult {
        lock.lock()
        guard var request = requests[id], request.expires > Date() else {
            requests[id] = nil
            lock.unlock()
            DispatchQueue.main.async { self.onHideRequest?(id) }
            return .expired
        }
        guard code.filter(\.isNumber) == request.code else {
            request.attempts += 1
            let remaining = Self.maxAttempts - request.attempts
            if remaining <= 0 {
                requests[id] = nil
                lock.unlock()
                DispatchQueue.main.async { self.onHideRequest?(id) }
                return .expired
            }
            requests[id] = request
            lock.unlock()
            return .wrongCode(remaining: remaining)
        }
        requests[id] = nil

        let token = Self.randomToken(bytes: 32)
        let device = PairedDevice(id: Self.randomToken(bytes: 8), name: request.name, tokenHash: Self.hash(token),
                                  control: true, created: Date(), lastSeen: Date())
        devicesByHash[device.tokenHash] = device
        saveLocked()
        lock.unlock()

        DispatchQueue.main.async {
            self.onHideRequest?(id)
            self.onDevicesChanged?()
        }
        return .paired(token: token, device: device)
    }

    func cancel(id: String) {
        lock.lock(); requests[id] = nil; lock.unlock()
    }

    // MARK: - Dispositivi

    func device(forToken token: String) -> PairedDevice? {
        lock.lock(); defer { lock.unlock() }
        let h = Self.hash(token)
        guard var device = devicesByHash[h] else { return nil }
        if Date().timeIntervalSince(device.lastSeen) > 3600 {
            device.lastSeen = Date()
            devicesByHash[h] = device
            saveLocked()
        }
        return device
    }

    var devices: [PairedDevice] {
        lock.lock(); defer { lock.unlock() }
        return devicesByHash.values.sorted { $0.created < $1.created }
    }

    func setControl(_ allowed: Bool, deviceID: String) {
        update(deviceID) { $0.control = allowed }
    }

    func remove(deviceID: String) {
        lock.lock()
        devicesByHash = devicesByHash.filter { $0.value.id != deviceID }
        saveLocked()
        lock.unlock()
        DispatchQueue.main.async { self.onDevicesChanged?() }
    }

    private func update(_ deviceID: String, _ change: (inout PairedDevice) -> Void) {
        lock.lock()
        if let key = devicesByHash.first(where: { $0.value.id == deviceID })?.key {
            change(&devicesByHash[key]!)
            saveLocked()
        }
        lock.unlock()
        DispatchQueue.main.async { self.onDevicesChanged?() }
    }

    private func saveLocked() {
        if let data = try? JSONEncoder().encode(Array(devicesByHash.values)) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomToken(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

import Foundation
import Network

/// WebSocket lato server (RFC 6455) sopra una NWConnection già avviata.
/// Tutti i metodi vanno chiamati sulla coda della connessione.
final class WebSocket {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?

    /// Byte accodati e non ancora consegnati al sistema: misura quanto il client è indietro.
    private(set) var pendingBytes = 0

    private let conn: NWConnection
    private var buffer: [UInt8]
    private var message: [UInt8] = []
    private var messageOpcode: UInt8 = 0
    private var closed = false
    private static let maxMessage = 1 << 20

    init(conn: NWConnection, initial: Data) {
        self.conn = conn
        self.buffer = [UInt8](initial)
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        parse()
        receive()
    }

    func send(text: String) { send(opcode: 0x1, payload: Data(text.utf8)) }
    func send(binary: Data) { send(opcode: 0x2, payload: binary) }

    func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        send(opcode: 0x1, payload: data)
    }

    func close() {
        guard !closed else { return }
        closed = true
        conn.cancel()
        onClose?()
    }

    private func send(opcode: UInt8, payload: Data) {
        guard !closed else { return }
        var frame = Data([0x80 | opcode])
        let n = payload.count
        if n < 126 {
            frame.append(UInt8(n))
        } else if n <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(n >> 8))
            frame.append(UInt8(n & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() { frame.append(UInt8((UInt64(n) >> (UInt64(i) * 8)) & 0xFF)) }
        }
        frame.append(payload)

        let size = frame.count
        pendingBytes += size
        conn.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingBytes -= size
            if error != nil { self.close() }
        })
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data {
                self.buffer.append(contentsOf: data)
                self.parse()
            }
            if isComplete || error != nil { self.close() } else { self.receive() }
        }
    }

    private func parse() {
        while !closed, buffer.count >= 2 {
            let b0 = buffer[0], b1 = buffer[1]
            let fin = b0 & 0x80 != 0
            let opcode = b0 & 0x0F
            let masked = b1 & 0x80 != 0
            var length = Int(b1 & 0x7F)
            var offset = 2
            if length == 126 {
                guard buffer.count >= 4 else { return }
                length = Int(buffer[2]) << 8 | Int(buffer[3])
                offset = 4
            } else if length == 127 {
                guard buffer.count >= 10 else { return }
                guard buffer[2..<6].allSatisfy({ $0 == 0 }) else { close(); return }
                length = buffer[6..<10].reduce(0) { $0 << 8 | Int($1) }
                offset = 10
            }
            guard length <= Self.maxMessage else { close(); return }
            let maskLength = masked ? 4 : 0
            guard buffer.count >= offset + maskLength + length else { return }

            let start = offset + maskLength
            var payload = Array(buffer[start..<(start + length)])
            if masked {
                let mask = Array(buffer[offset..<(offset + 4)])
                for i in payload.indices { payload[i] ^= mask[i & 3] }
            }
            buffer.removeFirst(start + length)
            handle(opcode: opcode, fin: fin, payload: payload)
        }
    }

    private func handle(opcode: UInt8, fin: Bool, payload: [UInt8]) {
        switch opcode {
        case 0x0:
            message += payload
            guard message.count <= Self.maxMessage else { close(); return }
            if fin { deliver(messageOpcode, message); message = [] }
        case 0x1, 0x2:
            if fin { deliver(opcode, payload) } else { messageOpcode = opcode; message = payload }
        case 0x8:
            close()
        case 0x9:
            send(opcode: 0xA, payload: Data(payload))
        default:
            break
        }
    }

    private func deliver(_ opcode: UInt8, _ payload: [UInt8]) {
        if opcode == 0x1 { onText?(String(decoding: payload, as: UTF8.self)) }
    }
}

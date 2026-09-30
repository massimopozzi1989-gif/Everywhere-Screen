import Foundation
import Network

/// WebSocket lato server (RFC 6455) sopra una NWConnection già avviata.
/// Tutti i metodi vanno chiamati sulla coda della connessione.
final class WebSocket {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    /// Chiamato quando tutti i dati accodati sono stati consegnati al sistema.
    var onDrain: (() -> Void)?

    /// Byte accodati e non ancora consegnati al sistema: misura quanto il client è indietro.
    private(set) var pendingBytes = 0

    private let conn: NWConnection
    /// Byte ricevuti; quelli prima di `readIndex` sono già stati letti.
    private var buffer: [UInt8]
    private var readIndex = 0
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
        let n = payload.count
        var frame = Data(capacity: n + 10)
        frame.append(0x80 | opcode)
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
            if error != nil { self.close() } else if self.pendingBytes == 0 { self.onDrain?() }
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
        while !closed {
            let available = buffer.count - readIndex
            guard available >= 2 else { break }
            let b0 = buffer[readIndex], b1 = buffer[readIndex + 1]
            let fin = b0 & 0x80 != 0
            let opcode = b0 & 0x0F
            let masked = b1 & 0x80 != 0
            var length = Int(b1 & 0x7F)
            var header = 2
            if length == 126 {
                guard available >= 4 else { break }
                length = Int(buffer[readIndex + 2]) << 8 | Int(buffer[readIndex + 3])
                header = 4
            } else if length == 127 {
                guard available >= 10 else { break }
                guard buffer[(readIndex + 2)..<(readIndex + 6)].allSatisfy({ $0 == 0 }) else { close(); return }
                length = buffer[(readIndex + 6)..<(readIndex + 10)].reduce(0) { $0 << 8 | Int($1) }
                header = 10
            }
            guard length <= Self.maxMessage else { close(); return }
            let maskStart = readIndex + header
            let start = maskStart + (masked ? 4 : 0)
            guard buffer.count >= start + length else { break }

            var payload = Array(buffer[start..<(start + length)])
            if masked {
                for i in payload.indices { payload[i] ^= buffer[maskStart + (i & 3)] }
            }
            readIndex = start + length
            handle(opcode: opcode, fin: fin, payload: payload)
        }
        // Scarta i byte già letti una volta sola, invece che a ogni frame.
        if readIndex == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex > 0 {
            buffer.removeFirst(readIndex)
            readIndex = 0
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
            // Risponde alla chiusura prima di chiudere, così il browser vede una chiusura pulita.
            send(opcode: 0x8, payload: Data(payload.prefix(2)))
            let conn = self.conn
            conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
            closed = true
            onClose?()
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

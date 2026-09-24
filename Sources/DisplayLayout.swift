import CoreGraphics

/// Disposizioni pronte per gli schermi dei tablet.
enum ArrangementPreset: String, CaseIterable, Identifiable {
    case right, left, sides, above, below

    var id: String { rawValue }

    var title: String {
        switch self {
        case .right: return "In fila a destra"
        case .left: return "In fila a sinistra"
        case .sides: return "Ai due lati"
        case .above: return "Sopra"
        case .below: return "Sotto"
        }
    }

    var symbol: String {
        switch self {
        case .right: return "rectangle.righthalf.inset.filled.arrow.right"
        case .left: return "rectangle.lefthalf.inset.filled.arrow.left"
        case .sides: return "arrow.left.and.right"
        case .above: return "rectangle.tophalf.inset.filled"
        case .below: return "rectangle.bottomhalf.inset.filled"
        }
    }
}

/// Geometria della disposizione, in coordinate globali di CoreGraphics (in punti, origine in
/// alto a sinistra dello schermo principale, y verso il basso).
enum DisplayLayout {
    /// Origini degli schermi dei tablet (nell'ordine dato) per una disposizione pronta.
    /// `fixed` sono gli altri schermi che non si spostano (monitor fisici), principale escluso.
    static func origins(for preset: ArrangementPreset, main: CGRect, fixed: [CGRect], tablets: [CGSize]) -> [CGPoint] {
        let occupied = fixed.reduce(main) { $0.union($1) }
        let centeredY = { (s: CGSize) in (main.midY - s.height / 2).rounded() }
        var out: [CGPoint] = []

        switch preset {
        case .right:
            var x = occupied.maxX
            for s in tablets { out.append(CGPoint(x: x, y: centeredY(s))); x += s.width }
        case .left:
            var x = occupied.minX
            for s in tablets { x -= s.width; out.append(CGPoint(x: x, y: centeredY(s))) }
        case .sides:
            var right = occupied.maxX, left = occupied.minX
            for (i, s) in tablets.enumerated() {
                if i % 2 == 0 {
                    out.append(CGPoint(x: right, y: centeredY(s))); right += s.width
                } else {
                    left -= s.width; out.append(CGPoint(x: left, y: centeredY(s)))
                }
            }
        case .above, .below:
            let total = tablets.reduce(0) { $0 + $1.width }
            var x = (main.midX - total / 2).rounded()
            for s in tablets {
                let y = preset == .above ? occupied.minY - s.height : occupied.maxY
                out.append(CGPoint(x: x, y: y))
                x += s.width
            }
        }
        return out
    }

    /// Posizione agganciata al bordo più vicino di un altro schermo, senza sovrapposizioni.
    /// `rect` è dove l'utente ha lasciato lo schermo.
    static func snap(_ rect: CGRect, to others: [CGRect]) -> CGPoint {
        let minOverlap: CGFloat = 40     // quanto devono toccarsi due schermi affiancati
        let alignDistance: CGFloat = 24  // entro questa distanza i bordi si allineano
        let w = rect.width, h = rect.height
        var best: (point: CGPoint, distance: CGFloat)?

        for o in others {
            func clampY(_ y: CGFloat) -> CGFloat { min(max(y, o.minY - h + minOverlap), o.maxY - minOverlap) }
            func clampX(_ x: CGFloat) -> CGFloat { min(max(x, o.minX - w + minOverlap), o.maxX - minOverlap) }
            func alignY(_ y: CGFloat) -> CGFloat {
                for target in [o.minY, o.maxY - h, o.midY - h / 2] where abs(y - target) < alignDistance { return target }
                return y
            }
            func alignX(_ x: CGFloat) -> CGFloat {
                for target in [o.minX, o.maxX - w, o.midX - w / 2] where abs(x - target) < alignDistance { return target }
                return x
            }
            let candidates = [
                CGPoint(x: o.maxX, y: alignY(clampY(rect.minY))),       // a destra
                CGPoint(x: o.minX - w, y: alignY(clampY(rect.minY))),   // a sinistra
                CGPoint(x: alignX(clampX(rect.minX)), y: o.minY - h),   // sopra
                CGPoint(x: alignX(clampX(rect.minX)), y: o.maxY),       // sotto
            ]
            for c in candidates {
                let placed = CGRect(origin: c, size: rect.size).insetBy(dx: 1, dy: 1)
                guard !others.contains(where: { $0.intersects(placed) }) else { continue }
                let d = hypot(c.x - rect.minX, c.y - rect.minY)
                if best == nil || d < best!.distance { best = (c, d) }
            }
        }
        let p = best?.point ?? rect.origin
        return CGPoint(x: p.x.rounded(), y: p.y.rounded())
    }

    /// Applica le nuove origini in modo permanente (macOS le ricorda).
    @discardableResult
    static func apply(_ origins: [CGDirectDisplayID: CGPoint]) -> Bool {
        var config: CGDisplayConfigRef?
        guard !origins.isEmpty, CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        for (id, p) in origins {
            CGConfigureDisplayOrigin(config, id, Int32(p.x), Int32(p.y))
        }
        if CGCompleteDisplayConfiguration(config, .permanently) == .success { return true }

        // Alcune configurazioni non accettano "permanently": riprova per la sessione.
        var retry: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&retry) == .success, let retry else { return false }
        for (id, p) in origins { CGConfigureDisplayOrigin(retry, id, Int32(p.x), Int32(p.y)) }
        return CGCompleteDisplayConfiguration(retry, .forSession) == .success
    }
}

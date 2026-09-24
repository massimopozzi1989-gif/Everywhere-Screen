import AppKit

/// Icona dell'app disegnata in codice: serve sia per l'.icns (generato da build.sh con
/// `--render-icon`) sia per l'icona della Home Screen del tablet.
enum Icon {
    /// `macStyle`: forma arrotondata con margini secondo la griglia delle icone macOS.
    /// Altrimenti quadrato pieno (iOS/Android arrotondano da soli).
    static func png(size: Int, macStyle: Bool) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        let s = CGFloat(size)
        let body = macStyle ? NSRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
                            : NSRect(x: 0, y: 0, width: s, height: s)
        let path = macStyle ? NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
                            : NSBezierPath(rect: body)

        if macStyle {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = s * 0.02
            shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
            shadow.set()
            NSColor.black.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        let gradient = NSGradient(colors: [
            NSColor(srgbRed: 0.33, green: 0.36, blue: 0.98, alpha: 1),
            NSColor(srgbRed: 0.10, green: 0.72, blue: 0.93, alpha: 1),
        ])
        gradient?.draw(in: path, angle: -60)

        let config = NSImage.SymbolConfiguration(pointSize: body.width * 0.42, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "macbook.and.ipad", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let sz = symbol.size
            let rect = NSRect(x: body.midX - sz.width / 2, y: body.midY - sz.height / 2, width: sz.width, height: sz.height)
            symbol.draw(in: rect)
        }
        return rep.representation(using: .png, properties: [:])
    }
}

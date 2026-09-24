import CoreGraphics

/// Schermo virtuale HiDPI creato con l'API privata CGVirtualDisplay (la stessa di
/// BetterDisplay/DeskPad). Esiste finché l'oggetto è vivo: rilasciarlo rimuove lo schermo.
final class VirtualScreen {
    static let minPoints = 480
    static let maxPoints = 2048

    let index: Int
    private let display: CGVirtualDisplay
    private(set) var width: Int
    private(set) var height: Int

    var displayID: CGDirectDisplayID { display.displayID }

    init?(index: Int, width: Int, height: Int) {
        let w = Self.clamp(width), h = Self.clamp(height)
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = .main
        descriptor.name = "Everywhere Screen \(index)"
        descriptor.maxPixelsWide = UInt32(Self.maxPoints * 2)
        descriptor.maxPixelsHigh = UInt32(Self.maxPoints * 2)
        // Densità tipica di un iPad (264 ppi) a 2x.
        descriptor.sizeInMillimeters = CGSize(width: Double(w * 2) / 264 * 25.4, height: Double(h * 2) / 264 * 25.4)
        descriptor.vendorID = 0x4D53
        descriptor.productID = 0x5343
        // Seriale fisso per slot: macOS ricorda la disposizione degli schermi.
        descriptor.serialNum = UInt32(0x1000 + index)

        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }
        self.index = index
        self.display = display
        self.width = w
        self.height = h
        guard resize(width: w, height: h) else { return nil }
    }

    /// Dimensioni in punti; i pixel reali sono il doppio (HiDPI).
    @discardableResult
    func resize(width: Int, height: Int) -> Bool {
        let w = Self.clamp(width), h = Self.clamp(height)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [CGVirtualDisplayMode(width: UInt32(w), height: UInt32(h), refreshRate: 60)]
        guard display.apply(settings) else { return false }
        self.width = w
        self.height = h
        ensureHiDPIMode()
        return true
    }

    /// macOS offre per ogni misura sia la modalità HiDPI (2x) sia quella 1:1, e a volte sceglie
    /// la 1:1 (per esempio per una preferenza salvata sullo stesso seriale): interfaccia minuscola.
    /// Qui si seleziona esplicitamente la modalità HiDPI.
    func ensureHiDPIMode() {
        let id = displayID
        if let current = CGDisplayCopyDisplayMode(id),
           current.width == width, current.height == height, current.pixelWidth == width * 2 { return }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode],
              let hiDPI = modes.first(where: { $0.width == width && $0.height == height && $0.pixelWidth == width * 2 && $0.isUsableForDesktopGUI() })
        else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayWithDisplayMode(config, id, hiDPI, nil)
        CGCompleteDisplayConfiguration(config, .permanently)
    }

    private static func clamp(_ v: Int) -> Int { min(max(v, minPoints), maxPoints) }
}

import AppKit
import ScreenCaptureKit
import ServiceManagement

/// Uno schermo esteso: schermo virtuale + cattura + canale con lo stesso numero.
final class Slot {
    let index: Int
    let hub: StreamHub
    let capturer = ScreenCapturer()
    var virtual: VirtualScreen?
    var autoFit: Bool
    var width: Int
    var height: Int
    var viewers = 0
    var sourceName: String?
    var error: String?
    var restartWork: DispatchWorkItem?
    /// Dimensione dello schermo quando è partita la cattura: se cambia va riavviata.
    var capturedSize: CGSize?

    init(index: Int, hub: StreamHub, width: Int, height: Int, autoFit: Bool) {
        self.index = index
        self.hub = hub
        self.width = width
        self.height = height
        self.autoFit = autoFit
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let port: UInt16 = 5050
    private let web = WebApp()
    private let injector = InputInjector()
    private let arrangement = ArrangementWindowController()
    private let defaults = UserDefaults.standard

    private var statusItem: NSStatusItem!
    private var slots: [Int: Slot] = [:]
    private var panels: [String: PairingPanel] = [:]
    private var serverError: String?
    private var screensChangedWork: DispatchWorkItem?

    private var quality: Double { defaults.object(forKey: "quality") as? Double ?? 0.7 }
    private var scale: Double { defaults.object(forKey: "scale") as? Double ?? 1.0 }
    private var fps: Int { defaults.object(forKey: "fps") as? Int ?? 30 }
    private var autoFullscreen: Bool { defaults.object(forKey: "autoFullscreen") as? Bool ?? true }

    /// Dimensioni in punti (HiDPI). Il verticale si ottiene con "Ruota" o con l'adattamento automatico.
    private var presets: [(String, Int, Int)] { [
        (tr("iPad 10,2\" (7ª–9ª gen.)", "iPad 10.2\" (7th–9th gen)"), 1080, 810),
        ("iPad 10,9\" / iPad Air 11\"", 1180, 820),
        ("iPad Pro 11\"", 1194, 834),
        ("iPad Pro / Air 13\"", 1366, 1024),
        ("iPad mini", 1133, 744),
        ("Tablet 16:10", 1280, 800),
        ("16:9", 1600, 900),
    ] }

    // MARK: - Avvio

    func applicationDidFinishLaunching(_ notification: Notification) {
        H264Encoder.warmUp()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        web.touchIcon = Icon.png(size: 180, macStyle: false)
        web.pairing.onShowRequest = { [weak self] request in self?.showPairing(request) }
        web.pairing.onHideRequest = { [weak self] id in self?.panels.removeValue(forKey: id)?.close() }
        web.server.onStateChanged = { [weak self] err in
            DispatchQueue.main.async { self?.serverError = err; self?.updateIcon() }
        }
        injector.onPermissionMissing = { [weak self] in
            DispatchQueue.main.async { self?.updateIcon() }
        }
        do {
            try web.start(port: port)
        } catch {
            serverError = tr("Porta \(port) non disponibile: ", "Port \(port) unavailable: ") + error.localizedDescription
        }

        // Schermi aggiunti/rimossi, ridimensionati o spostati.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.screensChangedWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.screensChanged() }
            self.screensChangedWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }

        let m = arrangement.model
        m.preset = defaults.string(forKey: "arrangement").flatMap(ArrangementPreset.init)
        m.provider = { [weak self] in self?.displayBoxes() ?? [] }
        m.onPreset = { [weak self] preset in self?.applyPreset(preset) }
        m.onMove = { [weak self] id, origin in self?.moveDisplay(id, to: origin) }
        m.onIdentify = { [weak self] in self?.web.allHubs.forEach { $0.identify() } }
        m.onOpenSettings = { [weak self] in self?.openDisplays() }

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }

        let saved = defaults.dictionary(forKey: "screens") ?? [:]
        for (key, value) in saved.sorted(by: { $0.key < $1.key }) {
            guard let i = Int(key), (1...Edition.maxScreens).contains(i), let cfg = value as? [String: Any] else { continue }
            // Accetta numeri o stringhe (es. valori scritti a mano con `defaults write`).
            func int(_ k: String, _ fallback: Int) -> Int { (cfg[k] as? NSNumber)?.intValue ?? (cfg[k] as? String).flatMap(Int.init) ?? fallback }
            addSlot(index: i, width: int("w", 1080), height: int("h", 810), autoFit: int("auto", 1) != 0)
        }
        if slots.isEmpty { addSlot(index: 1, width: 1080, height: 810, autoFit: true) }
        updateIcon()
    }

    private func showPairing(_ request: PairingManager.Request) {
        let panel = PairingPanel(request: request) { [weak self] in
            self?.web.pairing.cancel(id: request.id)
            self?.panels[request.id] = nil
        }
        panels[request.id] = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - Slot

    private func addSlot(index: Int, width: Int, height: Int, autoFit: Bool) {
        let hub = StreamHub(channel: index, queue: web.queue)
        hub.configure(quality: quality, fps: fps)
        hub.setAutoFullscreen(autoFullscreen)
        let slot = Slot(index: index, hub: hub, width: width, height: height, autoFit: autoFit)
        slot.virtual = VirtualScreen(index: index, width: width, height: height)
        if let v = slot.virtual { slot.width = v.width; slot.height = v.height }

        hub.onViewersChanged = { [weak self, weak slot] n in
            DispatchQueue.main.async {
                slot?.viewers = n
                self?.updateIcon()
                if self?.arrangement.isVisible == true { self?.arrangement.model.reload() }
            }
        }
        hub.onFit = { [weak self] w, h in
            DispatchQueue.main.async { self?.fit(channel: index, width: w, height: h) }
        }
        hub.onInput = { [injector] message, display in injector.handle(message, display: display) }
        slot.capturer.onPixelBuffer = { [hub] pixelBuffer in hub.push(pixelBuffer) }
        slot.capturer.onStop = { [weak self, weak slot] error in
            DispatchQueue.main.async {
                guard let self, let slot, self.slots[index] === slot else { return }
                slot.error = tr("Cattura interrotta: ", "Capture stopped: ") + error.localizedDescription
                self.updateIcon()
                self.scheduleRestart(slot, after: 2)
            }
        }

        slots[index] = slot
        web.register(hub)
        save()
        restartCapture(slot)
    }

    private func removeSlot(_ slot: Slot) {
        slots[slot.index] = nil
        slot.restartWork?.cancel()
        web.unregister(channel: slot.index)
        slot.hub.closeAll()
        save()
        Task { @MainActor in
            await slot.capturer.stop()
            slot.virtual = nil   // rilasciarlo rimuove lo schermo virtuale
        }
        updateIcon()
    }

    private func fit(channel: Int, width: Int, height: Int) {
        guard let slot = slots[channel], slot.autoFit else { return }
        resize(slot, width: width, height: height)
    }

    private func resize(_ slot: Slot, width: Int, height: Int) {
        guard let v = slot.virtual, (width, height) != (v.width, v.height) else { return }
        if v.resize(width: width, height: height) {
            slot.width = v.width
            slot.height = v.height
            save()
            scheduleRestart(slot, after: 1)
        }
    }

    private func save() {
        var out: [String: [String: Int]] = [:]
        for slot in slots.values {
            out[String(slot.index)] = ["w": slot.width, "h": slot.height, "auto": slot.autoFit ? 1 : 0]
        }
        defaults.set(out, forKey: "screens")
    }

    // MARK: - Cattura

    private func scheduleRestart(_ slot: Slot, after seconds: Double) {
        slot.restartWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak slot] in
            guard let self, let slot else { return }
            self.restartCapture(slot)
        }
        slot.restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func restartCapture(_ slot: Slot) {
        guard slots[slot.index] === slot else { return }
        guard let (id, name) = source(for: slot) else {
            slot.error = tr("Nessuno schermo disponibile", "No display available")
            updateIcon()
            return
        }
        slot.capturer.scale = scale
        slot.capturer.fps = fps
        slot.hub.configure(quality: quality, fps: fps)
        slot.hub.displayID = id
        Task { @MainActor in
            do {
                try await slot.capturer.start(displayID: id)
                slot.sourceName = name
                slot.error = nil
                slot.capturedSize = CGDisplayBounds(id).size
            } catch ScreenCapturer.CaptureError.superseded {
                return   // un riavvio più recente è già in corso
            } catch {
                slot.sourceName = nil
                slot.error = CGPreflightScreenCaptureAccess()
                    ? tr("Errore cattura: ", "Capture error: ") + error.localizedDescription
                    : tr("Manca il permesso Registrazione Schermo", "Screen Recording permission is missing")
                scheduleRestart(slot, after: 3)
            }
            updateIcon()
        }
    }

    /// Lo schermo virtuale dello slot. Se l'API privata non è disponibile (es. dopo un
    /// aggiornamento di macOS), lo slot 1 ripiega su uno schermo secondario esistente.
    private func source(for slot: Slot) -> (CGDirectDisplayID, String)? {
        if let v = slot.virtual { return (v.displayID, "Everywhere Screen \(slot.index) (\(tr("virtuale", "virtual")))") }
        guard slot.index == 1 else { return nil }
        let mainID = CGMainDisplayID()
        guard let screen = NSScreen.screens.first(where: { $0.displayID != mainID }) ?? NSScreen.main,
              let id = screen.displayID else { return nil }
        return (id, screen.localizedName)
    }

    private func updateIcon() {
        let hasError = serverError != nil || slots.values.contains { $0.error != nil }
        let streaming = slots.values.contains { $0.viewers > 0 }
        let symbol = hasError ? "exclamationmark.triangle" : (streaming ? "macbook.and.ipad" : "rectangle.on.rectangle")
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Everywhere Screen")
    }

    // MARK: - Disposizione

    private func screensChanged() {
        // Riavvia solo le catture il cui schermo è cambiato di dimensione (spostarlo non conta).
        for slot in slots.values {
            slot.virtual?.ensureHiDPIMode()
            let current = slot.virtual.map { CGDisplayBounds($0.displayID).size }
            if slot.error != nil || slot.capturedSize == nil || (current != nil && current != slot.capturedSize) {
                restartCapture(slot)
            }
        }
        reapplyPresetIfNeeded()
        arrangement.model.reload()
    }

    private func displayBoxes() -> [DisplayBox] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)

        let mainID = CGMainDisplayID()
        return ids.prefix(Int(count)).map { id in
            let slot = slots.values.first { $0.virtual?.displayID == id }
            let screenName = NSScreen.screens.first { $0.displayID == id }?.localizedName
            let name = slot.map { tr("Schermo \($0.index)", "Screen \($0.index)") } ?? (id == mainID ? "Mac" : screenName ?? "Monitor")
            return DisplayBox(id: id, name: name, frame: CGDisplayBounds(id), isMain: id == mainID,
                              slot: slot?.index, connected: (slot?.viewers ?? 0) > 0)
        }
    }

    /// Origini degli schermi dei tablet (in ordine di numero) per una disposizione pronta.
    private func presetOrigins(_ preset: ArrangementPreset) -> [CGDirectDisplayID: CGPoint] {
        let boxes = displayBoxes()
        guard let main = boxes.first(where: \.isMain) else { return [:] }
        let tablets = boxes.filter { $0.slot != nil }.sorted { $0.slot! < $1.slot! }
        let fixed = boxes.filter { !$0.isMain && $0.slot == nil }.map(\.frame)
        let origins = DisplayLayout.origins(for: preset, main: main.frame, fixed: fixed, tablets: tablets.map(\.frame.size))
        return Dictionary(uniqueKeysWithValues: zip(tablets.map(\.id), origins))
    }

    private func applyPreset(_ preset: ArrangementPreset) {
        DisplayLayout.apply(presetOrigins(preset))
        arrangement.model.preset = preset
        defaults.set(preset.rawValue, forKey: "arrangement")
        arrangement.model.reload()
    }

    /// Dopo una rotazione o un nuovo schermo la disposizione pronta scelta resta valida.
    private func reapplyPresetIfNeeded() {
        guard let preset = arrangement.model.preset else { return }
        let target = presetOrigins(preset)
        if target.contains(where: { CGDisplayBounds($0.key).origin != $0.value }) {
            DisplayLayout.apply(target)
        }
    }

    private func moveDisplay(_ id: CGDirectDisplayID, to origin: CGPoint) -> CGPoint? {
        let bounds = CGDisplayBounds(id)
        let others = displayBoxes().filter { $0.id != id }.map(\.frame)
        let placed = DisplayLayout.snap(CGRect(origin: origin, size: bounds.size), to: others)
        guard DisplayLayout.apply([id: placed]) else { return nil }
        // Disposizione libera: non riapplicare più quella pronta.
        defaults.removeObject(forKey: "arrangement")
        return CGDisplayBounds(id).origin
    }

    @objc private func showArrangement() {
        arrangement.show()
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let base = "http://\(NetInfo.localIPv4() ?? tr("IP-del-Mac", "Mac-IP")):\(port)"

        menu.addItem(action("\(base)  " + tr("(clic per copiare)", "(click to copy)"), #selector(copyURL(_:)), base))
        if let serverError { menu.addItem(disabled(serverError)) }
        menu.addItem(.separator())

        for slot in slots.values.sorted(by: { $0.index < $1.index }) {
            let clients = slot.viewers == 1 ? tr("1 dispositivo", "1 device") : tr("\(slot.viewers) dispositivi", "\(slot.viewers) devices")
            let parent = NSMenuItem(title: tr("Schermo", "Screen") + " \(slot.index) — \(slot.width)×\(slot.height) · \(clients)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.addItem(action(tr("Copia indirizzo", "Copy address") + "  \(base)/\(slot.index)", #selector(copyURL(_:)), "\(base)/\(slot.index)"))
            sub.addItem(disabled(slot.error ?? tr("Sorgente: ", "Source: ") + (slot.sourceName ?? "—")))
            if slot.virtual != nil {
                sub.addItem(.separator())
                let auto = action(tr("Adatta automaticamente al dispositivo", "Fit to the device automatically"), #selector(toggleAutoFit(_:)), slot.index)
                auto.state = slot.autoFit ? .on : .off
                sub.addItem(auto)
                for (name, w, h) in presets {
                    let portrait = slot.height > slot.width
                    let (pw, ph) = portrait ? (h, w) : (w, h)
                    let mi = action("\(name)  \(pw)×\(ph)", #selector(setPreset(_:)), [slot.index, pw, ph])
                    mi.state = (pw, ph) == (slot.width, slot.height) ? .on : .off
                    sub.addItem(mi)
                }
                sub.addItem(action(tr("Ruota (orizzontale/verticale)", "Rotate (landscape/portrait)"), #selector(rotate(_:)), slot.index))
            }
            sub.addItem(.separator())
            sub.addItem(action(tr("Rimuovi schermo", "Remove screen") + " \(slot.index)", #selector(removeScreen(_:)), slot.index))
            parent.submenu = sub
            menu.addItem(parent)
        }
        let add = action(tr("Aggiungi schermo", "Add screen"), #selector(addScreen), nil)
        add.isEnabled = slots.count < Edition.maxScreens
        menu.addItem(add)
        menu.addItem(.separator())

        menu.addItem(devicesMenu())
        if Edition.inputAllowed && !InputInjector.hasPermission {
            menu.addItem(action(tr("⚠︎ Consenti il controllo dal tablet (Accessibilità)…", "⚠︎ Allow control from the tablet (Accessibility)…"), #selector(openAccessibility), nil))
        }
        menu.addItem(.separator())

        menu.addItem(optionMenu(tr("Qualità", "Quality"), key: "quality", current: quality,
                                options: [(tr("Bassa (meno banda)", "Low (less bandwidth)"), 0.5), (tr("Media", "Medium"), 0.7),
                                          (tr("Alta", "High"), 0.85), (tr("Massima", "Maximum"), 0.95)]))
        menu.addItem(optionMenu(tr("Risoluzione stream", "Stream resolution"), key: "scale", current: scale,
                                options: [("Retina (100%)", 1.0), ("75%", 0.75), ("50%", 0.5)]))
        menu.addItem(optionMenu(tr("Frame al secondo", "Frames per second"), key: "fps", current: Double(fps),
                                options: [("15", 15), ("30", 30), ("60", 60)]))
        menu.addItem(.separator())

        let fullscreen = action(tr("Schermo intero automatico sui tablet", "Automatic full screen on tablets"), #selector(toggleAutoFullscreen), nil)
        fullscreen.state = autoFullscreen ? .on : .off
        fullscreen.toolTip = tr("Al primo tocco il tablet nasconde le barre del browser. Si può sempre attivare o disattivare dal pulsante sul tablet.",
                                "On the first touch the tablet hides the browser bars. You can always switch it on or off with the button on the tablet.")
        menu.addItem(fullscreen)
        menu.addItem(languageMenu())
        menu.addItem(.separator())

        let login = action(tr("Avvia al login", "Open at login"), #selector(toggleLogin), nil)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(action(tr("Disposizione schermi…", "Arrange screens…"), #selector(showArrangement), nil))
        menu.addItem(action(tr("Impostazioni Registrazione Schermo…", "Screen Recording settings…"), #selector(openPrivacy), nil))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: tr("Esci da Everywhere Screen", "Quit Everywhere Screen"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Il titolo è in entrambe le lingue: chi ha scelto quella sbagliata lo ritrova comunque.
    private func languageMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Lingua · Language", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let options: [(String, String)] = [(tr("Automatica (come il sistema)", "Automatic (same as the system)"), ""),
                                           ("Italiano", Language.it.rawValue), ("English", Language.en.rawValue)]
        for (title, code) in options {
            let mi = action(title, #selector(setLanguage(_:)), code)
            mi.state = (Language.preference?.rawValue ?? "") == code ? .on : .off
            sub.addItem(mi)
        }
        parent.submenu = sub
        return parent
    }

    private func devicesMenu() -> NSMenuItem {
        let devices = web.pairing.devices
        let parent = NSMenuItem(title: tr("Dispositivi abbinati", "Paired devices") + " (\(devices.count))", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if devices.isEmpty {
            sub.addItem(disabled(tr("Nessuno: apri l'indirizzo sul tablet per abbinarlo", "None yet: open the address on the tablet to pair it")))
        }
        for device in devices {
            let item = NSMenuItem(title: device.name, action: nil, keyEquivalent: "")
            let dsub = NSMenu()
            dsub.addItem(disabled(tr("Abbinato il ", "Paired on ") + device.created.formatted(date: .abbreviated, time: .shortened)))
            if Edition.inputAllowed {
                let control = action(tr("Può controllare il Mac", "Can control the Mac"), #selector(toggleDeviceControl(_:)), device.id)
                control.state = device.control ? .on : .off
                dsub.addItem(control)
            }
            dsub.addItem(action(tr("Rimuovi abbinamento", "Remove pairing"), #selector(removeDevice(_:)), device.id))
            item.submenu = dsub
            sub.addItem(item)
        }
        parent.submenu = sub
        return parent
    }

    private func action(_ title: String, _ selector: Selector, _ object: Any?) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        mi.target = self
        mi.representedObject = object
        return mi
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    private func optionMenu(_ title: String, key: String, current: Double, options: [(String, Double)]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (label, value) in options {
            let mi = action(label, #selector(setOption(_:)), [key: value])
            mi.state = abs(current - value) < 0.001 ? .on : .off
            sub.addItem(mi)
        }
        parent.submenu = sub
        return parent
    }

    // MARK: - Azioni

    @objc private func copyURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc private func addScreen() {
        guard let index = (1...Edition.maxScreens).first(where: { slots[$0] == nil }) else { return }
        addSlot(index: index, width: 1080, height: 810, autoFit: true)
        if slots[index]?.virtual == nil {
            slots[index]?.error = tr("Impossibile creare lo schermo virtuale", "Couldn't create the virtual screen")
            updateIcon()
        }
    }

    @objc private func removeScreen(_ sender: NSMenuItem) {
        guard let i = sender.representedObject as? Int, let slot = slots[i] else { return }
        removeSlot(slot)
    }

    @objc private func toggleAutoFit(_ sender: NSMenuItem) {
        guard let i = sender.representedObject as? Int, let slot = slots[i] else { return }
        slot.autoFit.toggle()
        save()
    }

    @objc private func setPreset(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? [Int], v.count == 3, let slot = slots[v[0]] else { return }
        slot.autoFit = false   // scelta manuale: il dispositivo non la sovrascrive
        resize(slot, width: v[1], height: v[2])
        save()
    }

    @objc private func rotate(_ sender: NSMenuItem) {
        guard let i = sender.representedObject as? Int, let slot = slots[i] else { return }
        slot.autoFit = false
        resize(slot, width: slot.height, height: slot.width)
        save()
    }

    @objc private func setOption(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? [String: Double], let (key, value) = dict.first else { return }
        if key == "fps" { defaults.set(Int(value), forKey: key) } else { defaults.set(value, forKey: key) }
        if key == "quality" {
            slots.values.forEach { $0.hub.configure(quality: value, fps: fps) }
        } else {
            slots.values.forEach { restartCapture($0) }
        }
    }

    @objc private func toggleDeviceControl(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let device = web.pairing.devices.first(where: { $0.id == id }) else { return }
        web.pairing.setControl(!device.control, deviceID: id)
        web.allHubs.forEach { $0.setControl(!device.control, deviceID: id) }
    }

    @objc private func removeDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        web.pairing.remove(deviceID: id)
        web.allHubs.forEach { $0.disconnect(deviceID: id) }
    }

    @objc private func toggleAutoFullscreen() {
        let on = !autoFullscreen
        defaults.set(on, forKey: "autoFullscreen")
        web.allHubs.forEach { $0.setAutoFullscreen(on) }
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        Language.preference = Language(rawValue: code)
        arrangement.languageChanged()
        // I tablet ricaricano la pagina nella nuova lingua.
        web.allHubs.forEach { $0.reloadClients() }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            serverError = tr("Avvio al login: ", "Open at login: ") + error.localizedDescription
            updateIcon()
        }
    }

    @objc private func openAccessibility() {
        InputInjector.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openDisplays() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    }

    @objc private func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

enum NetInfo {
    /// IPv4 della rete locale (preferisce en0, cioè il Wi-Fi sui Mac Apple Silicon).
    static func localIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var found: [String: String] = [:]
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found[String(cString: ifa.ifa_name)] = String(cString: host)
            }
        }
        return found["en0"] ?? found["en1"] ?? found.values.sorted().first
    }
}

// build.sh genera l'icona dell'app con: EverywhereScreen --render-icon <cartella.iconset>
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-icon" {
    let dir = URL(fileURLWithPath: CommandLine.arguments[2])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try? Icon.png(size: base * scale, macStyle: true)?.write(to: dir.appendingPathComponent(name))
        }
    }
    exit(0)
}

// Le app partono con un limite di 256 file aperti: la cattura e gli encoder ne usano già molti,
// e con 8 schermi e tanti tablet il server smetterebbe di accettare connessioni.
var fileLimit = rlimit()
if getrlimit(RLIMIT_NOFILE, &fileLimit) == 0, fileLimit.rlim_cur < 4096 {
    fileLimit.rlim_cur = min(4096, fileLimit.rlim_max)
    setrlimit(RLIMIT_NOFILE, &fileLimit)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

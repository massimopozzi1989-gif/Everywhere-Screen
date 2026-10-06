import AppKit

/// Finestrella in primo piano che mostra il codice di abbinamento sul Mac.
final class PairingPanel: NSPanel {
    let requestID: String
    private let onReject: () -> Void

    init(request: PairingManager.Request, onReject: @escaping () -> Void) {
        requestID = request.id
        self.onReject = onReject
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 190),
                   styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Everywhere Screen"
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let message = NSTextField(wrappingLabelWithString: tr("«\(request.name)» vuole collegarsi a questo Mac.\nInserisci questo codice sul dispositivo:",
                                                              "“\(request.name)” wants to connect to this Mac.\nEnter this code on the device:"))
        message.alignment = .center

        let spaced = String(request.code.prefix(3)) + " " + String(request.code.suffix(3))
        let code = NSTextField(labelWithString: spaced)
        code.font = .monospacedDigitSystemFont(ofSize: 38, weight: .semibold)
        code.alignment = .center
        code.isSelectable = true

        let reject = NSButton(title: tr("Rifiuta", "Decline"), target: nil, action: nil)
        reject.bezelStyle = .rounded
        reject.target = self
        reject.action = #selector(rejectTapped)

        let stack = NSStackView(views: [message, code, reject])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
        contentView = stack
        center()
    }

    @objc private func rejectTapped() {
        onReject()
        close()
    }
}

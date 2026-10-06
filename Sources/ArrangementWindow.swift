import AppKit
import SwiftUI

/// Uno schermo nella mappa della disposizione (coordinate globali CoreGraphics, in punti).
struct DisplayBox: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    var frame: CGRect
    let isMain: Bool
    /// Numero dello schermo Everywhere, se è uno schermo di un tablet.
    let slot: Int?
    let connected: Bool

    var movable: Bool { slot != nil }
}

final class ArrangementModel: ObservableObject {
    @Published var displays: [DisplayBox] = []
    @Published var preset: ArrangementPreset?
    /// Cambia quando cambia la lingua: ridisegna i testi.
    @Published var language = Language.current

    var provider: () -> [DisplayBox] = { [] }
    var onPreset: (ArrangementPreset) -> Void = { _ in }
    /// Ritorna l'origine effettiva dopo l'aggancio.
    var onMove: (CGDirectDisplayID, CGPoint) -> CGPoint? = { _, _ in nil }
    var onIdentify: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    func reload() { displays = provider() }

    func move(_ id: CGDirectDisplayID, to origin: CGPoint) {
        if let placed = onMove(id, origin), let i = displays.firstIndex(where: { $0.id == id }) {
            displays[i].frame.origin = placed
        }
        preset = nil
    }
}

final class ArrangementWindowController {
    let model = ArrangementModel()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = tr("Disposizione schermi", "Arrange screens")
            w.contentViewController = NSHostingController(rootView: ArrangementView(model: model))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        model.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func languageChanged() {
        model.language = Language.current
        window?.title = tr("Disposizione schermi", "Arrange screens")
        model.reload()
    }
}

// MARK: - Viste

struct ArrangementView: View {
    @ObservedObject var model: ArrangementModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr("Disposizioni pronte", "Ready-made layouts")).font(.headline)
                Spacer()
                Button { model.onIdentify() } label: {
                    Label(tr("Identifica tablet", "Identify tablets"), systemImage: "number.square")
                }
                .help(tr("Mostra il numero dello schermo su ogni tablet collegato", "Shows the screen number on every connected tablet"))
            }
            HStack(spacing: 8) {
                ForEach(ArrangementPreset.allCases) { preset in
                    PresetButton(preset: preset, selected: model.preset == preset) {
                        model.onPreset(preset)
                    }
                }
            }
            ArrangementCanvas(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(tr("Trascina un tablet per spostarlo: si aggancia al bordo più vicino.", "Drag a tablet to move it: it snaps to the nearest edge."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(tr("Impostazioni Schermi…", "Displays Settings…")) { model.onOpenSettings() }
            }
        }
        .id(model.language)
        .padding(20)
        .frame(minWidth: 640, minHeight: 440)
    }
}

private struct PresetButton: View {
    let preset: ArrangementPreset
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: preset.symbol).font(.title2)
                Text(preset.title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ArrangementCanvas: View {
    @ObservedObject var model: ArrangementModel
    @State private var dragging: CGDirectDisplayID?
    @State private var translation: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let union = model.displays.reduce(CGRect.null) { $0.union($1.frame) }
            let area = union.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1)
                                    : union.insetBy(dx: -max(union.width, 1200) * 0.15, dy: -max(union.height, 800) * 0.15)
            let scale = min(geo.size.width / area.width, geo.size.height / area.height)
            let inset = CGPoint(x: (geo.size.width - area.width * scale) / 2, y: (geo.size.height - area.height * scale) / 2)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(0.04))
                ForEach(model.displays) { d in
                    let active = dragging == d.id
                    let w = d.frame.width * scale, h = d.frame.height * scale
                    let x = inset.x + (d.frame.minX - area.minX) * scale + (active ? translation.width : 0)
                    let y = inset.y + (d.frame.minY - area.minY) * scale + (active ? translation.height : 0)
                    DisplayTile(display: d, lifted: active)
                        .frame(width: w, height: h)
                        .position(x: x + w / 2, y: y + h / 2)
                        .zIndex(active ? 1 : 0)
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { value in
                                    dragging = d.id
                                    translation = value.translation
                                }
                                .onEnded { value in
                                    let origin = CGPoint(x: d.frame.minX + value.translation.width / scale,
                                                         y: d.frame.minY + value.translation.height / scale)
                                    dragging = nil
                                    translation = .zero
                                    model.move(d.id, to: origin)
                                },
                            including: d.movable ? .all : .none
                        )
                }
            }
        }
    }
}

private struct DisplayTile: View {
    let display: DisplayBox
    let lifted: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        ZStack {
            shape.fill(fill)
            if display.isMain {
                VStack { Rectangle().fill(Color.white.opacity(0.55)).frame(height: 5); Spacer() }
                    .clipShape(shape)
            }
            VStack(spacing: 2) {
                if let slot = display.slot {
                    Text("\(slot)").font(.system(size: 30, weight: .bold, design: .rounded))
                }
                Text(display.name).font(.caption.weight(.semibold)).lineLimit(1)
                Text("\(Int(display.frame.width))×\(Int(display.frame.height))")
                    .font(.caption2).opacity(0.8)
                if display.slot != nil {
                    HStack(spacing: 4) {
                        Circle().fill(display.connected ? Color.green : Color.white.opacity(0.4)).frame(width: 6, height: 6)
                        Text(display.connected ? tr("collegato", "connected") : tr("in attesa", "waiting")).font(.caption2)
                    }
                    .opacity(0.9)
                }
            }
            .foregroundStyle(.white)
            .minimumScaleFactor(0.5)
            .padding(4)
        }
        .overlay(shape.strokeBorder(Color.white.opacity(lifted ? 0.9 : 0.25), lineWidth: lifted ? 2 : 1))
        .shadow(color: .black.opacity(lifted ? 0.35 : 0.12), radius: lifted ? 10 : 2, y: lifted ? 6 : 1)
        .scaleEffect(lifted ? 1.02 : 1)
        .animation(.easeOut(duration: 0.12), value: lifted)
    }

    private var fill: LinearGradient {
        let colors: [Color]
        if display.slot != nil {
            colors = [Color(red: 0.33, green: 0.36, blue: 0.98), Color(red: 0.10, green: 0.72, blue: 0.93)]
        } else if display.isMain {
            colors = [Color(white: 0.42), Color(white: 0.30)]
        } else {
            colors = [Color(white: 0.55), Color(white: 0.42)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

import CoreGraphics
import Foundation

// Test della geometria delle disposizioni. Esegui con: scripts/test.sh

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { failures += 1; print("✗ riga \(line): \(message)") }
}

let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
let ipad = CGSize(width: 1080, height: 810)
let portrait = CGSize(width: 820, height: 1180)

func rects(_ origins: [CGPoint], _ sizes: [CGSize]) -> [CGRect] {
    zip(origins, sizes).map { CGRect(origin: $0, size: $1) }
}

/// Nessuna sovrapposizione e ogni schermo tocca almeno un altro.
func checkValid(_ all: [CGRect], _ name: String) {
    for (i, a) in all.enumerated() {
        for (j, b) in all.enumerated() where i < j {
            check(!a.insetBy(dx: 1, dy: 1).intersects(b.insetBy(dx: 1, dy: 1)), "\(name): \(a) e \(b) si sovrappongono")
        }
        let touches = all.enumerated().contains { j, b in j != i && a.insetBy(dx: -1, dy: -1).intersects(b) }
        check(touches, "\(name): \(a) non tocca nessuno schermo")
    }
}

// Disposizioni pronte con 3 tablet di forme diverse.
let sizes = [ipad, portrait, ipad]
for preset in ArrangementPreset.allCases {
    let o = DisplayLayout.origins(for: preset, main: main, fixed: [], tablets: sizes)
    check(o.count == 3, "\(preset): 3 origini")
    checkValid([main] + rects(o, sizes), preset.rawValue)
}

// Disposizioni pronte con 8 tablet (il massimo): nessuna sovrapposizione, tutti attaccati.
let eight = (0..<8).map { $0 % 3 == 1 ? portrait : ipad }
for preset in ArrangementPreset.allCases {
    let o = DisplayLayout.origins(for: preset, main: main, fixed: [], tablets: eight)
    check(o.count == 8, "\(preset) con 8 tablet: 8 origini")
    checkValid([main] + rects(o, eight), "\(preset.rawValue) con 8 tablet")
}

let right = DisplayLayout.origins(for: .right, main: main, fixed: [], tablets: sizes)
check(right[0].x == 1512 && right[1].x == 2592 && right[2].x == 3412, "right: in fila da x=1512, ottenuto \(right)")
check(right[0].y == 86, "right: centrato verticalmente sul Mac (y=86), ottenuto \(right[0].y)")

let left = DisplayLayout.origins(for: .left, main: main, fixed: [], tablets: sizes)
check(left[0].x == -1080 && left[1].x == -1900, "left: in fila a sinistra, ottenuto \(left)")

let sides = DisplayLayout.origins(for: .sides, main: main, fixed: [], tablets: sizes)
check(sides[0].x == 1512 && sides[1].x == -820 && sides[2].x == 2592, "sides: alternati destra/sinistra, ottenuto \(sides)")

let above = DisplayLayout.origins(for: .above, main: main, fixed: [], tablets: [ipad, ipad])
check(above[0].y == -810 && above[0].x == -324 && above[1].x == 756, "above: riga centrata sopra, ottenuto \(above)")

// Un monitor fisico a destra: i tablet vanno dopo di lui, non sopra.
let monitor = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
let withMonitor = DisplayLayout.origins(for: .right, main: main, fixed: [monitor], tablets: [ipad])
check(withMonitor[0].x == 3432, "right con monitor: dopo il monitor, ottenuto \(withMonitor)")

// Aggancio: lasciato un po' staccato a destra del Mac → attaccato al bordo destro.
let snapped = DisplayLayout.snap(CGRect(x: 1600, y: 100, width: 1080, height: 810), to: [main])
check(snapped.x == 1512, "snap: attaccato al bordo destro, ottenuto \(snapped)")

// Aggancio con allineamento: vicino al bordo superiore → allineato in alto.
let aligned = DisplayLayout.snap(CGRect(x: 1530, y: 15, width: 1080, height: 810), to: [main])
check(aligned == CGPoint(x: 1512, y: 0), "snap: allineato in alto, ottenuto \(aligned)")

// Lasciato sopra il Mac, sovrapposto → spinto sopra.
let top = DisplayLayout.snap(CGRect(x: 200, y: -700, width: 1080, height: 810), to: [main])
check(top.y == -810, "snap: sopra il Mac, ottenuto \(top)")

// Mai sovrapposto a un altro tablet già presente.
let other = CGRect(x: 1512, y: 86, width: 1080, height: 810)
let second = DisplayLayout.snap(CGRect(x: 1700, y: 200, width: 1080, height: 810), to: [main, other])
checkValid([main, other, CGRect(origin: second, size: ipad)], "snap con altro tablet")

// Staccato lontanissimo → comunque agganciato a qualcosa.
let far = DisplayLayout.snap(CGRect(x: 9000, y: 9000, width: 1080, height: 810), to: [main])
checkValid([main, CGRect(origin: far, size: ipad)], "snap da lontano")

if failures == 0 { print("✓ tutti i test di DisplayLayout passati") } else { print("\(failures) test falliti"); exit(1) }

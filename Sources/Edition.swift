/// Modello Free + Pro.
/// Free: 1 schermo, solo visione. Pro: 3 schermi e controllo del Mac dal tablet.
/// Finché non c'è un sistema di licenze tutto è sbloccato.
enum Edition {
    static let isPro = true

    static var maxScreens: Int { isPro ? 3 : 1 }
    static var inputAllowed: Bool { isPro }
}

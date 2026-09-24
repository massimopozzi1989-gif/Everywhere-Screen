# Everywhere Screen

Usa qualsiasi tablet (iPad, Android) come schermo esteso del Mac, via Wi-Fi, senza installare
nulla sul tablet: basta il browser.

- Fino a 3 schermi virtuali, creati dall'app (niente BetterDisplay); ognuno si adatta alla
  risoluzione e all'orientamento del tablet che lo apre.
- Video H.264 a bassa latenza (VideoToolbox → WebSocket → Media Source Extensions), con MJPEG
  come ripiego per i browser più vecchi.
- Controllo del Mac dal tablet: tocco, trascinamento, clic destro, scroll a due dita,
  Apple Pencil con pressione, tastiera a schermo e tastiere fisiche con scorciatoie.
- Abbinamento dei dispositivi con codice a 6 cifre mostrato sul Mac.

Richiede macOS 14 o successivo su Apple Silicon.

## Uso
1. Avvia Everywhere Screen (icona nella barra dei menu).
2. Sul tablet apri l'indirizzo mostrato nel menu, ad es. `http://192.168.1.20:5050/1`.
3. Premi **Collega** e inserisci il codice che compare sul Mac.
4. Aggiungi la pagina alla Home Screen per usarla a tutto schermo.

Al primo avvio macOS chiede il permesso **Registrazione Schermo**; per controllare il Mac dal
tablet serve anche **Accessibilità**.

## Gesti
| Tablet | Mac |
|---|---|
| tap | clic |
| trascinare | trascinamento |
| pressione lunga / tap a due dita | clic destro |
| due dita | scorrimento |
| Apple Pencil | mouse preciso con pressione |
| pulsante tastiera | tastiera a schermo |

## Build
```bash
./build.sh            # build/Everywhere Screen.app, firmata Developer ID
./build.sh install    # la installa in /Applications e la avvia
scripts/release.sh    # DMG firmato e notarizzato in dist/
```
Il progetto non usa Xcode: `swiftc` compila `Sources/*.swift`. Gli schermi virtuali usano l'API
privata `CGVirtualDisplay`, per cui l'app si distribuisce fuori dal Mac App Store.

Architettura e decisioni: [docs/specs](docs/specs/2026-09-24-everywhere-screen-design.md).

import AppKit
import WebKit

/// A „VoxBarber használata” súgóablak vezérlője.
///
/// Egy `WKWebView`-t jelenít meg, amelybe beágyazott HTML dokumentumot tölt be
/// a program használati leírásával. Az ablak méretezhető és bezárható.
@MainActor
final class HelpWindowController: NSWindowController {

    // MARK: – Inicializálás

    convenience init() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 900)
        let w = min(720.0, screen.width)
        let h = min(640.0, screen.height)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoxBarber használata"
        window.center()
        window.minSize = NSSize(width: 480, height: 360)

        self.init(window: window)
        buildContentView()
    }

    // MARK: – Tartalom felépítése

    private func buildContentView() {
        guard let window else { return }

        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false

        window.contentView = NSView()
        guard let contentView = window.contentView else { return }
        contentView.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: contentView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])

        webView.loadHTMLString(Self.helpHTML, baseURL: nil)
    }

    // MARK: – Súgó tartalma (HTML)

    /// A súgó beágyazott HTML dokumentuma. A `prefers-color-scheme`
    /// segítségével világos és sötét módban is megfelelően jelenik meg.
    static let helpHTML: String = """
    <!DOCTYPE html>
    <html lang="hu">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        :root {
            --bg: #ffffff;
            --fg: #1d1d1f;
            --muted: #6e6e73;
            --accent: #0a84ff;
            --card: #f5f5f7;
            --border: #e0e0e3;
            --kbd-bg: #ffffff;
            --kbd-border: #c7c7cc;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --bg: #1e1e1e;
                --fg: #f5f5f7;
                --muted: #a1a1a6;
                --accent: #409cff;
                --card: #2a2a2c;
                --border: #3a3a3c;
                --kbd-bg: #3a3a3c;
                --kbd-border: #5a5a5e;
            }
        }
        * { box-sizing: border-box; }
        html, body {
            margin: 0;
            padding: 0;
            background: var(--bg);
            color: var(--fg);
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            font-size: 15px;
            line-height: 1.6;
            -webkit-font-smoothing: antialiased;
        }
        .container {
            max-width: 680px;
            margin: 0 auto;
            padding: 32px 28px 48px;
        }
        header {
            border-bottom: 1px solid var(--border);
            padding-bottom: 20px;
            margin-bottom: 28px;
        }
        h1 {
            font-size: 28px;
            font-weight: 700;
            margin: 0 0 6px;
            letter-spacing: -0.02em;
        }
        .subtitle {
            color: var(--muted);
            font-size: 15px;
            margin: 0;
        }
        h2 {
            font-size: 20px;
            font-weight: 600;
            margin: 32px 0 12px;
            letter-spacing: -0.01em;
        }
        h2:first-of-type { margin-top: 0; }
        p { margin: 0 0 14px; }
        ul { margin: 0 0 14px; padding-left: 22px; }
        li { margin: 0 0 8px; }
        .muted { color: var(--muted); }
        kbd {
            display: inline-block;
            padding: 1px 7px;
            font-family: -apple-system, BlinkMacSystemFont, "SF Mono", monospace;
            font-size: 13px;
            line-height: 1.5;
            background: var(--kbd-bg);
            border: 1px solid var(--kbd-border);
            border-radius: 5px;
            box-shadow: 0 1px 0 var(--kbd-border);
            white-space: nowrap;
        }
        .card {
            background: var(--card);
            border: 1px solid var(--border);
            border-radius: 12px;
            padding: 16px 20px;
            margin: 0 0 14px;
        }
        .steps {
            counter-reset: step;
            list-style: none;
            padding-left: 0;
        }
        .steps > li {
            position: relative;
            padding-left: 38px;
            margin-bottom: 14px;
        }
        .steps > li::before {
            counter-increment: step;
            content: counter(step);
            position: absolute;
            left: 0;
            top: 0;
            width: 26px;
            height: 26px;
            background: var(--accent);
            color: #fff;
            border-radius: 50%;
            text-align: center;
            line-height: 26px;
            font-size: 14px;
            font-weight: 600;
        }
        .tip {
            border-left: 3px solid var(--accent);
            padding: 4px 0 4px 16px;
            color: var(--muted);
            margin: 0 0 14px;
        }
        footer {
            margin-top: 36px;
            padding-top: 18px;
            border-top: 1px solid var(--border);
            color: var(--muted);
            font-size: 13px;
        }
    </style>
    </head>
    <body>
    <div class="container">
        <header>
            <h1>VoxBarber használata</h1>
            <p class="subtitle">Egyszerű, gyors hangfájl-szerkesztő macOS-re</p>
        </header>

        <h2>Áttekintés</h2>
        <p>
            A VoxBarber egy többablakos hangszerkesztő. Minden megnyitott vagy újonnan
            létrehozott hangfájl saját panelen jelenik meg a munkaterületen, ahol a
            hanghullámot megjelenítve lejátszhatod, kijelölheted és szerkesztheted.
        </p>

        <h2>Támogatott fájltípusok</h2>
        <p>
            A VoxBarber a legelterjedtebb hangformátumokat tudja megnyitni és lejátszani:
        </p>
        <div class="card">
            <ul style="margin-bottom: 0;">
                <li><strong>WAV</strong> (<span class="muted">.wav</span>) – tömörítetlen, veszteségmentes hang.</li>
                <li><strong>AIFF</strong> (<span class="muted">.aiff, .aif</span>) – tömörítetlen, veszteségmentes hang.</li>
                <li><strong>MP3</strong> (<span class="muted">.mp3</span>) – veszteségesen tömörített hang.</li>
                <li><strong>AAC / M4A</strong> (<span class="muted">.m4a, .aac</span>) – veszteségesen tömörített hang.</li>
                <li><strong>FLAC</strong> (<span class="muted">.flac</span>) – veszteségmentesen tömörített hang.</li>
                <li><strong>OGG</strong> (<span class="muted">.ogg</span>) – nyílt, veszteségesen tömörített hang.</li>
            </ul>
        </div>
        <p class="tip">
            Megjegyzés: a hangfájl megnyitásakor a program a hangot belső, szerkeszthető
            formátumra alakítja, így a szerkesztés és lejátszás a forrásformátumtól
            függetlenül azonos módon működik.
        </p>

        <h2>Első lépések</h2>
        <ol class="steps">
            <li><strong>Hangfájl megnyitása</strong> – válaszd a
                <em>Fájl › Hangfájl megnyitása</em> menüpontot (<kbd>⌘O</kbd>),
                majd jelöld ki a betölteni kívánt fájlt.</li>
            <li><strong>Új hangfájl</strong> – a <em>Fájl › Új hangfájl</em>
                menüponttal (<kbd>⌘N</kbd>) hozhatsz létre üres panelt, amelybe
                a vágólapról illeszthetsz be hangot.</li>
            <li><strong>Lejátszás</strong> – a panel eszköztárán a
                <kbd>▶︎ Play</kbd> gombbal indítsd el a lejátszást a kurzor pozíciójától.</li>
        </ol>

        <h2>Lejátszás vezérlése</h2>
        <ul>
            <li><strong>Play</strong> – lejátszás indítása a lejátszást jelölő vonal pozíciójától.</li>
            <li><strong>Pause</strong> – lejátszás szüneteltetése az aktuális pozíción.</li>
            <li><strong>Stop</strong> – lejátszás leállítása és visszaállás a kezdetre.</li>
            <li><strong>Ugrás a következő jelölőre</strong> – a lejátszás vonalát a következő markerre helyezi.</li>
            <li><strong>Ugrás a fájl végére</strong> – a lejátszás vonalát a hangfájl legvégére mozgatja.</li>
            <li><strong>Időpontra ugrás</strong> – pontos időpont megadásával pozícionálhatod a lejátszás vonalát.</li>
        </ul>

        <h2>Szerkesztés: másolás, kivágás, beillesztés</h2>
        <p>
            A szerkesztéshez először <strong>jelölj ki</strong> egy szakaszt a hanghullámon
            az egér húzásával. A kijelölés után aktívvá válnak a szerkesztő gombok:
        </p>
        <div class="card">
            <ul style="margin-bottom: 0;">
                <li><strong>Copy</strong> – a kijelölt szakasz a vágólapra másolása
                    (a hangfájl változatlan marad).</li>
                <li><strong>Cut</strong> – a kijelölt szakasz eltávolítása a fájlból és a
                    vágólapra helyezése; a „maradék” összezárul.</li>
                <li><strong>Paste</strong> – a vágólap tartalmának beillesztése a lejátszás
                    vonalának pozíciójára. Csak akkor aktív, ha van a vágólapon tartalom.</li>
            </ul>
        </div>
        <p class="tip">
            Tipp: a vágólap az alkalmazáson belül megosztott, így az egyik panelből kimásolt
            részletet egy másik panelbe (akár egy új, üres fájlba) is beillesztheted.
        </p>

        <h2>Jelölőpontok</h2>
        <p>
            A jelölőpontok (markerek) segítségével megjelölheted a hangfájl fontos
            pozícióit, és gyorsan ugorhatsz közöttük lejátszás közben.
        </p>
        <ul>
            <li><strong>Beszúrás</strong> – helyezd a lejátszás vonalát a kívánt pozícióra,
                majd a panel eszköztárán a <kbd>📍 Új jelölőpont</kbd> gombbal, vagy a
                <em>Szerkesztés › Új jelölőpont</em> menüponttal (<kbd>⌘M</kbd>) szúrj be
                jelölőt. Az új jelölő a kurzor (lejátszás közben az aktuális lejátszási)
                pozíciójára kerül, és a hangformán függőleges vonalként jelenik meg.</li>
            <li><strong>Elnevezés</strong> – minden új jelölő automatikus nevet kap
                (pl. <em>Jelölő 1</em>). A nevet a jelölőpontok listájában a név mezőbe
                kattintva bármikor átírhatod.</li>
            <li><strong>Listázás</strong> – a <em>Szerkesztés › Jelölőpontok listája</em>
                menüponttal megnyithatsz egy ablakot, amelyben időrendben látod az összes
                jelölőt. Itt átnevezheted, törölheted őket, illetve a listából a kívánt
                jelölőre navigálhatsz.</li>
            <li><strong>Ugrás jelölőre</strong> – az eszköztár
                <strong>Ugrás a következő jelölőre</strong> gombja a lejátszás vonalát az
                aktuális pozíció utáni első jelölőre helyezi (a végén körbeugorva az elsőre).</li>
        </ul>

        <h2>Nézet és nagyítás</h2>
        <ul>
            <li><strong>Nagyítás / kicsinyítés</strong> – a hanghullám részletesebb vagy
                átfogóbb megjelenítéséhez.</li>
            <li><strong>Görgetés</strong> – nagyított nézetben a hangfájl mentén navigálhatsz.</li>
            <li><strong>Időskála</strong> – a hanghullám alatt megjelenő időtengely a
                pontos pozícionálást segíti.</li>
        </ul>

        <h2>Ablakok kezelése</h2>
        <p>
            Több hangfájllal párhuzamosan dolgozhatsz. A <em>Nézet</em> menü
            <em>Ablak elrendezés mentése</em> és <em>betöltése</em> pontjaival
            elmentheted és visszatöltheted a panelek elrendezését.
        </p>

        <footer>
            VoxBarber súgó · A részletek a program verziójától függően eltérhetnek.
        </footer>
    </div>
    </body>
    </html>
    """
}

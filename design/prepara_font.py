"""Prepara i font per l'app Android, partendo dagli stessi file del PC.

Si lancia UNA VOLTA, a mano, e cio' che produce sta in git: chi clona il repo
costruisce l'APK **senza rete**, che per un prodotto offline-first non e' un
dettaglio ma il minimo.

Perche' non basta scaricare i .ttf e finirla li':

1. **Statici, non variabili.** Il file che Google serve copre i pesi da 400 a
   700 in un solo tracciato, e sul web funziona. In Flutter la mappatura fra
   `FontWeight` e l'asse `wght` di un font variabile non e' garantita da tutte
   le versioni: se non aggancia, TUTTO il testo esce col peso di riferimento e
   il guasto e' muto -- si vede solo guardando il telefono. Le istanze statiche
   tolgono la domanda: un file per peso, dichiarato con `weight:` nel pubspec.

2. **Solo latino.** Il font intero porta cirillico, greco e vietnamita: sono
   megabyte che nessuno leggera' mai in un'app italiana. I woff2 del PC Google
   li serve gia' ridotti; qui il taglio va fatto a mano, sullo STESSO
   repertorio, altrimenti le due app disegnerebbero due alfabeti diversi.

3. **La licenza viaggia col font.** L'APK e l'exe sono ridistribuzione a tutti
   gli effetti e la SIL OFL pretende che il testo della licenza sia incluso.

Serve fontTools, che **non va installato nel venv del progetto**: finirebbe
nell'exe (e' gia' successo con Pillow, +6 MB). Un venv usa-e-getta:

    py -3 -m venv %TEMP%\\vf && %TEMP%\\vf\\Scripts\\pip install fonttools brotli
    %TEMP%\\vf\\Scripts\\python design/prepara_font.py
"""

import io
import sys
import urllib.parse
import urllib.request
from pathlib import Path

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

RADICE = Path(__file__).resolve().parent.parent
DESTINAZIONE = RADICE / "mobile" / "assets" / "fonts"

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")

# I pesi sono quelli che l'app usa davvero (`grep FontWeight mobile/lib`), non
# tutta la scala: ogni peso in piu' e' un file in piu' dentro l'APK.
FAMIGLIE = [
    # (nome in Flutter, cartella in google/fonts, file, pesi)
    ("Inter", "inter", "Inter[opsz,wght].ttf", [400, 500, 600, 700]),
    ("SpaceGrotesk", "spacegrotesk", "SpaceGrotesk[wght].ttf", [600]),
    ("JetBrainsMono", "jetbrainsmono", "JetBrainsMono[wght].ttf", [400, 700]),
]

# Latin + Latin Extended-A, piu' la punteggiatura e i simboli che l'interfaccia
# usa davvero (euro, virgolette curve, lineette, punti elenco, il segno di
# moltiplicazione). Gli stessi intervalli dei sottoinsiemi "latin" e
# "latin-ext" di Google.
REPERTORIO = (
    "U+0000-00FF,U+0100-017F,U+0180-024F,U+0259,U+02BB-02BC,U+02C6,"
    "U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,"
    "U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD"
)


def prendi(url: str) -> bytes:
    r = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(r, timeout=120) as f:
        return f.read()


def main() -> int:
    DESTINAZIONE.mkdir(parents=True, exist_ok=True)
    totale = 0

    for nome, cartella, file, pesi in FAMIGLIE:
        url = ("https://raw.githubusercontent.com/google/fonts/main/ofl/"
               + cartella + "/" + urllib.parse.quote(file))
        print(f"{nome}: scarico il variabile...")
        grezzo = prendi(url)

        for peso in pesi:
            var = TTFont(io.BytesIO(grezzo))
            assi = {"wght": peso}
            # Inter ha anche l'asse `opsz` (dimensione ottica): lo fisso al
            # valore da testo corrente, altrimenti l'istanza resterebbe
            # variabile su quell'asse e ricadremmo nel problema 1.
            if any(a.axisTag == "opsz" for a in var["fvar"].axes):
                assi["opsz"] = 14
            statico = instancer.instantiateVariableFont(var, assi, inplace=True)

            opz = subset.Options()
            # Non "*": le funzioni OpenType che non usiamo (frazioni, maiuscoletto,
            # varianti stilistiche, cifre antiche) sono tabelle che pesano e che
            # nessuna schermata chiede mai. `tnum` invece resta: sono le cifre a
            # larghezza fissa, quelle che impediscono al contatore dei secondi di
            # ballare mentre scende.
            opz.layout_features = ["ccmp", "locl", "kern", "mark", "mkmk",
                                   "liga", "clig", "calt", "tnum", "zero"]
            opz.name_IDs = ["*"]
            opz.notdef_outline = True
            s = subset.Subsetter(options=opz)
            s.populate(unicodes=subset.parse_unicodes(REPERTORIO))
            s.subset(statico)

            uscita = DESTINAZIONE / f"{nome}-{peso}.ttf"
            statico.save(uscita)
            n = uscita.stat().st_size
            totale += n
            print(f"  {uscita.name:28s} {n/1024:7.1f} KB")

        lic = prendi("https://raw.githubusercontent.com/google/fonts/main/ofl/"
                     + cartella + "/OFL.txt")
        (DESTINAZIONE / f"OFL-{nome}.txt").write_bytes(lic)

    print(f"\ntotale dentro l'APK: {totale/1024:.1f} KB")
    return 0


if __name__ == "__main__":
    sys.exit(main())

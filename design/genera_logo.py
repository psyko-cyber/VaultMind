"""Ricava il logo del telefono (icona, splash, schermata di sblocco) da
`design/logo-originale.png`.

Perche' non basta ridimensionare l'originale, come si faceva fino al 16/09/2026:

1. **L'originale ha una toppa.** Nell'angolo in basso a destra c'e' un
   rettangolo di colore piatto incollato sopra l'immagine (con ogni probabilita'
   a coprire una filigrana). A 96 px quasi non si vede; nello splash di
   Android, grande mezzo schermo, si' -- e sembra un logo rotto.

2. **Lo sfondo del medaglione e' un quadrato.** Nell'icona adattiva il
   foreground conteneva l'immagine intera, sfondo blu compreso, e da Android 12
   lo splash ritaglia l'icona in un **cerchio** piu' piccolo del quadrato: ne
   usciva un quadrato con gli angoli smussati ad arco, di un blu diverso dal
   nero attorno. E' il "logo spezzato" della foto di Luca.

Quindi qui lo sfondo si **toglie** invece di ritagliarlo. Il medaglione e' luce
su uno sfondo scuro sfumato: si stima lo sfondo con una superficie liscia
(polinomio di secondo grado, ricavato dai soli pixel che sono sicuramente
sfondo), si sottrae, e cio' che resta -- la luce -- si posa su un colore unico,
[SFONDO]. Nessun contorno da scontornare a mano, nessun alone: dove non c'era
luce resta esattamente [SFONDO], e la toppa sparisce perche' li' di luce non ce
n'e'.

Per il foreground dell'icona adattiva il colore unico diventa **trasparenza**
("color to alpha"): composto sopra [SFONDO], che e' lo sfondo dell'icona e dello
splash, restituisce il pixel identico.

[SFONDO] e' il fondo del tema predefinito ("Scuro", blu e azzurro come il PC,
`tema.dart`): lo splash finisce e la prima schermata di Flutter comincia sullo
stesso colore, senza lampo.

Serve Pillow, che **non va nel venv del progetto** (finirebbe nell'exe, gia'
successo: +6 MB). Un venv usa-e-getta, come per `prepara_font.py`:

    py -3 -m venv %TEMP%\\vl && %TEMP%\\vl\\Scripts\\pip install pillow
    %TEMP%\\vl\\Scripts\\python design/genera_logo.py
    %TEMP%\\vl\\Scripts\\python design/genera_logo.py --anteprima CARTELLA

Non e' un passo di build: gira quando cambia l'originale, e cio' che produce
sta in git.
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw

RADICE = Path(__file__).resolve().parent.parent
ORIGINALE = RADICE / "design" / "logo-originale.png"
RES = RADICE / "mobile" / "android" / "app" / "src" / "main" / "res"

#: Il fondo di "Scuro" in `mobile/lib/tema.dart` (`--s0` del PC), e
#: `sfondo_icona` in `res/values/colors.xml`, e i colori di `web/index.html` e
#: `web/manifest.json`. Cambiarlo qui senza cambiarlo la' rimette l'alone.
SFONDO = (0x08, 0x0B, 0x14)

#: Quanto del foreground occupa il medaglione. Android garantisce visibile solo
#: il cerchio centrale di 66 dp su 108 (0,61): le punte del cristallo stanno a
#: 0,48 del lato dell'immagine, quindi a 0,62 arrivano a 0,30 dal centro, dentro.
SCALA_FOREGROUND = 0.62

#: Le densita' di Android: il foreground e' 108 dp, l'icona classica 48 dp.
DENSITA = {"mdpi": 1.0, "hdpi": 1.5, "xhdpi": 2.0, "xxhdpi": 3.0, "xxxhdpi": 4.0}


# --------------------------------------------------------------------------
# Pulizia dell'originale
# --------------------------------------------------------------------------

def trova_toppa(img: Image.Image) -> tuple[int, int] | None:
    """Il rettangolo di colore piatto ancorato in basso a destra.

    Si parte due pixel dentro: l'ultima riga e l'ultima colonna hanno gli
    angoli semitrasparenti, e il colore li' non e' quello della toppa.
    Restituisce l'angolo in alto a sinistra, o None se non c'e'.
    """
    px = img.load()
    w, h = img.size
    x0, y0 = w - 3, h - 3
    colore = px[x0, y0][:3]
    while x0 > 0 and px[x0 - 1, h - 3][:3] == colore:
        x0 -= 1
    while y0 > 0 and px[w - 3, y0 - 1][:3] == colore:
        y0 -= 1
    if w - x0 < 8 or h - y0 < 8:
        return None
    # Un tratto piatto su una riga puo' capitare anche in un'immagine sana: e'
    # una toppa solo se e' piatto quasi tutto il rettangolo.
    uguali = sum(
        px[x, y][:3] == colore for x in range(x0, w - 2) for y in range(y0, h - 2)
    )
    if uguali < 0.95 * (w - 2 - x0) * (h - 2 - y0):
        return None
    return x0, y0


def _risolvi(a: list[list[float]], b: list[float]) -> list[float]:
    """Eliminazione di Gauss con pivot: sei incognite, niente numpy."""
    n = len(b)
    m = [riga[:] + [b[i]] for i, riga in enumerate(a)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(m[r][c]))
        m[c], m[p] = m[p], m[c]
        for r in range(n):
            if r != c and m[c][c]:
                f = m[r][c] / m[c][c]
                for k in range(c, n + 1):
                    m[r][k] -= f * m[c][k]
    return [m[i][n] / m[i][i] for i in range(n)]


def _base(x: float, y: float) -> list[float]:
    return [1.0, x, y, x * x, x * y, y * y]


def stima_sfondo(img: Image.Image, toppa: tuple[int, int] | None):
    """Una superficie liscia per canale che descrive lo sfondo sfumato.

    Campioni: i pixel **scuri e lontani dal centro**, fuori dalla toppa. Il
    vicino al centro si esclude perche' dentro lo scudo ci sono zone scure che
    sono disegno, non sfondo. Due passate: la seconda scarta i campioni che la
    prima spiega male (un pezzo di cristallo in penombra).
    """
    px = img.load()
    w, h = img.size
    cx, cy = (w - 1) / 2, (h - 1) / 2

    def norm(x, y):
        return (x - cx) / cx, (y - cy) / cy

    campioni = []
    for y in range(1, h - 1):
        for x in range(1, w - 1):
            if toppa and x >= toppa[0] and y >= toppa[1]:
                continue
            r, g, b, _ = px[x, y]
            if 0.3 * r + 0.59 * g + 0.11 * b > 40:
                continue
            if math.hypot(x - cx, y - cy) < 0.30 * w:
                continue
            campioni.append((x, y, (r, g, b)))

    def adatta(punti):
        coeff = []
        for ch in range(3):
            ata = [[0.0] * 6 for _ in range(6)]
            atb = [0.0] * 6
            for x, y, rgb in punti:
                v = _base(*norm(x, y))
                for i in range(6):
                    atb[i] += v[i] * rgb[ch]
                    for j in range(6):
                        ata[i][j] += v[i] * v[j]
            coeff.append(_risolvi(ata, atb))
        return coeff

    def valuta(coeff, x, y):
        v = _base(*norm(x, y))
        return [sum(c * b for c, b in zip(coeff[ch], v)) for ch in range(3)]

    coeff = adatta(campioni)
    buoni = [
        (x, y, rgb) for x, y, rgb in campioni
        if max(abs(a - b) for a, b in zip(rgb, valuta(coeff, x, y))) < 8
    ]
    coeff = adatta(buoni)
    scarto = sum(
        max(abs(a - b) for a, b in zip(rgb, valuta(coeff, x, y))) for x, y, rgb in buoni
    ) / len(buoni)
    print(f"  sfondo stimato su {len(buoni)} pixel, scarto medio {scarto:.1f} livelli")
    return lambda x, y: valuta(coeff, x, y)


#: Sotto questa luce (in livelli sopra lo sfondo stimato) un pixel e' sfondo, e
#: si spegne con una rampa fino a PIENA. Senza, il rumore della stima -- due o
#: tre livelli -- disegnava sul nero dello splash il quadrato dell'immagine e il
#: bordo della toppa: invisibili a 256 px, visibili a mezzo schermo.
SOGLIA, PIENA = 3, 12

#: Le punte del cristallo arrivano a 0,48 del lato dal centro. Oltre, la luce si
#: spegne entro 0,53: negli angoli la superficie stimata sbaglia di piu', e un
#: alone d'angolo sul nero disegna di nuovo il quadrato.
RAGGIO_PIENO, RAGGIO_SPENTO = 0.49, 0.53

#: La toppa taglia di netto la punta del cristallo in basso a destra (sopra il
#: bordo ci sono pixel a 150 livelli), e lungo il bordo c'e' una colonna di
#: pixel mescolati. Una rampa di questa larghezza, in pixel dell'originale,
#: chiude la punta invece di troncarla.
RAMPA_TOPPA = 5


def _peso_toppa(x: int, y: int, toppa: tuple[int, int] | None) -> float:
    if not toppa:
        return 1.0
    x0, y0 = toppa
    if x >= x0 and y >= y0:
        return 0.0
    if x < x0 and y < y0:
        d = max(x0 - x, y0 - y)
    else:
        d = x0 - x if x < x0 else y0 - y
    return min(1.0, d / RAMPA_TOPPA)


def medaglione_su_sfondo(img: Image.Image) -> Image.Image:
    """L'originale con lo sfondo sostituito da [SFONDO]: RGB opaco."""
    img = img.convert("RGBA")
    toppa = trova_toppa(img)
    if toppa:
        print(f"  toppa trovata da ({toppa[0]}, {toppa[1]}) all'angolo: la tolgo")
    sfondo = stima_sfondo(img, toppa)
    px = img.load()
    w, h = img.size
    out = Image.new("RGB", (w, h))
    po = out.load()
    cx, cy = (w - 1) / 2, (h - 1) / 2
    for y in range(h):
        for x in range(w):
            vicino = _peso_toppa(x, y, toppa)
            r = math.hypot(x - cx, y - cy) / w
            lontano = min(1.0, max(0.0, (RAGGIO_SPENTO - r) / (RAGGIO_SPENTO - RAGGIO_PIENO)))
            if vicino == 0 or lontano == 0:
                po[x, y] = SFONDO  # sotto la toppa non c'e' luce da salvare
                continue
            s = sfondo(x, y)
            # Solo la luce: le pieghe piu' scure dello sfondo, posate su un
            # quasi nero, finirebbero comunque a zero.
            luce = [max(0.0, px[x, y][c] - s[c]) for c in range(3)]
            t = min(1.0, max(0.0, (max(luce) - SOGLIA) / (PIENA - SOGLIA)))
            peso = t * t * (3 - 2 * t) * vicino * lontano
            po[x, y] = tuple(
                min(255, round(SFONDO[c] + luce[c] * peso)) for c in range(3)
            )
    return out


# --------------------------------------------------------------------------
# Uscite
# --------------------------------------------------------------------------

def colore_in_trasparenza(img: Image.Image) -> Image.Image:
    """Toglie [SFONDO] lasciando la luce: composto sopra [SFONDO] ridà `img`.

    Per ogni pixel si cerca l'opacita' minima con cui un colore posato su
    [SFONDO] lo riproduce; e' il "color to alpha" dei programmi di grafica.
    """
    out = Image.new("RGBA", img.size)
    pi, po = img.load(), out.load()
    for y in range(img.size[1]):
        for x in range(img.size[0]):
            c = pi[x, y]
            a = 0.0
            for k in range(3):
                t = SFONDO[k]
                # Mai piu' scuro di SFONDO: medaglione_su_sfondo tiene solo la
                # luce, e il ricampionamento LANCZOS che scende sotto di un
                # livello non merita un pixel opaco nero.
                if c[k] > t:
                    a = max(a, (c[k] - t) / (255 - t))
            if a <= 0:
                po[x, y] = (0, 0, 0, 0)
                continue
            a = min(1.0, a)
            po[x, y] = tuple(
                max(0, min(255, round(SFONDO[k] + max(0, c[k] - SFONDO[k]) / a)))
                for k in range(3)
            ) + (round(a * 255),)
    return out


def foreground(med: Image.Image, lato: int) -> Image.Image:
    tela = Image.new("RGB", (lato, lato), SFONDO)
    m = round(lato * SCALA_FOREGROUND)
    tela.paste(med.resize((m, m), Image.LANCZOS), ((lato - m) // 2, (lato - m) // 2))
    return colore_in_trasparenza(tela)


def icona_classica(med: Image.Image, lato: int) -> Image.Image:
    """Per Android prima dell'8, che non ritaglia: il quadrato arrotondato lo
    disegniamo noi. Maschera a 4x per avere il bordo liscio."""
    tela = Image.new("RGB", (lato, lato), SFONDO)
    m = round(lato * 0.86)
    tela.paste(med.resize((m, m), Image.LANCZOS), ((lato - m) // 2, (lato - m) // 2))
    grande = lato * 4
    maschera = Image.new("L", (grande, grande), 0)
    ImageDraw.Draw(maschera).rounded_rectangle(
        (0, 0, grande - 1, grande - 1), radius=round(grande * 0.2), fill=255
    )
    out = tela.convert("RGBA")
    out.putalpha(maschera.resize((lato, lato), Image.LANCZOS))
    return out


def icona_piena(med: Image.Image, lato: int, scala: float) -> Image.Image:
    """Quadrato opaco di [SFONDO] col medaglione al centro. Per il web: iOS
    arrotonda da se' l'icona della Home e non vuole trasparenze (le riempie
    di nero), e le icone "maskable" del manifest le ritaglia il sistema."""
    tela = Image.new("RGB", (lato, lato), SFONDO)
    m = round(lato * scala)
    tela.paste(med.resize((m, m), Image.LANCZOS), ((lato - m) // 2, (lato - m) // 2))
    return tela


def anteprima(med: Image.Image, cartella: Path) -> None:
    """Lo splash di Android 12 simulato, e l'icona a 22 px: e' a quella misura
    che si giudica (regola del progetto), non a 256."""
    cartella.mkdir(parents=True, exist_ok=True)
    fg = foreground(med, 432)
    schermo = Image.new("RGB", (540, 960), SFONDO)
    schermo.paste(fg.resize((400, 400), Image.LANCZOS), (70, 280), fg.resize((400, 400), Image.LANCZOS))
    schermo.save(cartella / "splash.png")
    # Lo stesso schiarito 6 volte: un bordo a tre livelli sul quasi nero non
    # lo vede l'occhio sul monitor, lo vede su un OLED al buio.
    schermo.point(lambda v: min(255, v * 6)).save(cartella / "splash-schiarito.png")
    icona = Image.new("RGBA", (432, 432), SFONDO + (255,))
    icona.alpha_composite(fg)
    cerchio = Image.new("L", (432, 432), 0)
    ImageDraw.Draw(cerchio).ellipse((36, 36, 395, 395), fill=255)
    icona.putalpha(cerchio)
    fondo = Image.new("RGBA", (432 * 2 + 44 + 22, 432), (230, 230, 230, 255))
    fondo.alpha_composite(icona, (0, 0))
    fondo.alpha_composite(icona.resize((22, 22), Image.LANCZOS), (432 + 22, 205))
    fondo.alpha_composite(icona.resize((44, 44), Image.LANCZOS), (432 + 66, 194))
    fondo.save(cartella / "icona.png")
    print(f"  anteprime in {cartella}")


def main() -> int:
    print(f"Leggo {ORIGINALE.relative_to(RADICE)}")
    med = medaglione_su_sfondo(Image.open(ORIGINALE))

    if "--anteprima" in sys.argv:
        anteprima(med, Path(sys.argv[sys.argv.index("--anteprima") + 1]))
        return 0

    # Sblocco: tessera opaca, la arrotonda Flutter (ClipRRect). Opaca perche'
    # col tema chiaro una luce su trasparente sbiadirebbe.
    med.save(RADICE / "mobile" / "assets" / "logo.png", optimize=True)
    for nome, d in DENSITA.items():
        cartella = RES / f"mipmap-{nome}"
        foreground(med, round(108 * d)).save(cartella / "ic_launcher_foreground.png", optimize=True)
        icona_classica(med, round(48 * d)).save(cartella / "ic_launcher.png", optimize=True)
    print("Fatto: assets/logo.png e mipmap-*/ic_launcher{,_foreground}.png")

    # Versione browser (iPhone). "maskable" a SCALA_FOREGROUND per la stessa
    # ragione dell'icona adattiva: il sistema ne tiene solo il cerchio centrale.
    web = RADICE / "mobile" / "web"
    for lato in (192, 512):
        icona_piena(med, lato, 0.80).save(web / "icons" / f"Icon-{lato}.png", optimize=True)
        icona_piena(med, lato, SCALA_FOREGROUND).save(
            web / "icons" / f"Icon-maskable-{lato}.png", optimize=True)
    icona_piena(med, 180, 0.80).save(web / "icons" / "apple-touch-icon.png", optimize=True)
    icona_piena(med, 32, 0.95).save(web / "favicon.png", optimize=True)
    print("Fatto: web/icons/*.png e web/favicon.png")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

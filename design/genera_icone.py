"""Riversa `design/icone.json` nelle tre app.

Perche' un generatore invece di scrivere le icone a mano nei tre posti: le
icone sono lo stesso disegno su PC, estensione e Android, ma i tre formati
sono incompatibili (uno sprite SVG, un altro sprite SVG piu' piccolo, e del
codice Dart che dipinge su una `Canvas`). Copiarle a mano vuol dire che alla
prima correzione due copie su tre restano indietro senza che nulla si rompa in
modo evidente -- lo stesso guaio che i colori hanno gia' oggi, e che infatti
costringe a un commento in ogni file che implora di aggiornarli tutti e tre.

Non e' un passo di build: gira quando *cambiano le icone*, e cio' che produce
sta in git. `index.html` resta monolitico e apribile com'e'.

Il pezzo meno ovvio e' il traduttore da SVG a Dart. Flutter non sa leggere un
attributo `d`, e i pacchetti che lo fanno non li vogliamo (regola del
progetto). Quindi il tracciato lo interpreta **Python**, qui, una volta sola, ed
emette chiamate esplicite -- `p.cubicTo(...)`, `p.arcToPoint(...)`. Sul
telefono non resta nessun parser da far girare a ogni fotogramma.

Uso:
    py -3 design/genera_icone.py            scrive
    py -3 design/genera_icone.py --verifica  controlla e basta (esce 1 se cambia)
"""

from __future__ import annotations

import json
import math
import re
import sys
from pathlib import Path as FsPath

RADICE = FsPath(__file__).resolve().parent.parent
SORGENTE = RADICE / "design" / "icone.json"

# I tre bersagli. L'estensione prende solo cio' che usa: il popup e' un
# pannello di 360 px con cinque icone, non ha senso spedirgli il set intero.
SOLO_ESTENSIONE = [
    "copia", "estensione", "impostazioni", "lucchetto", "occhio",
    "scudo-ok", "spunta",
]

MARCA_SPRITE = ("<!-- ICONE:INIZIO -->", "<!-- ICONE:FINE -->")
MARCA_GRIGLIA = ("<!-- GRIGLIA-ICONE:INIZIO -->", "<!-- GRIGLIA-ICONE:FINE -->")


# --------------------------------------------------------------------------
# Lettura del tracciato SVG
# --------------------------------------------------------------------------

_NUMERO = re.compile(r"[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?")
_COMANDO = re.compile(r"([MmLlHhVvCcSsQqTtAaZz])")


def _pezzi(d: str):
    """Spezza un attributo `d` in (lettera, [numeri...])."""
    parti = _COMANDO.split(d)
    fuori = []
    i = 1
    while i < len(parti):
        lettera = parti[i]
        numeri = [float(n) for n in _NUMERO.findall(parti[i + 1])]
        fuori.append((lettera, numeri))
        i += 2
    return fuori


def _quanti(lettera: str) -> int:
    return {
        "M": 2, "L": 2, "H": 1, "V": 1, "C": 6,
        "S": 4, "Q": 4, "T": 2, "A": 7, "Z": 0,
    }[lettera.upper()]


def in_dart(d: str) -> list[str]:
    """Traduce un tracciato SVG in chiamate Dart su una `Path` chiamata `p`.

    Tutto viene reso assoluto qui: in Dart i comandi relativi non esistono, e
    ricalcolarli a runtime vorrebbe dire riportare sul telefono proprio il
    parser che stiamo evitando.
    """
    righe: list[str] = []
    x = y = 0.0          # punto corrente
    sx = sy = 0.0        # inizio del sottotracciato (per Z)
    cx = cy = None       # ultimo punto di controllo, per S e T
    ultimo = ""

    def n(v: float) -> str:
        # `12.0` in Dart e' un double valido e piu' corto di `12.000000`;
        # gli interi restano interi perche' Dart li promuove da se'.
        return f"{v:g}"

    for lettera, numeri in _pezzi(d):
        rel = lettera.islower()
        L = lettera.upper()
        passo = _quanti(L)

        if L == "Z":
            righe.append("p.close();")
            x, y = sx, sy
            cx = cy = None
            ultimo = "Z"
            continue

        # Un comando puo' portarsi dietro piu' gruppi di argomenti:
        # "L 1 2 3 4" sono due segmenti. Dopo il primo, una M implicita
        # diventa L (e' la regola SVG, e senza di essa i contorni si spezzano).
        primo = True
        for i in range(0, len(numeri), passo):
            a = numeri[i:i + passo]
            if len(a) < passo:
                break
            eff = L
            if L == "M" and not primo:
                eff = "L"

            if eff == "M":
                nx, ny = (x + a[0], y + a[1]) if rel else (a[0], a[1])
                righe.append(f"p.moveTo({n(nx)}, {n(ny)});")
                x, y = nx, ny
                sx, sy = nx, ny
                cx = cy = None
            elif eff == "L":
                nx, ny = (x + a[0], y + a[1]) if rel else (a[0], a[1])
                righe.append(f"p.lineTo({n(nx)}, {n(ny)});")
                x, y = nx, ny
                cx = cy = None
            elif eff == "H":
                nx = x + a[0] if rel else a[0]
                righe.append(f"p.lineTo({n(nx)}, {n(y)});")
                x = nx
                cx = cy = None
            elif eff == "V":
                ny = y + a[0] if rel else a[0]
                righe.append(f"p.lineTo({n(x)}, {n(ny)});")
                y = ny
                cx = cy = None
            elif eff == "C":
                p = [x + v if rel and k % 2 == 0 else y + v if rel else v
                     for k, v in enumerate(a)]
                righe.append(
                    f"p.cubicTo({n(p[0])}, {n(p[1])}, {n(p[2])}, {n(p[3])}, "
                    f"{n(p[4])}, {n(p[5])});")
                cx, cy = p[2], p[3]
                x, y = p[4], p[5]
            elif eff == "S":
                p = [x + v if rel and k % 2 == 0 else y + v if rel else v
                     for k, v in enumerate(a)]
                # Il primo controllo e' il riflesso del precedente: e' cio'
                # che rende "liscia" la giunzione, ed e' tutto il senso di S.
                if ultimo in ("C", "S") and cx is not None:
                    r1x, r1y = 2 * x - cx, 2 * y - cy
                else:
                    r1x, r1y = x, y
                righe.append(
                    f"p.cubicTo({n(r1x)}, {n(r1y)}, {n(p[0])}, {n(p[1])}, "
                    f"{n(p[2])}, {n(p[3])});")
                cx, cy = p[0], p[1]
                x, y = p[2], p[3]
            elif eff == "Q":
                p = [x + v if rel and k % 2 == 0 else y + v if rel else v
                     for k, v in enumerate(a)]
                righe.append(
                    f"p.quadraticBezierTo({n(p[0])}, {n(p[1])}, "
                    f"{n(p[2])}, {n(p[3])});")
                cx, cy = p[0], p[1]
                x, y = p[2], p[3]
            elif eff == "T":
                p = [x + v if rel and k % 2 == 0 else y + v if rel else v
                     for k, v in enumerate(a)]
                if ultimo in ("Q", "T") and cx is not None:
                    r1x, r1y = 2 * x - cx, 2 * y - cy
                else:
                    r1x, r1y = x, y
                righe.append(
                    f"p.quadraticBezierTo({n(r1x)}, {n(r1y)}, "
                    f"{n(p[0])}, {n(p[1])});")
                cx, cy = r1x, r1y
                x, y = p[0], p[1]
            elif eff == "A":
                rx, ry, rot, grande, orario, ax, ay = a
                if rel:
                    ax, ay = x + ax, y + ay
                righe.append(
                    f"p.arcToPoint(const Offset({n(ax)}, {n(ay)}), "
                    f"radius: const Radius.elliptical({n(abs(rx))}, {n(abs(ry))}), "
                    f"rotation: {n(math.radians(rot))}, "
                    f"largeArc: {'true' if grande else 'false'}, "
                    f"clockwise: {'true' if orario else 'false'});")
                x, y = ax, ay
                cx = cy = None

            ultimo = eff
            primo = False

    return righe


# --------------------------------------------------------------------------
# I tre formati
# --------------------------------------------------------------------------

def sprite_svg(icone: dict, nomi: list[str], rientro: str = "") -> str:
    """Lo sprite `<symbol>` da incollare nell'HTML.

    Nessun attributo di tratto sui figli: `stroke`, `stroke-width` e i due
    `linecap`/`linejoin` arrivano per ereditarieta' dall'elemento `<svg>` che
    fa `<use>`. Metterli qui li renderebbe impossibili da cambiare dal CSS, e
    con loro sparirebbe anche `currentColor` -- cioe' le icone smetterebbero
    di seguire il tema.
    """
    fuori = []
    for nome in nomi:
        forme = icone[nome]["forme"]
        pezzi = []
        for f in forme:
            if "d" in f:
                pezzi.append(f'<path d="{f["d"]}"/>')
            elif "cerchio" in f:
                cx, cy, r = f["cerchio"]
                pezzi.append(f'<circle cx="{cx}" cy="{cy}" r="{r}"/>')
            elif "rett" in f:
                x, y, w, h, r = f["rett"]
                pezzi.append(
                    f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}"/>')
            else:
                raise SystemExit(f"forma sconosciuta in '{nome}': {f}")
        fuori.append(
            f'{rientro}<symbol id="i-{nome}" viewBox="0 0 24 24">'
            + "".join(pezzi) + "</symbol>")
    corpo = "\n".join(fuori)
    return (
        f'{rientro}<svg width="0" height="0" aria-hidden="true" '
        f'style="position:absolute">\n{corpo}\n{rientro}</svg>'
    )


def griglia_anteprima(icone: dict, nomi: list[str]) -> str:
    fuori = []
    for nome in nomi:
        titolo = icone[nome]["titolo"]
        fuori.append(
            f'  <figure class="ico-cella" title="{titolo}">'
            f'<svg class="ic ic-32" aria-hidden="true"><use href="#i-{nome}"/></svg>'
            f'<figcaption>{nome}</figcaption></figure>')
    return "\n".join(fuori)


def dart(icone: dict, nomi: list[str]) -> str:
    corpi = []
    for nome in nomi:
        metodo = _dartizza(nome)
        righe = ["  final p = Path();"]
        for f in icone[nome]["forme"]:
            if "d" in f:
                righe += [f"  {r}" for r in in_dart(f["d"])]
            elif "cerchio" in f:
                cx, cy, r = f["cerchio"]
                righe.append(
                    f"  p.addOval(Rect.fromCircle("
                    f"center: const Offset({cx}, {cy}), radius: {r}));")
            elif "rett" in f:
                x, y, w, h, r = f["rett"]
                righe.append(
                    f"  p.addRRect(RRect.fromLTRBR({x}, {y}, {x + w}, {y + h}, "
                    f"const Radius.circular({r})));")
        righe.append("  return p;")
        corpi.append(f"Path _{metodo}() {{\n" + "\n".join(righe) + "\n}")

    voci = "\n".join(
        f"  static const String {_dartizza(n)} = '{n}';" for n in nomi)
    mappa = "\n".join(f"  '{n}': _{_dartizza(n)}," for n in nomi)

    return f'''// GENERATO DA design/genera_icone.py -- non modificare a mano.
// La sorgente e' design/icone.json; dopo averla cambiata:
//     py -3 design/genera_icone.py

/// Le icone di VaultMind, le stesse identiche del PC e dell'estensione.
///
/// Sono tracciati, non un font e non `Icons.*`: cosi' le tre app disegnano lo
/// stesso lucchetto, invece di tre lucchetti che si somigliano. I comandi SVG
/// sono gia' stati tradotti in chiamate su `Path` dal generatore, quindi qui
/// non c'e' niente da interpretare a runtime e nessun pacchetto in piu'.
///
/// Il colore arriva da `currentColor` come sul web: se non lo si passa,
/// `IconaVM` prende `IconTheme.of(context).color`, che il tema riempie da se'.
library;

import 'package:flutter/widgets.dart';

class Icone {{
{voci}
}}

/// Disegna un'icona da 24x24 alla misura richiesta.
class IconaVM extends StatelessWidget {{
  const IconaVM(this.nome, {{super.key, this.size = 24, this.color}});

  final String nome;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {{
    final c = color ??
        IconTheme.of(context).color ??
        DefaultTextStyle.of(context).style.color ??
        const Color(0xFF000000);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _PittoreIcona(nome, c)),
    );
  }}
}}

class _PittoreIcona extends CustomPainter {{
  _PittoreIcona(this.nome, this.colore);

  final String nome;
  final Color colore;

  @override
  void paint(Canvas tela, Size misura) {{
    final p = _cache.putIfAbsent(nome, () => _tracciati[nome]!());
    final k = misura.width / 24.0;
    tela.save();
    tela.scale(k);
    tela.drawPath(
      p,
      Paint()
        ..style = PaintingStyle.stroke
        // 1.5 nelle unita' della griglia 24, non in pixel: `scale()` lo
        // moltiplica insieme al resto. E' quello che fa anche il browser con
        // un `viewBox` di 24, quindi le due app restano identiche a ogni
        // misura -- che e' tutto il punto di generarle da una sorgente sola.
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = colore,
    );
    tela.restore();
  }}

  @override
  bool shouldRepaint(_PittoreIcona v) => v.nome != nome || v.colore != colore;
}}

final Map<String, Path> _cache = {{}};

const Map<String, Path Function()> _tracciati = {{
{mappa}
}};

{chr(10).join(corpi)}
'''


def _dartizza(nome: str) -> str:
    parti = nome.split("-")
    return parti[0] + "".join(p.capitalize() for p in parti[1:])


# --------------------------------------------------------------------------

def sostituisci(testo: str, marca: tuple[str, str], nuovo: str, dove: str) -> str:
    inizio, fine = marca
    i = testo.find(inizio)
    j = testo.find(fine)
    if i < 0 or j < 0:
        raise SystemExit(f"{dove}: mancano i marcatori {inizio} / {fine}")
    return testo[: i + len(inizio)] + "\n" + nuovo + "\n" + testo[j:]


def scrivi(percorso: FsPath, contenuto: str, verifica: bool) -> bool:
    prima = percorso.read_text(encoding="utf-8") if percorso.exists() else None
    if prima == contenuto:
        return False
    if verifica:
        print(f"  DIVERSO  {percorso.relative_to(RADICE)}")
        return True
    percorso.write_text(contenuto, encoding="utf-8", newline="\n")
    print(f"  scritto  {percorso.relative_to(RADICE)}")
    return True


def main() -> int:
    verifica = "--verifica" in sys.argv
    dati = json.loads(SORGENTE.read_text(encoding="utf-8"))
    icone = dati["icone"]
    tutti = list(icone)

    mancanti = [n for n in SOLO_ESTENSIONE if n not in icone]
    if mancanti:
        raise SystemExit(f"l'estensione chiede icone che non esistono: {mancanti}")

    cambiato = False

    # 1. anteprima: sprite completo + griglia illustrata
    ant = RADICE / "design" / "anteprima.html"
    if ant.exists():
        t = ant.read_text(encoding="utf-8")
        t = sostituisci(t, MARCA_SPRITE, sprite_svg(icone, tutti), str(ant))
        t = sostituisci(t, MARCA_GRIGLIA, griglia_anteprima(icone, tutti), str(ant))
        cambiato |= scrivi(ant, t, verifica)

    # 2. app PC
    pc = RADICE / "VaultMind_Windows" / "app" / "web" / "index.html"
    if pc.exists() and MARCA_SPRITE[0] in pc.read_text(encoding="utf-8"):
        t = pc.read_text(encoding="utf-8")
        t = sostituisci(t, MARCA_SPRITE, sprite_svg(icone, tutti), str(pc))
        cambiato |= scrivi(pc, t, verifica)

    # 3. estensione
    ext = RADICE / "extension" / "popup.html"
    if ext.exists() and MARCA_SPRITE[0] in ext.read_text(encoding="utf-8"):
        t = ext.read_text(encoding="utf-8")
        t = sostituisci(t, MARCA_SPRITE, sprite_svg(icone, SOLO_ESTENSIONE), str(ext))
        cambiato |= scrivi(ext, t, verifica)

    # 4. Android
    mob = RADICE / "mobile" / "lib" / "icone.dart"
    if mob.parent.exists():
        cambiato |= scrivi(mob, dart(icone, tutti), verifica)

    if verifica and cambiato:
        print("Le icone generate non sono allineate a design/icone.json.")
        return 1
    if not cambiato:
        print("Gia' allineato.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

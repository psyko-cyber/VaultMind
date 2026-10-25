"""
qr.py — Il QR che il PC mostra per collegare un telefono.

Scritto qui e non preso da una libreria per due ragioni: nel venv non ce n'è
nessuna, e ogni pacchetto aggiunto al venv finisce dentro l'exe (vedi
`run.ps1`). Il QR serve a una cosa sola — un indirizzo di un centinaio di
caratteri — e per quella bastano la modalità «byte» e la correzione d'errore
M (regge un 15% di immagine rovinata: riflessi sullo schermo, mano che trema).

È la ricetta dello standard ISO/IEC 18004 nella forma resa celebre da Project
Nayuki (qrcodegen, licenza MIT), ridotta a quello che serve. Non si prova
guardandolo: `tests/test_qr.py` lo fa **decodificare** a `web/jsQR.js`, un
lettore scritto da altri, per ogni versione che può uscire da qui.
"""

from __future__ import annotations
from typing import List

# Per versione (indice 1..40): byte di correzione per blocco, e numero di
# blocchi. Due righe sole, livello M: è l'unico che usiamo.
_ECC_PER_BLOCCO_M = (
    -1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26,
    26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28)
_BLOCCHI_M = (
    -1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16,
    17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49)
_FORMATO_M = 0   # i due bit del livello M nell'informazione di formato

_MASCHERE = (
    lambda x, y: (x + y) % 2,
    lambda x, y: y % 2,
    lambda x, y: x % 3,
    lambda x, y: (x + y) % 3,
    lambda x, y: (x // 3 + y // 2) % 2,
    lambda x, y: x * y % 2 + x * y % 3,
    lambda x, y: (x * y % 2 + x * y % 3) % 2,
    lambda x, y: ((x + y) % 2 + x * y % 3) % 2,
)


def _moduli_dati(ver: int) -> int:
    """Quanti moduli restano per i dati dopo i disegni fissi."""
    n = (16 * ver + 128) * ver + 64
    if ver >= 2:
        allineamenti = ver // 7 + 2
        n -= (25 * allineamenti - 10) * allineamenti - 55
        if ver >= 7:
            n -= 36
    return n


def _byte_dati(ver: int) -> int:
    return _moduli_dati(ver) // 8 - _ECC_PER_BLOCCO_M[ver] * _BLOCCHI_M[ver]


def _moltiplica(x: int, y: int) -> int:
    """Prodotto nel campo GF(2^8) con il polinomio 0x11D dello standard."""
    z = 0
    for i in reversed(range(8)):
        z = (z << 1) ^ ((z >> 7) * 0x11D)
        z ^= ((y >> i) & 1) * x
    return z


def _divisore(grado: int) -> List[int]:
    r = [0] * (grado - 1) + [1]
    radice = 1
    for _ in range(grado):
        for j in range(grado):
            r[j] = _moltiplica(r[j], radice)
            if j + 1 < grado:
                r[j] ^= r[j + 1]
        radice = _moltiplica(radice, 0x02)
    return r


def _resto(dati: List[int], divisore: List[int]) -> List[int]:
    r = [0] * len(divisore)
    for b in dati:
        fattore = b ^ r.pop(0)
        r.append(0)
        for i, coeff in enumerate(divisore):
            r[i] ^= _moltiplica(coeff, fattore)
    return r


class _Simbolo:
    def __init__(self, ver: int):
        self.ver = ver
        self.lato = ver * 4 + 17
        self.scuro = [[False] * self.lato for _ in range(self.lato)]
        self.fisso = [[False] * self.lato for _ in range(self.lato)]

    def metti(self, x: int, y: int, scuro: bool) -> None:
        self.scuro[y][x] = scuro
        self.fisso[y][x] = True

    # ---------------------------------------------------------- disegni fissi

    def allineamenti(self) -> List[int]:
        if self.ver == 1:
            return []
        n = self.ver // 7 + 2
        passo = (self.ver * 8 + n * 3 + 5) // (n * 4 - 4) * 2
        pos = [self.lato - 7 - i * passo for i in range(n - 1)] + [6]
        return list(reversed(pos))

    def disegna_fissi(self) -> None:
        for i in range(self.lato):
            self.metti(6, i, i % 2 == 0)
            self.metti(i, 6, i % 2 == 0)
        for cx, cy in ((3, 3), (self.lato - 4, 3), (3, self.lato - 4)):
            for dy in range(-4, 5):
                for dx in range(-4, 5):
                    x, y = cx + dx, cy + dy
                    if 0 <= x < self.lato and 0 <= y < self.lato:
                        self.metti(x, y, max(abs(dx), abs(dy)) not in (2, 4))
        pos = self.allineamenti()
        n = len(pos)
        for i in range(n):
            for j in range(n):
                if (i, j) in ((0, 0), (0, n - 1), (n - 1, 0)):
                    continue   # lì ci sono già i tre quadrati d'angolo
                for dy in range(-2, 3):
                    for dx in range(-2, 3):
                        self.metti(pos[i] + dx, pos[j] + dy, max(abs(dx), abs(dy)) != 1)
        self.disegna_formato(0)   # segnaposto: la maschera vera si sa dopo
        self.disegna_versione()

    def disegna_formato(self, maschera: int) -> None:
        dati = _FORMATO_M << 3 | maschera
        r = dati
        for _ in range(10):
            r = (r << 1) ^ ((r >> 9) * 0x537)
        bit = (dati << 10 | r) ^ 0x5412

        def b(i):
            return (bit >> i) & 1 != 0

        for i in range(6):
            self.metti(8, i, b(i))
        self.metti(8, 7, b(6))
        self.metti(8, 8, b(7))
        self.metti(7, 8, b(8))
        for i in range(9, 15):
            self.metti(14 - i, 8, b(i))
        for i in range(8):
            self.metti(self.lato - 1 - i, 8, b(i))
        for i in range(8, 15):
            self.metti(8, self.lato - 15 + i, b(i))
        self.metti(8, self.lato - 8, True)   # sempre scuro, da standard

    def disegna_versione(self) -> None:
        if self.ver < 7:
            return
        r = self.ver
        for _ in range(12):
            r = (r << 1) ^ ((r >> 11) * 0x1F25)
        bit = self.ver << 12 | r
        for i in range(18):
            scuro = (bit >> i) & 1 != 0
            a, b = self.lato - 11 + i % 3, i // 3
            self.metti(a, b, scuro)
            self.metti(b, a, scuro)

    # ------------------------------------------------------------------- dati

    def disegna_dati(self, parole: List[int]) -> None:
        i = 0
        destra = self.lato - 1
        while destra >= 1:
            if destra == 6:
                destra = 5   # la colonna del cronometro si salta
            for v in range(self.lato):
                for j in range(2):
                    x = destra - j
                    su = ((destra + 1) & 2) == 0
                    y = self.lato - 1 - v if su else v
                    if not self.fisso[y][x] and i < len(parole) * 8:
                        self.scuro[y][x] = (parole[i >> 3] >> (7 - (i & 7))) & 1 != 0
                        i += 1
            destra -= 2

    def applica_maschera(self, m: int) -> None:
        f = _MASCHERE[m]
        for y in range(self.lato):
            for x in range(self.lato):
                if not self.fisso[y][x] and f(x, y) == 0:
                    self.scuro[y][x] = not self.scuro[y][x]

    def penalita(self) -> int:
        """Quanto il disegno è difficile da leggere (regole 1-4 dello standard).

        Ogni maschera produce un QR valido; questa sceglie quella che evita
        strisce lunghe, blocchi pieni e falsi quadrati d'angolo, cioè ciò che
        fa sbagliare una fotocamera. La regola 3 è contata in modo semplice,
        cercando lo schema e non con la storia delle corse: qui serve un
        buon QR, non il punteggio identico a quello di un altro programma."""
        n = self.lato
        m = self.scuro
        p = 0
        righe = [m[y] for y in range(n)]
        colonne = [[m[y][x] for y in range(n)] for x in range(n)]
        for linea in righe + colonne:
            corsa, colore = 0, None
            for c in linea:
                if c == colore:
                    corsa += 1
                else:
                    if corsa >= 5:
                        p += 3 + (corsa - 5)
                    colore, corsa = c, 1
            if corsa >= 5:
                p += 3 + (corsa - 5)
            testo = "".join("1" if c else "0" for c in linea)
            for schema in ("10111010000", "00001011101"):
                inizio = testo.find(schema)
                while inizio != -1:
                    p += 40
                    inizio = testo.find(schema, inizio + 1)
        for y in range(n - 1):
            for x in range(n - 1):
                if m[y][x] == m[y][x + 1] == m[y + 1][x] == m[y + 1][x + 1]:
                    p += 3
        scuri = sum(1 for riga in m for c in riga if c)
        totale = n * n
        k = (abs(scuri * 20 - totale * 10) + totale - 1) // totale - 1
        return p + k * 10


def _parole(dati: bytes, ver: int) -> List[int]:
    """I byte del messaggio in modalità «byte», con riempimento e correzione
    d'errore già intrecciati nell'ordine in cui vanno disegnati."""
    bit: List[int] = []

    def aggiungi(valore: int, quanti: int) -> None:
        for i in reversed(range(quanti)):
            bit.append((valore >> i) & 1)

    aggiungi(0b0100, 4)
    aggiungi(len(dati), 8 if ver <= 9 else 16)
    for b in dati:
        aggiungi(b, 8)
    capienza = _byte_dati(ver) * 8
    aggiungi(0, min(4, capienza - len(bit)))
    aggiungi(0, (-len(bit)) % 8)
    parole = [int("".join(map(str, bit[i:i + 8])), 2) for i in range(0, len(bit), 8)]
    riempi = 0xEC
    while len(parole) < _byte_dati(ver):
        parole.append(riempi)
        riempi ^= 0xEC ^ 0x11

    blocchi = _BLOCCHI_M[ver]
    ecc = _ECC_PER_BLOCCO_M[ver]
    grezze = _moduli_dati(ver) // 8
    corti = blocchi - grezze % blocchi
    lung_corto = grezze // blocchi
    div = _divisore(ecc)
    pezzi = []
    k = 0
    for i in range(blocchi):
        d = parole[k:k + lung_corto - ecc + (0 if i < corti else 1)]
        k += len(d)
        e = _resto(d, div)
        if i < corti:
            d = d + [0]   # segnaposto, saltato all'intreccio
        pezzi.append(d + e)
    fuori = []
    for i in range(len(pezzi[0])):
        for j, blocco in enumerate(pezzi):
            if i != lung_corto - ecc or j >= corti:
                fuori.append(blocco[i])
    return fuori


def matrice(testo: str) -> List[List[bool]]:
    """Il QR come righe di moduli (True = scuro), senza margine."""
    dati = testo.encode("utf-8")
    for ver in range(1, 41):
        conteggio = 8 if ver <= 9 else 16
        if 4 + conteggio + len(dati) * 8 <= _byte_dati(ver) * 8:
            break
    else:
        raise ValueError("Testo troppo lungo per un QR.")
    s = _Simbolo(ver)
    s.disegna_fissi()
    s.disegna_dati(_parole(dati, ver))
    migliore, punteggio = 0, None
    for m in range(8):
        s.applica_maschera(m)
        s.disegna_formato(m)
        p = s.penalita()
        if punteggio is None or p < punteggio:
            migliore, punteggio = m, p
        s.applica_maschera(m)   # XOR: due volte la stessa maschera la toglie
    s.applica_maschera(migliore)
    s.disegna_formato(migliore)
    return s.scuro


def svg(testo: str, margine: int = 4) -> str:
    """Il QR come SVG, nero su bianco **sempre**, anche col tema scuro: un
    QR chiaro su fondo scuro molte fotocamere non lo leggono. I quattro moduli
    di margine bianco sono parte dello standard, non estetica."""
    m = matrice(testo)
    n = len(m) + 2 * margine
    tratti = []
    for y, riga in enumerate(m):
        for x, scuro in enumerate(riga):
            if scuro:
                tratti.append(f"M{x + margine} {y + margine}h1v1h-1z")
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {n} {n}" '
            f'shape-rendering="crispEdges" role="img" aria-label="QR per collegare il telefono">'
            f'<rect width="{n}" height="{n}" fill="#fff"/>'
            f'<path fill="#000" d="{"".join(tratti)}"/></svg>')

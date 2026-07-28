"""
search.py — Indice di recupero deterministico.

Per ogni credenziale costruiamo un "documento" (titolo + tag + etichette dei
campi + valori NON segreti) e ne calcoliamo l'embedding una volta sola.
Alla query:
  1. embedding della richiesta;
  2. similarità coseno con tutte le voci;
  3. bonus lessicale per match esatti sul titolo/tag/etichette, con
     espansione di ALIAS di brand (gmail↔google↔youtube, outlook↔microsoft…);
  4. ordinamento e rilevazione dell'ambiguità: raggruppa TUTTE le voci che
     condividono col risultato migliore lo stesso termine-chiave della query
     (es. tutti gli account "google").

Nessuna password viene usata per l'indicizzazione né inviata da nessuna parte.
"""

from __future__ import annotations
import re
import unicodedata
from typing import List, Tuple

import numpy as np

from .embedding import Embeddings
from .crypto_store import Credential

_STOP = {
    "dammi", "dimmi", "dammela", "la", "le", "il", "lo", "i", "gli", "un", "una", "uno",
    "di", "del", "della", "dello", "dei", "delle", "dell", "nell", "sull", "all", "quell",
    "dall", "coll", "mia", "mio", "mie", "miei", "per",
    "quella", "quello", "quelli", "quelle", "cosa", "roba", "tipo",
    "password", "pass", "pwd", "credenziali", "credenziale", "account", "qual", "quale",
    "e", "ed", "a", "ad", "da", "su", "in", "con", "che", "mostrami", "mostra",
    "trova", "trovami", "cerca", "cercami", "fammi", "vedere", "recupera", "ho", "voglio",
    "serve", "mi", "anche", "the", "of", "my", "me", "tutti", "tutte", "miei", "mie",
}

# Alias di brand: termini diversi che indicano lo stesso "account". Applicati sia
# alla query sia ai token indicizzati, così "google account" trova anche le voci
# il cui titolo/tag dice "gmail" o "youtube". Tutto offline, dizionario statico.
_ALIASES = {
    # Solo famiglia Google, SENZA gmail: "google" non tira piu' su le voci gmail
    # via alias, e "gmail" matcha solo voci gmail. Gli altri brand NON hanno piu'
    # alias: il match avviene sui token letterali di titolo/tag/etichette
    # (es. una voce con titolo "Outlook" e tag "microsoft" esce cercando "microsoft").
    "google": "google",
    "youtube": "google",
    "gsuite": "google",
    "workspace": "google",
    "drive": "google",
}

# Etichette i cui VALORI sono segreti: non li indicizziamo nell'embedding.
_SECRET_HINTS = ("password", "pass", "pwd", "pin", "puc", "puk", "otp", "totp",
                 "2fa", "mfa", "secret", "segreto", "seed", "recovery", "backup",
                 "cvv", "token", "chiave", "key", "codice", "code")


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFD", s.lower())
    s = "".join(c for c in s if unicodedata.category(c) != "Mn")
    s = re.sub(r"[^a-z0-9@.\s]", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def _tokens(s: str) -> List[str]:
    return [t for t in _norm(s).split(" ") if t and t not in _STOP]


def _alias_expand(toks: set) -> set:
    out = set(toks)
    for t in toks:
        a = _ALIASES.get(t)
        if a:
            out.add(a)
    return out


def _is_secret_label(label: str) -> bool:
    l = _norm(label)
    return any(h in l for h in _SECRET_HINTS)


def _clean_for_embedding(s: str) -> str:
    """Testo senza filler/stopword, usato SOLO per calcolare l'embedding.
    Aggiunge gli alias di brand così la query 'google' si avvicina ai doc 'gmail'."""
    toks = _alias_expand(set(_tokens(s)))
    return " ".join(sorted(toks)) if toks else _norm(s)


def _doc(c: Credential) -> str:
    """Documento indicizzato: titolo + tag + etichette + VALORI non segreti.
    I valori segreti (password/PIN/PUC/OTP…) non entrano mai nell'indice."""
    labels = " ".join(f.label for f in c.fields)
    vals = " ".join(f.value for f in c.fields if not _is_secret_label(f.label))
    return f"{c.title} {' '.join(c.tags)} {labels} {vals}"


def _searchable_tokens(c: Credential) -> set:
    """Token 'forti' per matching/raggruppamento: titolo + tag + etichette,
    espansi con alias di brand. NON include i valori (evita di raggruppare ogni
    servizio registrato con una gmail sotto 'google')."""
    toks = set(_tokens(c.title)) | set(_tokens(" ".join(c.tags))) \
        | set(_tokens(" ".join(f.label for f in c.fields)))
    return _alias_expand(toks)


def _lexical_bonus(query: str, c: Credential) -> float:
    q = _alias_expand(set(_tokens(query)))
    if not q:
        return 0.0
    title = _alias_expand(set(_tokens(c.title)))
    hay = _searchable_tokens(c)
    bonus = 0.0
    for t in q:
        if t in title:
            bonus += 0.45          # match esatto nel titolo: domina
        elif t in hay:
            bonus += 0.24          # match esatto su tag/etichette/alias (clear soglia da solo)
        elif any(len(t) >= 4 and len(h) >= 4 and (h in t or t in h) for h in hay):
            bonus += 0.05          # substring debole: contributo minimo
    return min(bonus, 0.9)


def _matched_tokens(query: str, c: Credential) -> set:
    """Token della query (con alias) che combaciano coi token forti della voce."""
    q = _alias_expand(set(_tokens(query)))
    return q & _searchable_tokens(c)


class SearchResult:
    def __init__(self, cred: Credential, score: float, matched: set | None = None):
        self.cred = cred
        self.score = score
        self.matched = matched or set()


class SearchIndex:
    def __init__(self, embeddings: Embeddings):
        self.emb = embeddings
        self._creds: List[Credential] = []
        self._matrix: np.ndarray | None = None

    def build(self, creds: List[Credential]) -> None:
        self._creds = list(creds)
        if creds:
            self._matrix = self.emb.encode([_clean_for_embedding(_doc(c)) for c in creds])
        else:
            self._matrix = None

    @property
    def creds(self) -> List[Credential]:
        """Voci attualmente indicizzate (sola lettura, per metadati non sensibili)."""
        return self._creds

    def query(self, text: str, top_k: int = 8) -> List[SearchResult]:
        if not self._creds or self._matrix is None:
            return []
        qv = self.emb.encode([_clean_for_embedding(text)])[0]
        sims = self._matrix @ qv  # coseno (vettori normalizzati)
        results = []
        for i, c in enumerate(self._creds):
            score = float(sims[i]) + _lexical_bonus(text, c)
            results.append(SearchResult(c, score, _matched_tokens(text, c)))
        results.sort(key=lambda r: r.score, reverse=True)
        return results[:top_k]


def interpret(results: List[SearchResult],
              min_score: float = 0.22,
              ambig_gap: float = 0.14,
              max_group: int = 6) -> Tuple[str, List[SearchResult]]:
    """
    Decide come rispondere:
      - "none"     : nessun risultato sopra soglia
      - "single"   : un vincitore chiaro -> [risultato]
      - "ambiguous": più voci ugualmente pertinenti -> [da scegliere]

    Regola di ambiguità (sui match lessicali): si guarda QUANTI termini della
    query ciascuna voce combacia (matched-set). La voce che ne combacia di più
    è più specifica e vince. Si è ambigui solo quando più voci hanno lo stesso
    numero (massimo) di termini combaciati: es. due account "google", tre
    "home banking" senza nome banca. Un termine discriminante (es. "intesa")
    risolve da solo verso quella voce.
    """
    strong = [r for r in results if r.score >= min_score]
    if not strong:
        return "none", []
    if len(strong) == 1:
        return "single", strong[:1]

    # Ambiguità basata sulla specificità dei match lessicali.
    maxlen = max(len(r.matched) for r in strong)
    if maxlen > 0:
        most_specific = [r for r in strong if len(r.matched) == maxlen]
        if len(most_specific) > 1:
            return "ambiguous", most_specific[:max_group]
        return "single", most_specific[:1]

    # Nessun match lessicale: decisione puramente semantica (coseno) col gap.
    top = strong[0]
    if top.score - strong[1].score >= ambig_gap:
        return "single", strong[:1]
    picks = [r for r in strong if top.score - r.score < ambig_gap][:max_group]
    return ("ambiguous", picks) if len(picks) > 1 else ("single", strong[:1])

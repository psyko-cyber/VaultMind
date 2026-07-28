"""
embedding.py — Backend di embedding "pluggable".

Strategia:
  - Se è installato `sentence-transformers`, usa il modello locale
    all-MiniLM-L6-v2 (scaricato una volta, poi 100% offline) per ottenere
    veri embedding semantici. Questa è la modalità fedele al prodotto.
  - Altrimenti, ripiega su un vettorizzatore char-n-gram con hashing,
    in puro Python + NumPy: nessun download, gira ovunque subito.
    Cattura comunque match parziali e refusi sui titoli disordinati.

In entrambi i casi il recupero a valle (search.py) è DETERMINISTICO:
nearest-neighbor su coseno, niente generazione.
"""

from __future__ import annotations
import hashlib
from typing import List

import numpy as np


def _l2_normalize(mat: np.ndarray) -> np.ndarray:
    norms = np.linalg.norm(mat, axis=1, keepdims=True)
    norms[norms == 0] = 1.0
    return mat / norms


class _HashingNgram:
    """Fallback senza dipendenze pesanti: char 3-gram -> spazio a dimensione fissa."""

    def __init__(self, dim: int = 1024):
        self.dim = dim

    def _vec(self, text: str) -> np.ndarray:
        text = f"  {text.lower()}  "
        v = np.zeros(self.dim, dtype=np.float32)
        for n in (3, 4):
            for i in range(len(text) - n + 1):
                gram = text[i:i + n]
                h = int(hashlib.md5(gram.encode("utf-8")).hexdigest(), 16)
                v[h % self.dim] += 1.0
        return v

    def encode(self, texts: List[str]) -> np.ndarray:
        mat = np.vstack([self._vec(t) for t in texts]) if texts else np.zeros((0, self.dim), np.float32)
        return _l2_normalize(mat)


class Embeddings:
    def __init__(self):
        self.backend = "hashing-ngram (fallback)"
        self._model = None
        try:
            from sentence_transformers import SentenceTransformer  # type: ignore
            self._model = SentenceTransformer("all-MiniLM-L6-v2")
            self.backend = "sentence-transformers / all-MiniLM-L6-v2"
        except Exception:
            self._model = _HashingNgram()

    def encode(self, texts: List[str]) -> np.ndarray:
        if not texts:
            return np.zeros((0, 1), dtype=np.float32)
        vecs = self._model.encode(texts)
        vecs = np.asarray(vecs, dtype=np.float32)
        if vecs.ndim == 1:
            vecs = vecs.reshape(1, -1)
        return _l2_normalize(vecs)

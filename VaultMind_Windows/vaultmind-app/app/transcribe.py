"""
transcribe.py — Trascrizione vocale locale OPZIONALE (Whisper).

Se è installato `faster-whisper` (vedi requirements-audio.txt), l'audio
registrato dal microfono viene trascritto in locale, sul tuo PC: nessun byte
lascia il dispositivo. Il modello "base" (~150 MB) si scarica una volta sola al
primo uso, poi funziona offline.

Se il modulo non è installato, l'app resta perfettamente funzionante: il
pulsante microfono mostra semplicemente un messaggio che spiega come abilitarlo.
"""

from __future__ import annotations
import os
import tempfile

_MODEL = None
MODEL_SIZE = os.environ.get("VAULTMIND_WHISPER_MODEL", "base")


def _backend() -> str | None:
    try:
        import faster_whisper  # noqa: F401
        return "faster-whisper"
    except Exception:
        return None


def available() -> bool:
    return _backend() is not None


def _get_model():
    global _MODEL
    if _MODEL is None:
        from faster_whisper import WhisperModel
        _MODEL = WhisperModel(MODEL_SIZE, device="cpu", compute_type="int8")
    return _MODEL


def transcribe_bytes(data: bytes, suffix: str = ".webm", language: str = "it") -> str:
    """Trascrive i byte audio (formato del MediaRecorder del browser, di norma webm/opus).
    Solleva RuntimeError se nessun backend è disponibile."""
    if not available():
        raise RuntimeError("Backend di trascrizione non disponibile.")
    fd, path = tempfile.mkstemp(suffix=suffix)
    os.close(fd)
    try:
        with open(path, "wb") as f:
            f.write(data)
        model = _get_model()
        # vad_filter richiede l'asset silero_vad, spesso assente nel .exe frozen.
        # Lo disattiviamo: la trascrizione funziona comunque (il VAD serviva solo
        # a tagliare i silenzi). Così evitiamo l'errore ONNX NO_SUCHFILE.
        segments, _info = model.transcribe(path, language=language, vad_filter=False)
        return " ".join(seg.text for seg in segments).strip()
    finally:
        if os.path.exists(path):
            os.remove(path)

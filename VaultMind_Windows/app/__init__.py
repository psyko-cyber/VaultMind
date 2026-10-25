"""VaultMind — gestore di credenziali locale con interfaccia chat."""

#: LA versione del prodotto, per tutte e tre le piattaforme. Da qui la leggono
#: l'app (Impostazioni e controllo aggiornamenti), `installer/rilascio.ps1`
#: (che la passa a Inno Setup e la usa come tag della release) e il test
#: `tests/test_versione.py`, che si lamenta se `mobile/pubspec.yaml` o
#: `mobile/lib/versione.dart` dicono un numero diverso.
#:
#: Era "0.1.0" mentre l'installer dichiarava 6.8: due numeri scollegati non
#: servono a niente, e col controllo degli aggiornamenti un numero sbagliato
#: qui significa non aggiornarsi mai (o riscaricare in continuazione).
__version__ = "7.0"

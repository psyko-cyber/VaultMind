/// La versione dell'app, scritta in un posto solo.
library;

/// Il numero che l'app mostra in Impostazioni e confronta col tag dell'ultima
/// release su GitHub.
///
/// Deve dire lo stesso numero di `VaultMind_Windows/app/__init__.py` e di
/// `version:` in `pubspec.yaml`: PC e telefono escono dalla stessa release,
/// quindi dallo stesso numero. Lo controlla `tests/test_versione.py`, perché
/// tre posti da aggiornare a mano sono tre posti da dimenticare — e un numero
/// sbagliato qui significa un telefono che non si aggiorna mai, o che propone
/// di installare la versione che ha già.
///
/// Non si legge da `pubspec.yaml`: per farlo servirebbe `package_info_plus`,
/// cioè una dipendenza in più (e un plugin nativo) per leggere una stringa.
const versioneApp = '7.0';

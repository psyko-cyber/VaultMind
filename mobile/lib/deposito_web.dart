/// Il deposito nel browser: il `localStorage` del sito.
///
/// Perche' non IndexedDB, che e' "quello serio": qui si salvano pochi testi
/// interi, e `localStorage` scrive una chiave **in un colpo solo** -- o c'e' il
/// vault nuovo o c'e' quello vecchio, che e' la stessa garanzia del rename sul
/// telefono, senza transazioni da scrivere a mano. Il limite di Safari (circa
/// 5 MB) e' cinquanta volte il vault di Luca, 800 voci in 110 KB.
///
/// ## Il limite vero, detto all'utente
///
/// Su iPhone questa memoria appartiene all'**icona sulla schermata Home**:
/// togliere l'icona cancella il vault. E una pagina aperta in Safari, senza
/// icona, viene svuotata dopo sette giorni senza uso. Per questo
/// `schermate/installa.dart` chiede di aggiungere l'app alla Home prima di
/// tutto, e le schermate insistono sul backup.
library;

import 'package:web/web.dart' as web;

const _prefisso = 'vaultmind/';

Future<bool> esisteDeposito(String nome) async =>
    web.window.localStorage.getItem('$_prefisso$nome') != null;

Future<String?> leggiDeposito(String nome) async =>
    web.window.localStorage.getItem('$_prefisso$nome');

Future<void> scriviDeposito(String nome, String testo) async {
  try {
    web.window.localStorage.setItem('$_prefisso$nome', testo);
  } catch (e) {
    // Quasi sempre e' la quota. Il messaggio dice cosa fare, non il nome
    // dell'eccezione del browser.
    throw const FormatException(
        'Lo spazio del browser per VaultMind è pieno: il vault non è stato salvato.');
  }
}

Future<void> eliminaDeposito(String nome) async =>
    web.window.localStorage.removeItem('$_prefisso$nome');

Future<List<String>> nomiDeposito() async {
  final s = web.window.localStorage;
  return [
    for (var i = 0; i < s.length; i++)
      if (s.key(i) case final k? when k.startsWith(_prefisso)) k.substring(_prefisso.length)
  ];
}

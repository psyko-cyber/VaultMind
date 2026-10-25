/// Come parlano PC e telefono: la chiave del QR e i messaggi cifrati. Senza
/// socket.
///
/// Gemello di `VaultMind_Windows/app/sync_protocol.py`, legato a quello dal
/// vettore `tests/vettore/sync.json`: stessa chiave e stesso nonce devono dare
/// gli stessi byte nelle due lingue, o il primo collegamento fallirebbe sempre.
///
/// ## Perché è così semplice (ottobre 2026)
///
/// Il sync di prima ricavava le chiavi dalla master password e chiedeva un
/// codice di 6 cifre: un vault nato sul telefono, anche con la stessa
/// password, non poteva abbinarsi al PC in nessun modo. Adesso la fiducia la
/// decide **chi inquadra il QR**: il PC genera 32 byte a caso e li mostra, il
/// telefono li legge, e da lì ogni messaggio è cifrato con AES-256-GCM con
/// quella chiave. Chi non l'ha inquadrata non legge niente e non può scrivere
/// niente che l'altro accetti.
///
/// Un messaggio è una riga JSON; dentro `m` ci sono nonce (12 byte), testo
/// cifrato e tag (16 byte) in coda, come nel vault. L'AAD è `vaultmind-sync`:
/// un messaggio del sync non deve mai poter passare per un vault.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const int versioneSync = 1;
final Uint8List aadSync = Uint8List.fromList(utf8.encode('vaultmind-sync'));
const int lunghezzaChiaveSync = 32;

final _casuale = Random.secure();

/// Un messaggio che non si apre: chiave sbagliata, manomesso o malformato.
/// Per chi lo riceve la reazione è una sola: si chiude.
class MessaggioRifiutato implements Exception {
  final String motivo;
  const MessaggioRifiutato([this.motivo = 'Messaggio non decifrabile.']);
  @override
  String toString() => motivo;
}

String esa(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List daEsa(String s) {
  if (s.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(s)) {
    throw const FormatException('esadecimale non valido');
  }
  final fuori = Uint8List(s.length ~/ 2);
  for (var i = 0; i < fuori.length; i++) {
    fuori[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return fuori;
}

Uint8List _byteCasuali(int quanti) =>
    Uint8List.fromList(List.generate(quanti, (_) => _casuale.nextInt(256)));

/// Un identificativo per questo dispositivo. Casuale e non ricavato
/// dall'hardware: come etichetta un numero a caso va benissimo, senza dire
/// niente su di te.
String idDispositivo() => esa(_byteCasuali(8));

/// Metà dell'identificativo di un collegamento: il PC ne manda 8 byte, il
/// telefono ne aggiunge 8. Ogni messaggio lo ripete, così un messaggio
/// registrato da un collegamento vecchio non vale in uno nuovo.
String nuovaMetaSessione() => esa(_byteCasuali(8));

/// Il gettone del telefono: cambia a ogni modifica del vault. Vedi
/// `sync_gestore.dart`.
String nuovoGettone() => esa(_byteCasuali(8));

/// Cifra [dati] col JSON compatto di `jsonEncode`, che è anche quello di
/// Python con `separators=(",", ":")` e `ensure_ascii=False`. [nonce] a
/// parametro solo per il vettore di prova: in uso è sempre nuovo, perché due
/// messaggi con la stessa coppia chiave-nonce in GCM si smontano a vicenda.
Future<String> cifra(List<int> chiave, Map<String, dynamic> dati, {List<int>? nonce}) =>
    cifraTesto(chiave, jsonEncode(dati), nonce: nonce);

Future<String> cifraTesto(List<int> chiave, String chiaro, {List<int>? nonce}) async {
  final n = nonce ?? _byteCasuali(12);
  final scatola = await AesGcm.with256bits().encrypt(
    utf8.encode(chiaro),
    secretKey: SecretKey(chiave),
    nonce: n,
    aad: aadSync,
  );
  return base64.encode([...n, ...scatola.cipherText, ...scatola.mac.bytes]);
}

Future<Map<String, dynamic>> decifra(List<int> chiave, String testo) async {
  // Cattura larga: arriva dalla rete, e un messaggio storto può avere
  // qualunque forma. La conclusione è sempre la stessa.
  Object? dati;
  try {
    final grezzo = base64.decode(testo);
    if (grezzo.length < 12 + 16) throw const FormatException('troppo corto');
    final chiaro = await AesGcm.with256bits().decrypt(
      SecretBox(grezzo.sublist(12, grezzo.length - 16),
          nonce: grezzo.sublist(0, 12), mac: Mac(grezzo.sublist(grezzo.length - 16))),
      secretKey: SecretKey(chiave),
      aad: aadSync,
    );
    dati = jsonDecode(utf8.decode(chiaro));
  } catch (_) {
    throw const MessaggioRifiutato();
  }
  if (dati is! Map<String, dynamic>) {
    throw const MessaggioRifiutato('Il messaggio non è un oggetto.');
  }
  return dati;
}

// ------------------------------------------------------------------- il QR

/// Cosa c'è nel QR che mostra il PC.
class QrPc {
  final int versione;
  final String idPc, nome;
  final Uint8List chiave;
  const QrPc(this.versione, this.idPc, this.nome, this.chiave);
}

/// Legge `vaultmind://abbina?v=1&pc=…&k=…&n=…`. Solleva [FormatException]
/// con un messaggio che dice **cosa ha letto**: chi inquadra per sbaglio il
/// QR di un sito deve sapere che non è quello giusto, non che «non va».
QrPc leggiQr(String testo) {
  final t = testo.trim();
  Uri u;
  try {
    u = Uri.parse(t);
  } catch (_) {
    throw FormatException('Questo QR non è di VaultMind: dice «${_corto(t)}».');
  }
  if (u.scheme != 'vaultmind' || u.host != 'abbina') {
    throw FormatException('Questo QR non è quello del PC: dice «${_corto(t)}».');
  }
  final q = u.queryParameters;
  final v = int.tryParse(q['v'] ?? '');
  if (v != versioneSync) {
    throw const FormatException(
        'Il QR viene da una versione diversa di VaultMind: aggiorna le due app.');
  }
  final pc = q['pc'] ?? '';
  Uint8List chiave;
  try {
    chiave = daEsa(q['k'] ?? '');
  } catch (_) {
    chiave = Uint8List(0);
  }
  if (pc.isEmpty || chiave.length != lunghezzaChiaveSync) {
    throw const FormatException('Il QR è incompleto: riprova inquadrandolo da più vicino.');
  }
  return QrPc(v!, pc, q['n'] ?? '', chiave);
}

String _corto(String t) => t.length <= 40 ? t : '${t.substring(0, 40)}…';

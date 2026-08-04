/// Abbinamento e autenticazione fra dispositivi. Senza socket.
///
/// Qui c'è **solo il ragionamento**: come due dispositivi si dimostrano di
/// essere tuoi, come si accorgono di qualcuno in mezzo, e come si riconoscono
/// le volte successive. La rete sta altrove, la fusione dei dati in
/// `fusione.dart`.
///
/// Gemello di `VaultMind_Windows/app/sync_protocol.py`, legato a quello dal
/// vettore `tests/vettore/sync.json`: se le due implementazioni calcolassero
/// prove diverse, l'abbinamento fallirebbe **sempre** — e senza il vettore lo
/// si scoprirebbe con due dispositivi veri in mano.
///
/// ## L'idea, in una riga
///
/// **Il segreto condiviso c'è già.** Due dispositivi che aprono lo stesso vault
/// derivano la stessa chiave a 256 bit dalla master password. Non serve
/// inventare uno scambio di chiavi: basta dimostrare di saperla, senza mai
/// trasmetterla.
///
/// ## Cosa protegge, e cosa no
///
/// Il confine della sicurezza è **la master password**. Chi la conosce possiede
/// il vault, e quindi può anche abbinare un dispositivo. L'elenco dei
/// dispositivi fidati non difende da lui: serve a te, per decidere e revocare.
///
/// Da lì discende una scelta che evita un problema intero: le chiavi per
/// parlare con ciascun dispositivo **non si generano e non si salvano**, si
/// ricavano al volo dalla chiave del vault. Sul telefono resta un elenco di
/// nomi e date, e chi lo legge non ci trova niente da usare.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Cifre del codice di abbinamento e dell'impronta.
const int cifreCodice = 6;

/// Quanto vive un codice di abbinamento, in secondi.
const int validitaCodiceS = 120;

/// Tentativi ammessi su uno stesso codice, poi si butta.
const int tentativiMax = 5;

// Etichette del protocollo. Cambiarne una rompe l'abbinamento fra versioni
// diverse: è voluto, perché una versione che calcola prove diverse deve
// fallire subito e non a metà di un trasferimento.
final List<int> _infoSessione = utf8.encode('vaultmind-sync-v1');
final List<int> _infoPeer = utf8.encode('vaultmind-peer-v1');

final _casuale = Random.secure();

/// HKDF-SHA256 (RFC 5869), scritto a mano su `package:crypto`.
///
/// A mano e non con la versione di `package:cryptography` perché quella è
/// asincrona e qui serve poter calcolare dentro un confronto. L'algoritmo è
/// standard, quindi Python ottiene gli stessi identici byte.
List<int> _hkdf(List<int> ikm, List<int> salt, List<int> info, [int lunghezza = 32]) {
  final prk = Hmac(sha256, salt).convert(ikm).bytes;
  final fuori = <int>[];
  var blocco = <int>[];
  var i = 1;
  while (fuori.length < lunghezza) {
    blocco = Hmac(sha256, prk).convert([...blocco, ...info, i]).bytes;
    fuori.addAll(blocco);
    i++;
  }
  return fuori.sublist(0, lunghezza);
}

/// Byte in cifre decimali, per farle leggere a una persona.
///
/// **Sei byte, non otto**: gli interi di Dart sono a 64 bit con segno, quelli
/// di Python non hanno limite. Con otto byte di là il numero resterebbe
/// positivo e di qua diventerebbe negativo, e i due schermi mostrerebbero
/// codici diversi senza che niente si rompa in modo evidente.
String _cifre(List<int> dato, int quante) {
  var n = 0;
  for (var i = 0; i < 6 && i < dato.length; i++) {
    n = (n << 8) | dato[i];
  }
  var limite = 1;
  for (var i = 0; i < quante; i++) {
    limite *= 10;
  }
  return (n % limite).toString().padLeft(quante, '0');
}

String _esa(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List daEsa(String s) {
  final fuori = Uint8List(s.length ~/ 2);
  for (var i = 0; i < fuori.length; i++) {
    fuori[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return fuori;
}

// ------------------------------------------------------------------ sessione

/// Numero usato una volta sola. Ogni abbinamento ne genera uno per parte: è ciò
/// che impedisce di riusare una conversazione registrata ieri.
Uint8List nonce() =>
    Uint8List.fromList(List.generate(16, (_) => _casuale.nextInt(256)));

/// Le sei cifre da mostrare. Da `Random.secure()`: un codice indovinabile
/// vanificherebbe il fatto stesso di chiederlo.
String codiceAbbinamento() =>
    _cifre(List.generate(8, (_) => _casuale.nextInt(256)), cifreCodice);

/// La chiave valida per QUESTO abbinamento: nasce dalla chiave del vault più i
/// due nonce, quindi cambia a ogni sessione.
List<int> chiaveSessione(List<int> chiaveVault, List<int> nonceA, List<int> nonceB) =>
    _hkdf(chiaveVault, [...nonceA, ...nonceB], _infoSessione);

/// La dimostrazione di conoscere la chiave del vault, senza mostrarla.
///
/// Il [ruolo] ("A" per chi mostra il codice, "B" per chi lo scrive) fa sì che
/// le due prove siano diverse: senza, chi riceve la prova di A potrebbe
/// rimandarla indietro spacciandosi per B. Il [codice] entra nel calcolo: è
/// così che l'abbinamento resta legato alle sei cifre lette sull'altro schermo.
String prova(List<int> sessione, String ruolo, String codice) => _esa(
    Hmac(sha256, sessione).convert(utf8.encode('prova:$ruolo:$codice')).bytes);

/// Confronto a tempo costante: `==` su una stringa esce al primo byte diverso,
/// e il tempo che ci mette dice quanti ne aveva indovinati.
bool verificaProva(List<int> sessione, String ruolo, String codice, String? ricevuta) =>
    _confrontoCostante(prova(sessione, ruolo, codice), ricevuta ?? '');

bool _confrontoCostante(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// Le sei cifre da confrontare a occhio sui due schermi, in due gruppi da tre
/// perché si leggano ad alta voce senza sbagliare.
String improntaSessione(List<int> sessione) {
  final c = _cifre(
      Hmac(sha256, sessione).convert(utf8.encode('impronta')).bytes, cifreCodice);
  return '${c.substring(0, 3)} ${c.substring(3)}';
}

// ------------------------------------------- riconoscersi le volte successive

/// Un identificativo per questo dispositivo. Casuale e non ricavato
/// dall'hardware: il MAC address si falsifica in un minuto e Android lo
/// randomizza per rete, quindi come serratura non regge — e come etichetta un
/// numero a caso va benissimo, senza dire niente su di te.
String idDispositivo() =>
    _esa(List.generate(8, (_) => _casuale.nextInt(256)));

/// La chiave per parlare con un dispositivo già abbinato.
///
/// **Si ricava, non si salva.** È il motivo per cui sul telefono non finisce
/// nessun segreto nuovo.
List<int> chiaveVerso(List<int> chiaveVault, String idPeer) =>
    _hkdf(chiaveVault, utf8.encode(idPeer), _infoPeer);

/// Come ci si riconosce senza codice, dopo il primo abbinamento.
String rispostaSfida(List<int> chiaveVault, String idPeer, List<int> sfida) =>
    _esa(Hmac(sha256, chiaveVerso(chiaveVault, idPeer)).convert(sfida).bytes);

bool verificaSfida(
        List<int> chiaveVault, String idPeer, List<int> sfida, String? ricevuta) =>
    _confrontoCostante(rispostaSfida(chiaveVault, idPeer, sfida), ricevuta ?? '');

// ------------------------------------------------------------------ il vault

/// Un'etichetta che dice «questi due vault hanno la stessa chiave», senza
/// rivelarla.
///
/// Serve a distinguere due fallimenti che si assomigliano e chiedono cose
/// opposte: «non ci siamo capiti sulla rete» e «hai cambiato la master password
/// su un dispositivo e non sull'altro». Il secondo non si risolve riprovando:
/// va rimandato il vault.
String improntaVault(List<int> chiaveVault) => _esa(
        Hmac(sha256, chiaveVault).convert(utf8.encode('quale-vault')).bytes)
    .substring(0, 16);

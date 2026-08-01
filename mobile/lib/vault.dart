/// Lettura del vault VaultMind.
///
/// Deve aprire ESATTAMENTE gli stessi file prodotti dall'app Windows: il
/// formato è il contratto fra le due piattaforme, documentato in
/// `tests/vettore/LEGGIMI.md` e difeso dal vettore di prova.
/// Chi tocca questo file esegua `flutter test`: apre il vettore vero.
///
/// Il vault non lascia il dispositivo, e la master password non viene mai
/// salvata: da lei si deriva la chiave, che resta in memoria per la sessione.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Parametri del formato. Devono combaciare con `crypto_store.py`: cambiarne
/// uno qui, senza cambiarlo là, produce vault che l'altra piattaforma non apre.
const int kArgon2TimeCost = 3;
const int kArgon2MemoryKiB = 64 * 1024;
const int kArgon2Parallelism = 2;
const int kKeyLength = 32; // 256 bit

/// Dati autenticati aggiuntivi di AES-GCM. Senza questi il tag non torna e la
/// decifratura fallisce senza spiegare perché: è il primo posto da guardare
/// se un vault valido "non si apre".
final Uint8List kAad = Uint8List.fromList(utf8.encode('vaultmind'));

/// La master password è sbagliata — oppure il ciphertext è stato manomesso.
/// Le due cose sono crittograficamente indistinguibili, quindi restano un
/// errore solo, come sul PC.
class WrongPassword implements Exception {
  final String message;
  const WrongPassword([this.message = 'Master password errata o vault corrotto.']);
  @override
  String toString() => message;
}

/// Il file non è un vault leggibile: JSON rotto, troncato, campi mancanti.
/// Distinto da [WrongPassword] perché chiede all'utente l'azione OPPOSTA —
/// con la password sbagliata si riprova, con un file danneggiato si ripristina
/// un backup, e riprovare la password all'infinito su un file rotto è il modo
/// peggiore di scoprirlo.
class VaultCorrupted implements Exception {
  final String message;
  const VaultCorrupted([this.message = 'Il file del vault non è leggibile.']);
  @override
  String toString() => message;
}

/// Un campo di una credenziale: etichetta + valore, nell'ordine scelto
/// dall'utente (l'ordine non è estetica: è come vede la voce).
class Campo {
  final String label;
  final String value;
  const Campo(this.label, this.value);

  factory Campo.fromJson(Map<String, dynamic> j) =>
      Campo((j['label'] ?? '') as String, (j['value'] ?? '') as String);
}

class Credenziale {
  final int id;
  final String title;
  final List<String> tags;

  /// Voce da cui si rimette le mani su tutto il resto (banca, email
  /// principale). Assente nei vault creati prima del 29/07/2026: assente
  /// significa `false`, mai errore.
  final bool critical;
  final List<Campo> fields;

  const Credenziale({
    required this.id,
    required this.title,
    required this.tags,
    required this.critical,
    required this.fields,
  });

  factory Credenziale.fromJson(Map<String, dynamic> j) => Credenziale(
        id: j['id'] as int,
        title: (j['title'] ?? '') as String,
        tags: ((j['tags'] ?? const []) as List).map((t) => '$t').toList(),
        critical: (j['critical'] ?? false) == true,
        fields: ((j['fields'] ?? const []) as List)
            .map((f) => Campo.fromJson(f as Map<String, dynamic>))
            .toList(),
      );
}

/// Il contenuto decifrato di un vault.
class Vault {
  final List<Credenziale> credenziali;
  const Vault(this.credenziali);
}

/// Apre un vault cifrato.
///
/// [contenuto] è il testo del file `.json` così com'è su disco.
/// Solleva [VaultCorrupted] se non è un vault leggibile, [WrongPassword] se
/// la chiave non torna.
Future<Vault> apriVault(String contenuto, String master) async {
  final Uint8List salt, nonce, ciphertext;
  try {
    final blob = jsonDecode(contenuto) as Map<String, dynamic>;
    final kdf = blob['kdf'] as Map<String, dynamic>;
    salt = base64.decode(kdf['salt'] as String);
    nonce = base64.decode(blob['nonce'] as String);
    ciphertext = base64.decode(blob['ciphertext'] as String);
  } catch (e) {
    // Cattura larga di proposito: un file danneggiato può avere qualsiasi
    // forma (chiavi mancanti, null, base64 invalido) e ognuna solleva
    // un'eccezione diversa. Per l'utente la conclusione è una sola.
    throw const VaultCorrupted();
  }

  final chiave = await derivaChiave(master, salt);

  // Il tag GCM (16 byte) sta IN CODA al ciphertext: è la convenzione di
  // Python `cryptography`, che produce i file. Qui va separato a mano.
  const lunghezzaTag = 16;
  if (ciphertext.length < lunghezzaTag) throw const VaultCorrupted();
  final corpo = ciphertext.sublist(0, ciphertext.length - lunghezzaTag);
  final tag = ciphertext.sublist(ciphertext.length - lunghezzaTag);

  final Uint8List chiaro;
  try {
    final byte = await AesGcm.with256bits().decrypt(
      SecretBox(corpo, nonce: nonce, mac: Mac(tag)),
      secretKey: SecretKey(chiave),
      aad: kAad,
    );
    chiaro = Uint8List.fromList(byte);
  } catch (e) {
    throw const WrongPassword();
  }

  try {
    final dati = jsonDecode(utf8.decode(chiaro)) as Map<String, dynamic>;
    final voci = (dati['credentials'] ?? const []) as List;
    return Vault(voci
        .map((c) => Credenziale.fromJson(c as Map<String, dynamic>))
        .toList());
  } catch (e) {
    // Il tag è tornato ma il contenuto non ha la forma attesa: è un vault
    // nostro scritto male, non il file di qualcun altro.
    throw const VaultCorrupted('Il contenuto del vault non è leggibile.');
  }
}

/// Argon2**id** — non Argon2i né Argon2d: una variante sbagliata dà una
/// chiave diversa, e la decifratura fallisce senza dire perché.
Future<Uint8List> derivaChiave(String master, Uint8List salt) async {
  final algoritmo = Argon2id(
    memory: kArgon2MemoryKiB,
    parallelism: kArgon2Parallelism,
    iterations: kArgon2TimeCost,
    hashLength: kKeyLength,
  );
  final chiave = await algoritmo.deriveKey(
    secretKey: SecretKey(utf8.encode(master)),
    nonce: salt, // in Argon2 il "nonce" di questa API è il salt
  );
  return Uint8List.fromList(await chiave.extractBytes());
}

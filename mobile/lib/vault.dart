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
import 'dart:math';
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

  Map<String, dynamic> toJson() => {'label': label, 'value': value};
}

/// Le chiavi di una voce che QUESTA versione conosce. Tutte le altre vengono
/// ricopiate tali e quali: da quando il telefono SCRIVE il vault, una versione
/// più vecchia che incontra un campo aggiunto dopo lo cancellerebbe in silenzio
/// al primo salvataggio. Stessa difesa di `_CRED_KEYS` in `crypto_store.py`.
const _chiaviNote = {
  'id', 'title', 'fields', 'tags', 'critical', 'category', 'uid', 'rev', 'mod'
};

/// Ora vera in millisecondi. Serve a MOSTRARE quando una voce è cambiata, non
/// a decidere chi vince: due telefoni con l'orologio sfasato deciderebbero
/// male. Per quello c'è `rev`, che è un contatore e non un orologio.
int oraOra() => DateTime.now().millisecondsSinceEpoch;

/// L'identificativo di una voce che esisteva PRIMA che gli uid esistessero.
///
/// Non può essere casuale: il PC e il telefono ne genererebbero due diversi
/// per la stessa identica voce, e al primo sync quella voce diventerebbe due
/// voci. Si ricava dal numero che la voce ha già, uguale su ogni copia dello
/// stesso vault. Stessa regola di `uid_derivato()` in `crypto_store.py`.
String uidDerivato(int id) => '#$id';

final _casuale = Random.secure();

/// uid per una voce NUOVA: casuale, perché due dispositivi scollegati che
/// aggiungono una voce prendono entrambi lo stesso `id` (max+1).
String uidNuovo() {
  const cifre = '0123456789abcdef';
  return List.generate(32, (_) => cifre[_casuale.nextInt(16)]).join();
}

/// Il salt di un vault NUOVO: 16 byte, come `os.urandom(16)` in
/// `crypto_store.create()`. Chi apre non ne controlla la lunghezza (usa quello
/// che trova nel file), ma i vault nati sul telefono devono essere
/// indistinguibili da quelli nati sul PC.
const int kLunghezzaSalt = 16;

/// Il minimo per una master password NUOVA, lo stesso di `/api/unlock` sul PC.
/// Contato in caratteri veri (`runes`), come `len()` in Python: con
/// `String.length` un'emoji varrebbe due.
const int kMasterMinima = 8;

/// Un vault nuovo e vuoto, con la sua chiave. **Non scrive niente**: salvarlo
/// è compito di chi chiama (`creaVault` in `archivio.dart`), e solo quando
/// tutto il resto è andato bene.
///
/// Esiste dal 16/09/2026: fino ad allora un vault nasceva solo sul PC, e chi
/// aveva soltanto il telefono restava fermo alla prima schermata.
Future<({Vault vault, Uint8List chiave})> nuovoVault(String master) async {
  if (master.runes.length < kMasterMinima) {
    throw ArgumentError('La master password deve avere almeno $kMasterMinima caratteri.');
  }
  final salt = Uint8List.fromList(
      List.generate(kLunghezzaSalt, (_) => _casuale.nextInt(256)));
  return (vault: Vault(const [], salt: salt), chiave: await derivaChiave(master, salt));
}

/// La lapide di una voce cancellata: senza, l'altro dispositivo — che la voce
/// ce l'ha ancora — la rimanderebbe indietro e la voce resusciterebbe.
class Lapide {
  final String uid;
  final int rev;
  final int mod;
  const Lapide(this.uid, {required this.rev, required this.mod});

  factory Lapide.fromJson(Map<String, dynamic> j) => Lapide(
        '${j['uid'] ?? ''}',
        rev: (j['rev'] as num?)?.toInt() ?? 1,
        mod: (j['mod'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {'uid': uid, 'rev': rev, 'mod': mod};
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

  /// Categoria scelta A MANO, una sola per voce. Vuota = nessuna. Non viene mai
  /// dedotta dai tag: quelli di un import sono spesso parole prese dal titolo.
  final String categoria;

  /// Identificativo stabile e unico, che sopravvive alla copia del vault da un
  /// dispositivo all'altro. Per le voci nate prima si ricava da [id].
  final String uid;

  /// Contatore logico: cresce di uno a ogni modifica di QUESTA voce. È lui a
  /// dire chi è più avanti, non l'orologio.
  final int rev;

  /// Ora dell'ultima modifica, in millisecondi. Da mostrare all'utente.
  final int mod;

  /// Chiavi lette dal file ma sconosciute a questa versione (vedi [_chiaviNote]).
  final Map<String, dynamic> extra;

  Credenziale({
    required this.id,
    required this.title,
    required this.tags,
    required this.critical,
    required this.fields,
    this.categoria = '',
    String uid = '',
    this.rev = 1,
    this.mod = 0,
    this.extra = const {},
  }) : uid = uid.isEmpty ? uidDerivato(id) : uid;

  factory Credenziale.fromJson(Map<String, dynamic> j) => Credenziale(
        id: j['id'] as int,
        title: (j['title'] ?? '') as String,
        tags: ((j['tags'] ?? const []) as List).map((t) => '$t').toList(),
        critical: (j['critical'] ?? false) == true,
        categoria: '${j['category'] ?? ''}'.trim(),
        uid: '${j['uid'] ?? ''}',
        rev: (j['rev'] as num?)?.toInt() ?? 1,
        mod: (j['mod'] as num?)?.toInt() ?? 0,
        fields: ((j['fields'] ?? const []) as List)
            .map((f) => Campo.fromJson(f as Map<String, dynamic>))
            .toList(),
        extra: {
          for (final e in j.entries)
            if (!_chiaviNote.contains(e.key)) e.key: e.value
        },
      );

  Map<String, dynamic> toJson() => {
        ...extra, // gli sconosciuti per primi: le chiavi note vincono comunque
        'id': id,
        'title': title,
        'tags': tags,
        'critical': critical,
        'fields': fields.map((f) => f.toJson()).toList(),
        // I campi opzionali si scrivono solo se dicono qualcosa: un vault mai
        // toccato dopo l'aggiornamento resta identico a com'era, e il vettore
        // di prova continua a valere. Come fa il PC.
        if (categoria.isNotEmpty) 'category': categoria,
        if (uid != uidDerivato(id)) 'uid': uid,
        if (rev != 1) 'rev': rev,
        if (mod != 0) 'mod': mod,
      };

  /// Una copia modificata. **Fa avanzare il contatore**: qualunque cambiamento
  /// del contenuto deve risultare al sync, altrimenti un riordino di 800 voci
  /// passerebbe per "niente è cambiato".
  Credenziale modificata({
    String? title,
    List<String>? tags,
    bool? critical,
    List<Campo>? fields,
    String? categoria,
  }) =>
      Credenziale(
        id: id,
        title: title ?? this.title,
        tags: tags ?? this.tags,
        critical: critical ?? this.critical,
        fields: fields ?? this.fields,
        categoria: (categoria ?? this.categoria).trim(),
        uid: uid,
        rev: rev + 1,
        mod: oraOra(),
        extra: extra,
      );

  Credenziale conCategoria(String nuova) => modificata(categoria: nuova);

  /// Copia con un altro `id` e **senza** far avanzare il contatore: serve alla
  /// fusione, quando due voci diverse si ritrovano lo stesso numero. Cambiare
  /// il numero non è modificare la voce.
  Credenziale conId(int nuovo) => Credenziale(
        id: nuovo,
        title: title,
        tags: tags,
        critical: critical,
        fields: fields,
        categoria: categoria,
        uid: uid,
        rev: rev,
        mod: mod,
        extra: extra,
      );
}

/// Il contenuto decifrato di un vault.
///
/// Immutabile: modificarlo significa costruirne uno nuovo con [con]. Così
/// l'interfaccia si ridipinge sola quando il valore cambia, e non esiste il
/// caso "ho cambiato la lista ma nessuno se n'è accorto".
class Vault {
  final List<Credenziale> credenziali;

  /// Le categorie esistenti, nell'ordine scelto dall'utente. Stanno qui e non
  /// si deducono dalle voci: una categoria appena creata è vuota, e dedurla la
  /// farebbe sparire fra il momento in cui la crei e quello in cui la riempi.
  final List<String> categorie;

  /// Cosa è stato cancellato e quando. Vedi [Lapide].
  final List<Lapide> lapidi;

  /// Il salt del file da cui è stato aperto: serve a riscriverlo con la stessa
  /// chiave, senza rifare Argon2 (che sul telefono costa quasi un secondo).
  final Uint8List salt;

  /// Chiavi del contenuto in chiaro sconosciute a questa versione.
  final Map<String, dynamic> extraRadice;

  const Vault(
    this.credenziali, {
    this.categorie = const [],
    this.lapidi = const [],
    required this.salt,
    this.extraRadice = const {},
  });

  Vault con({
    List<Credenziale>? credenziali,
    List<String>? categorie,
    List<Lapide>? lapidi,
  }) =>
      Vault(
        credenziali ?? this.credenziali,
        categorie: categorie ?? this.categorie,
        lapidi: lapidi ?? this.lapidi,
        salt: salt,
        extraRadice: extraRadice,
      );

  /// Il vault senza la voce indicata, con la sua lapide al posto giusto.
  ///
  /// `rev` della lapide è quello della voce **più uno**: la cancellazione è
  /// essa stessa una modifica, e deve battere la copia ancora viva sull'altro
  /// dispositivo, altrimenti il sync la rimanderebbe indietro.
  Vault senzaVoce(int id) {
    final voce = credenziali.where((c) => c.id == id).firstOrNull;
    if (voce == null) return this;
    return con(
      credenziali: credenziali.where((c) => c.id != id).toList(),
      lapidi: [
        ...lapidi.where((l) => l.uid != voce.uid),
        Lapide(voce.uid, rev: voce.rev + 1, mod: oraOra()),
      ],
    );
  }
}

/// I tre pezzi del file, già decodificati.
class _Pezzi {
  final Uint8List salt, nonce, ciphertext;
  const _Pezzi(this.salt, this.nonce, this.ciphertext);
}

_Pezzi _leggiPezzi(String contenuto) {
  try {
    final blob = jsonDecode(contenuto) as Map<String, dynamic>;
    final kdf = blob['kdf'] as Map<String, dynamic>;
    return _Pezzi(
      base64.decode(kdf['salt'] as String),
      base64.decode(blob['nonce'] as String),
      base64.decode(blob['ciphertext'] as String),
    );
  } catch (e) {
    // Cattura larga di proposito: un file danneggiato può avere qualsiasi
    // forma (chiavi mancanti, null, base64 invalido) e ognuna solleva
    // un'eccezione diversa. Per l'utente la conclusione è una sola.
    throw const VaultCorrupted();
  }
}

/// Deriva la chiave dalla master password, usando il salt del file.
/// Separata perché serve anche allo sblocco con impronta: quella conserva la
/// **chiave**, mai la password.
Future<Uint8List> chiaveDelVault(String contenuto, String master) async =>
    derivaChiave(master, _leggiPezzi(contenuto).salt);

/// Apre un vault cifrato.
///
/// [contenuto] è il testo del file `.json` così com'è su disco.
/// Solleva [VaultCorrupted] se non è un vault leggibile, [WrongPassword] se
/// la chiave non torna.
Future<Vault> apriVault(String contenuto, String master) async =>
    apriVaultConChiave(contenuto, await chiaveDelVault(contenuto, master));

/// Apre un vault con la chiave già derivata: è la strada dello sblocco con
/// impronta, che salta Argon2 perché la chiave l'ha già.
Future<Vault> apriVaultConChiave(String contenuto, Uint8List chiave) async {
  final p = _leggiPezzi(contenuto);

  // Il tag GCM (16 byte) sta IN CODA al ciphertext: è la convenzione di
  // Python `cryptography`, che produce i file. Qui va separato a mano.
  const lunghezzaTag = 16;
  if (p.ciphertext.length < lunghezzaTag) throw const VaultCorrupted();
  final corpo = p.ciphertext.sublist(0, p.ciphertext.length - lunghezzaTag);
  final tag = p.ciphertext.sublist(p.ciphertext.length - lunghezzaTag);

  final Uint8List chiaro;
  try {
    final byte = await AesGcm.with256bits().decrypt(
      SecretBox(corpo, nonce: p.nonce, mac: Mac(tag)),
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
    return Vault(
      voci.map((c) => Credenziale.fromJson(c as Map<String, dynamic>)).toList(),
      categorie: ripulisciCategorie((dati['categories'] ?? const []) as List),
      lapidi: ((dati['deleted'] ?? const []) as List)
          .whereType<Map<String, dynamic>>()
          .map(Lapide.fromJson)
          .where((l) => l.uid.isNotEmpty)
          .toList(),
      salt: p.salt,
      extraRadice: {
        for (final e in dati.entries)
          if (e.key != 'credentials' &&
              e.key != 'categories' &&
              e.key != 'deleted')
            e.key: e.value
      },
    );
  } catch (e) {
    // Il tag è tornato ma il contenuto non ha la forma attesa: è un vault
    // nostro scritto male, non il file di qualcun altro.
    throw const VaultCorrupted('Il contenuto del vault non è leggibile.');
  }
}

/// Nome di categoria ripulito: spazi normalizzati, maiuscole come sono state
/// scritte. Il confronto è senza maiuscole, la resa a schermo no: chi scrive
/// «Banche» vuole rileggere «Banche». Stessa regola di `crypto_store.py`.
String normalizzaCategoria(String nome) => nome.trim().split(RegExp(r'\s+')).join(' ');

/// Via i vuoti e i doppioni; l'ordine è quello scelto dall'utente e resta.
List<String> ripulisciCategorie(List<dynamic> grezze) {
  final out = <String>[];
  final viste = <String>{};
  for (final c in grezze) {
    final nome = normalizzaCategoria('$c');
    if (nome.isNotEmpty && viste.add(nome.toLowerCase())) out.add(nome);
  }
  return out;
}

/// Cifra un vault e restituisce il testo del file, nella forma ESATTA prodotta
/// dal PC — è il contratto fra le piattaforme (`tests/vettore/LEGGIMI.md`).
///
/// [chiave] è quella già in memoria dalla sessione: non si ripassa dalla master
/// password, e Argon2 (quasi un secondo sul telefono) non viene rifatto.
///
/// Il **nonce è nuovo a ogni scrittura**, e non è un dettaglio: riusarne uno
/// con la stessa chiave in AES-GCM non indebolisce la cifratura, la annulla —
/// due vault cifrati con la stessa coppia si smontano a vicenda con uno XOR.
/// Il salt invece resta quello del file, perché la chiave deriva da lui.
Future<String> cifraVault(Vault vault, Uint8List chiave) async {
  final contenuto = <String, dynamic>{
    ...vault.extraRadice, // prima gli sconosciuti, poi i nostri
    'credentials': vault.credenziali.map((c) => c.toJson()).toList(),
    if (vault.categorie.isNotEmpty) 'categories': vault.categorie,
    if (vault.lapidi.isNotEmpty)
      'deleted': vault.lapidi.map((l) => l.toJson()).toList(),
  };

  final algoritmo = AesGcm.with256bits();
  final nonce = algoritmo.newNonce();
  final scatola = await algoritmo.encrypt(
    utf8.encode(jsonEncode(contenuto)),
    secretKey: SecretKey(chiave),
    nonce: nonce,
    aad: kAad,
  );

  // Il tag GCM va IN CODA al ciphertext: qui `cryptography` lo tiene separato,
  // Python lo concatena. Chi legge si aspetta la forma di Python.
  final ciphertext = Uint8List.fromList([...scatola.cipherText, ...scatola.mac.bytes]);

  return jsonEncode({
    'version': 1,
    'kdf': {
      'alg': 'argon2id',
      'salt': base64.encode(vault.salt),
      'time_cost': kArgon2TimeCost,
      'memory_cost': kArgon2MemoryKiB,
      'parallelism': kArgon2Parallelism,
    },
    'cipher': 'aes-256-gcm',
    'nonce': base64.encode(nonce),
    'ciphertext': base64.encode(ciphertext),
  });
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

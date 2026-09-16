/// Cio' che del sync sulla rete serve sapere **anche dove la rete non c'e'**.
///
/// Stava tutto in `sync_rete.dart` fino al 16/09/2026, quando l'app ha
/// cominciato a girare anche nel browser (la versione per iPhone). Un browser
/// non apre socket verso la rete di casa, e `dart:io` in una build web non
/// compila nemmeno: il trasporto vero resta in `sync_rete_io.dart`, quello
/// vuoto sta in `sync_rete_web.dart`, e qui restano i tipi che le schermate e
/// il gestore usano in entrambi i casi. Una copia sola, non due che divergono.
library;

/// Porta dell'ascoltatore. Vicina a quella dell'app sul PC (8731) per
/// ricordarsi che sono due cose diverse: quella è loopback, questa parla con
/// la rete locale.
const int portaSync = 8732;

/// Porta della scoperta. Solo UDP, solo domande e risposte corte.
const int portaScoperta = 8733;

/// Versione del protocollo sul filo. Due versioni diverse si rifiutano subito,
/// invece di capirsi a metà.
const int versione = 1;

/// Oltre questo, un messaggio non è un messaggio: è qualcuno che prova a farci
/// allocare memoria finché non moriamo.
const int maxMessaggio = 64 * 1024 * 1024;
const Duration attesaMax = Duration(seconds: 20);

/// Il collegamento non deve proseguire, e il motivo si può dire all'utente.
class RifiutoSync implements Exception {
  final String messaggio;
  const RifiutoSync(this.messaggio);
  @override
  String toString() => messaggio;
}

/// Tutto quello che il trasporto deve chiedere all'app, senza conoscerla.
/// Nei test si passa un contesto finto e si fanno parlare due estremi sullo
/// stesso dispositivo, senza vault e senza interfaccia.
class ContestoSync {
  final String idDispositivo;
  final String nome;
  final List<int> chiaveVault;

  /// {id: nome} — solo nomi, nessun segreto: le chiavi si ricavano.
  ///
  /// Deve essere la mappa **viva**, non una copia: l'elenco cambia mentre
  /// l'ascoltatore è già aperto — è esattamente quello che succede al primo
  /// abbinamento — e con una fotografia il dispositivo appena abbinato
  /// continuerebbe a risultare sconosciuto, respinto per sempre a finestra di
  /// abbinamento chiusa.
  final Map<String, String> fidati;

  /// Il vault cifrato da mandare all'altro, **chiesto al momento**.
  ///
  /// Asincrona perché cifrare lo è, e tenerne una copia pronta era il bug del
  /// 05/08/2026: la copia veniva preparata solo quando il telefono CHIAMAVA,
  /// quindi quando era lui a rispondere mandava una stringa vuota e il PC
  /// diceva «il vault ricevuto non è leggibile». Invisibile finché il PC non
  /// ha imparato a chiamare per primo.
  final Future<String> Function() leggiVaultCifrato;

  /// Riceve il vault dell'altro e lo fonde. Torna un riepilogo per l'utente.
  final Future<Map<String, dynamic>> Function(String blob, String idPeer) riceviVault;

  /// Il salt del vault, per chi deve ancora derivare la chiave.
  final List<int> saltVault;

  /// Codice di abbinamento in corso, se l'utente l'ha chiesto.
  final String? Function() codiceAttivo;

  /// Chiamata quando un abbinamento va a buon fine.
  final void Function(String idPeer, String nome) abbina;

  ContestoSync({
    required this.idDispositivo,
    required this.nome,
    required this.chiaveVault,
    required this.leggiVaultCifrato,
    required this.riceviVault,
    this.fidati = const {},
    this.saltVault = const [],
    String? Function()? codiceAttivo,
    void Function(String, String)? abbina,
  })  : codiceAttivo = codiceAttivo ?? (() => null),
        abbina = abbina ?? ((_, _) {});

  bool siFidaDi(String idPeer) => fidati.containsKey(idPeer);
}

/// Un dispositivo trovato sulla rete.
class Trovato {
  final String id, nome, indirizzo;
  final int porta;
  final bool abbinabile, firmata;
  final String salt;

  /// Il nome con cui lo conosciamo NOI, se è già abbinato: vince su quello che
  /// annuncia lui, che potrebbe essere stato cambiato dall'altra parte.
  String? nomeLocale;

  /// Come chiamarlo a schermo.
  String get etichetta => nomeLocale ?? nome;

  /// L'abbiamo già abbinato?
  bool get conosciuto => nomeLocale != null;

  Trovato({
    required this.id,
    required this.nome,
    required this.indirizzo,
    required this.porta,
    this.abbinabile = false,
    this.firmata = false,
    this.salt = '',
  });
}

/// Cio' che del sync sulla rete serve sapere **anche dove la rete non c'e'**.
///
/// Il trasporto vero sta in `sync_rete_io.dart`, quello vuoto del browser in
/// `sync_rete_web.dart`; qui restano i tipi che il gestore usa in entrambi i
/// casi. Una copia sola, non due che divergono.
library;

/// La porta su cui il telefono aspetta il PC. Vicina a quella dell'app sul
/// PC (8731) per ricordarsi che sono due cose diverse: quella e' loopback,
/// questa parla con la rete di casa. La stessa di `sync_net.PORTA_SYNC`.
const int portaSync = 8732;

/// Oltre questo, un messaggio non e' un messaggio: e' qualcuno che prova a
/// farci allocare memoria finche' non moriamo.
const int maxMessaggio = 64 * 1024 * 1024;

/// Finche' chi chiama non ha dimostrato di avere la chiave, una riga non puo'
/// essere piu' lunga di cosi'. La prima riga del PC e' un saluto di poche
/// centinaia di byte; prima del 10/11/2026 chiunque in rete poteva farne
/// tenere in memoria 64 MB per collegamento, senza chiave (pentest, M2).
const int maxPrimaRiga = 64 * 1024;

/// Quanti collegamenti insieme. In casa chiama un PC, al piu' due: gli altri
/// vengono chiusi subito, senza leggere niente.
const int maxCollegamenti = 8;

/// A collegamento aperto: un vault grande su una WiFi lenta ci mette un po'.
const Duration attesaMax = Duration(seconds: 20);

/// Il collegamento non deve proseguire, e il motivo si puo' dire all'utente.
class RifiutoSync implements Exception {
  final String messaggio;
  const RifiutoSync(this.messaggio);
  @override
  String toString() => messaggio;
}

/// Un collegamento col PC: righe di JSON, in chiaro. Cifrare e decifrare il
/// contenuto e' compito di chi lo usa (`sync_gestore.dart`), che sa con quale
/// chiave.
abstract class Canale {
  /// La riga successiva. Solleva [RifiutoSync] se il collegamento si chiude,
  /// se non arriva niente entro [attesa] o se la riga non e' un oggetto JSON.
  Future<Map<String, dynamic>> leggi({Duration attesa = attesaMax});

  void scrivi(Map<String, dynamic> dato);

  /// Chi sta dall'altra parte ha dimostrato di avere la chiave: da qui le
  /// righe possono essere grandi quanto un vault ([maxMessaggio]).
  void fidati();

  Future<void> chiudi();
}

/// Cosa fare di ogni collegamento in arrivo.
typedef Servizio = Future<void> Function(Canale canale);

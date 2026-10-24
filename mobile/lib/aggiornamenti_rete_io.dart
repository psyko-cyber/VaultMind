/// La rete degli aggiornamenti sul telefono: una GET e un file nella cache.
///
/// Qui dentro **non si solleva per un guasto di rete**: `prendiTesto` risponde
/// `null` e basta. È la regola che tiene in piedi la promessa «l'app si apre
/// comunque»: niente connessione, DNS che risponde spazzatura, Wi-Fi di un bar
/// che intercetta tutto — per chi chiama sono tutti lo stesso caso, «non lo
/// so», e nessuno di questi deve diventare un messaggio a schermo.
///
/// Il download invece solleva: lì l'utente ha chiesto una cosa precisa e ha
/// diritto di sapere che non è riuscita.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
// BytesBuilder sta qui, non in dart:io: arrivarci di rimbalzo e' deprecato.
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'versione.dart';

/// Corta di proposito: un controllo che non risponde non è niente da
/// aspettare. Il download ha il suo tempo, più lungo.
const attesaControllo = Duration(seconds: 8);
const attesaDownload = Duration(seconds: 30);

HttpClient _cliente(Duration attesa) => HttpClient()
  ..connectionTimeout = attesa
  ..userAgent = 'VaultMind/$versioneApp';

/// Il corpo della risposta, o `null` per qualunque motivo.
///
/// [massimo] è un tetto alla lettura: una risposta enorme non deve poter
/// riempire la memoria del telefono per un controllo di versione.
Future<String?> prendiTesto(
  String url, {
  Duration attesa = attesaControllo,
  int massimo = 256 * 1024,
}) async {
  final c = _cliente(attesa);
  try {
    final richiesta = await c.getUrl(Uri.parse(url)).timeout(attesa);
    richiesta.headers.set('Accept', 'application/vnd.github+json');
    final r = await richiesta.close().timeout(attesa);
    if (r.statusCode != 200) return null;
    final pezzi = BytesBuilder(copy: false);
    await for (final p in r.timeout(attesa)) {
      pezzi.add(p);
      if (pezzi.length > massimo) break;
    }
    return utf8.decode(pezzi.takeBytes(), allowMalformed: true);
  } catch (_) {
    return null;
  } finally {
    c.close(force: true);
  }
}

/// La cartella dei download: la **cache privata dell'app**, non la cartella
/// Download del telefono. Un APK che resta fra i file dell'utente è un APK che
/// qualcuno installerà il mese prossimo credendolo l'ultimo.
Future<Directory> _cartella() async => Directory(
    '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}vaultmind-aggiornamento');

Future<void> pulisciCache() async {
  try {
    final d = await _cartella();
    if (await d.exists()) await d.delete(recursive: true);
  } catch (_) {}
}

/// Scarica [url] nella cache e restituisce percorso e SHA-256 del file.
///
/// `null` se [annullato] ha detto di smettere: annullare non è un errore e non
/// deve diventare un messaggio. Solleva, invece, se il download non riesce.
///
/// Lo SHA-256 si calcola rileggendo il file dal disco e non tenendolo in
/// memoria: un APK sono decine di MB, e su un telefono con poca memoria
/// libera quella copia è esattamente il momento in cui l'app viene uccisa.
Future<({String percorso, String sha})?> scaricaInCache(
  String url,
  String nome, {
  void Function(double)? suProgresso,
  bool Function()? annullato,
}) async {
  await pulisciCache();
  final d = await _cartella();
  await d.create(recursive: true);
  final f = File('${d.path}${Platform.pathSeparator}$nome');
  final c = _cliente(attesaDownload);
  try {
    final r = await (await c.getUrl(Uri.parse(url)).timeout(attesaDownload))
        .close()
        .timeout(attesaDownload);
    if (r.statusCode != 200) throw HttpException('HTTP ${r.statusCode}', uri: Uri.parse(url));
    final totale = r.contentLength;
    var fatto = 0;
    var fermato = false;
    final scrittura = f.openWrite();
    try {
      await for (final p in r.timeout(attesaDownload)) {
        if (annullato?.call() ?? false) {
          fermato = true;
          break;
        }
        scrittura.add(p);
        fatto += p.length;
        if (totale > 0) suProgresso?.call(fatto / totale);
      }
    } finally {
      await scrittura.close();
    }
    if (fermato) {
      await pulisciCache();
      return null;
    }
    if (totale > 0 && fatto != totale) {
      throw const HttpException('Download interrotto a metà.');
    }
    final sha = (await sha256.bind(f.openRead()).first).toString();
    return (percorso: f.path, sha: sha);
  } catch (_) {
    await pulisciCache();
    rethrow;
  } finally {
    c.close(force: true);
  }
}

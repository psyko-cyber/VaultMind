/// Accorgersi che c'è una versione nuova, senza far dipendere l'app da
/// Internet.
///
/// È lo stesso meccanismo del PC (`VaultMind_Windows/app/aggiornamenti.py`),
/// con le stesse regole, e il confronto fra versioni è provato sugli **stessi
/// casi** in Python e in Dart (`tests/vettore/versioni.json`): due numeri di
/// versione confrontati in due modi diversi sono un'app che si aggiorna su un
/// dispositivo e non sull'altro.
///
/// ## Perché un'app «100% locale» chiama GitHub
///
/// Il contrario di «locale» è «il provider ha i tuoi dati», non «il programma
/// non sa di essere vecchio». Un gestore di password fermo alla versione di un
/// anno prima è un problema di sicurezza, e l'unico modo di accorgersene era
/// che qualcuno andasse a guardare la pagina delle release: cioè nessuno.
///
/// Da qui esce **una GET anonima** a una pagina pubblica, non più di una ogni
/// 12 ore. GitHub vede un indirizzo IP e lo `User-Agent` con la versione, come
/// qualunque visita a un sito: niente identificativi, niente conteggi, e
/// niente che riguardi il vault — questo file non ha accesso alla sessione.
/// Resta una connessione in uscita che prima non c'era, quindi l'interruttore
/// in Impostazioni la spegne, e spenta non parte nessuna richiesta.
///
/// ## Non blocca niente
///
/// Il controllo parte **dopo** che la casa è a schermo e nessuno ne aspetta la
/// risposta: senza rete scade dopo 8 secondi e di questa riga non resta
/// traccia. Chi apre VaultMind in aereo non deve accorgersi che esiste.
///
/// ## L'installazione
///
/// L'APK è lo stesso che si scarica a mano, **con la stessa firma**
/// (`CN=Luca Giordano`): Android lo installa sopra quello attuale e i dati
/// restano. Se la firma non corrispondesse, Android rifiuterebbe — ed è questa
/// la vera difesa, non il nostro controllo. Lo SHA-256 della release si
/// verifica comunque prima di passare il file all'installer: un APK scaricato
/// a metà non deve arrivare fino a quella schermata.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'aggiornamenti_rete.dart';
import 'impostazioni.dart';
import 'ponte_file.dart';
import 'versione.dart';

/// Dove si guarda. Perché la richiesta funzioni senza token, le release devono
/// stare su un repo **pubblico** (vedi TODO.md).
const repoGitHub = 'psyko-cyber/VaultMind';
const paginaRelease = 'https://github.com/$repoGitHub/releases/latest';
const _apiUltima = 'https://api.github.com/repos/$repoGitHub/releases/latest';

/// I nomi degli allegati che `installer/rilascio.ps1` carica sulla release.
/// Si cerca per nome e non «il primo .apk»: su quella release c'è anche il
/// setup di Windows.
const nomeApk = 'VaultMind.apk';
const nomeSomme = 'SHA256SUMS.txt';

/// Ogni quanto si torna a chiedere, e quanto vale «più tardi».
const intervalloOre = 12;
const rinvioOre = 20;

class Novita {
  final String versione;
  final String pagina;
  final String note;
  final String? download;
  final String? somme;

  const Novita({
    required this.versione,
    required this.pagina,
    this.note = '',
    this.download,
    this.somme,
  });

  /// Si può installare da dentro l'app solo se la release allega **sia** l'APK
  /// **sia** lo SHA256SUMS.txt: senza il secondo non c'è niente da verificare,
  /// e un APK non verificato non lo si passa all'installer. In quel caso resta
  /// il pulsante che apre la pagina.
  bool get scaricabile => download != null && somme != null;

  Map<String, dynamic> toJson() => {
        'versione': versione,
        'pagina': pagina,
        if (note.isNotEmpty) 'note': note,
        if (download != null) 'download': download,
        if (somme != null) 'somme': somme,
      };

  static Novita? daJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final v = '${j['versione'] ?? ''}';
    if (v.isEmpty) return null;
    return Novita(
      versione: v,
      pagina: '${j['pagina'] ?? paginaRelease}',
      note: '${j['note'] ?? ''}',
      download: j['download'] as String?,
      somme: j['somme'] as String?,
    );
  }
}

/// `a` è una versione più recente di `b`?
///
/// Confronto numerico pezzo per pezzo, non alfabetico: `"6.10" > "6.9"` deve
/// essere vero, e come stringhe non lo sarebbe.
///
/// Si buttano via il `v` del tag e **tutto quello che segue un `+` o un `-`**:
/// il numero di build serve ad Android (`versionCode`), non a dire chi è più
/// recente, e senza questa riga `6.9.0+69` risulterebbe più nuovo di `6.9` —
/// cioè il telefono si offrirebbe di aggiornarsi alla versione che ha già.
/// I pezzi mancanti valgono 0: `6.9` e `6.9.0` sono la stessa versione.
bool piuRecente(String a, String b) {
  List<int> pezzi(String v) => v
      .replaceFirst(RegExp(r'^[vV]'), '')
      .trim()
      .split(RegExp(r'[+\-]'))
      .first
      .split('.')
      .where((p) => p.isNotEmpty)
      .map((p) => int.tryParse(p) ?? 0)
      .toList();

  final x = pezzi(a), y = pezzi(b);
  final quanti = [x.length, y.length, 3].reduce((m, n) => m > n ? m : n);
  for (var i = 0; i < quanti; i++) {
    final xi = i < x.length ? x[i] : 0;
    final yi = i < y.length ? y[i] : 0;
    if (xi != yi) return xi > yi;
  }
  return false;
}

/// La risposta di GitHub ridotta a quello che serve, o `null` se quella
/// risposta non parla di una release.
///
/// Il portale Wi-Fi di un hotel che risponde 200 con la sua pagina di login è
/// il caso normale, non un errore: **della forma di una risposta altrui non si
/// dà mai niente per buono** (regola del progetto, pagata con tre
/// `AttributeError` sul PC).
Novita? leggiRelease(String corpo) {
  Object? j;
  try {
    j = jsonDecode(corpo);
  } catch (_) {
    return null;
  }
  if (j is! Map) return null;
  final tag = '${j['tag_name'] ?? ''}'.trim().replaceFirst(RegExp(r'^[vV]'), '');
  if (!RegExp(r'^\d+(\.\d+)*$').hasMatch(tag)) return null;
  String? apk, somme;
  final allegati = j['assets'];
  if (allegati is List) {
    for (final a in allegati) {
      if (a is! Map) continue;
      final nome = '${a['name'] ?? ''}';
      final url = a['browser_download_url'];
      if (url is! String) continue;
      if (nome == nomeApk) apk = url;
      if (nome == nomeSomme) somme = url;
    }
  }
  return Novita(
    versione: tag,
    pagina: '${j['html_url'] ?? paginaRelease}',
    note: '${j['body'] ?? ''}'.trim(),
    download: apk,
    somme: somme,
  );
}

/// Lo SHA-256 di [nome] dentro un SHA256SUMS.txt (`hash *nome`).
String? shaAtteso(String somme, String nome) {
  for (final riga in const LineSplitter().convert(somme)) {
    final m = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(riga.trim());
    if (m != null && m.group(2)!.trim() == nome) {
      return m.group(1)!.toLowerCase();
    }
  }
  return null;
}

/// Le note della release in testo semplice: un `AlertDialog` non è un lettore
/// di Markdown, e `## **` a schermo sembrano un difetto dell'app.
String notePulite(String md, {int righe = 12}) {
  final pulite = md
      .replaceAll('**', '')
      .split('\n')
      .map((l) => l.replaceFirst(RegExp(r'^#+\s*'), '').trimRight())
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  final r = pulite.split('\n');
  return r.length > righe ? [...r.take(righe), '…'].join('\n') : pulite;
}

/// La novità trovata e non rimandata. La guarda Impostazioni, così la riga
/// «c'è la 7.0» non dipende da chi ha aperto quale schermata.
final avvisoAggiornamento = ValueNotifier<Novita?>(null);

int _adesso() => DateTime.now().millisecondsSinceEpoch;

/// «Più tardi» su una versione precisa: non si ripropone per [rinvioOre].
bool rinviata(Novita n) {
  final i = impostazioni.value;
  return i.aggRinviata == n.versione &&
      _adesso() - i.aggRinviataQuando < rinvioOre * 3600 * 1000;
}

Future<void> rinvia(Novita n) => salvaImpostazioni(impostazioni.value
    .copia(aggRinviata: n.versione, aggRinviataQuando: _adesso()));

/// Com'è andato un controllo.
///
/// [risposto] falso vuol dire «non lo so»: nessuna rete, oppure il portale
/// Wi-Fi di turno che ha risposto qualcosa che non è una release. Serve a una
/// cosa sola, e importante: chi ha **premuto un pulsante** merita una risposta
/// onesta, e «hai già l'ultima versione» detto senza connessione è una bugia.
/// Il controllo automatico non guarda questo campo: lì il silenzio è giusto.
class EsitoControllo {
  final Novita? novita;
  final bool risposto;
  const EsitoControllo(this.novita, {this.risposto = true});
}

/// Chiede a GitHub, non più di una volta ogni [intervalloOre].
///
/// Non solleva mai. Quando la rete non risponde si tiene l'ultima risposta
/// buona: se ieri c'era la 7.0, c'è ancora anche in metropolitana.
Future<EsitoControllo> controlla({bool forza = false}) async {
  // Nel browser l'app si aggiorna da sola: vedi `aggiornamenti_rete_web.dart`.
  if (kIsWeb) return const EsitoControllo(null);
  if (!impostazioni.value.aggAttivi) {
    avvisoAggiornamento.value = null;
    return const EsitoControllo(null);
  }
  var trovata = Novita.daJson(impostazioni.value.aggTrovata);
  var risposto = true;
  final adesso = _adesso();
  if (forza || adesso - impostazioni.value.aggControllo >= intervalloOre * 3600 * 1000) {
    final corpo = await prendiTesto(_apiUltima);
    final letta = corpo == null ? null : leggiRelease(corpo);
    risposto = letta != null;
    if (letta != null) {
      trovata = piuRecente(letta.versione, versioneApp) ? letta : null;
    }
    // L'ora si segna comunque: senza rete non si riprova fra due secondi.
    await salvaImpostazioni(impostazioni.value.copia(
      aggControllo: adesso,
      aggTrovata: trovata?.toJson() ?? const <String, dynamic>{},
    ));
  }
  // Dopo un aggiornamento riuscito la nota resta nelle preferenze: è questo
  // confronto, non la cancellazione, a farla smettere di comparire.
  if (trovata != null && !piuRecente(trovata.versione, versioneApp)) {
    trovata = null;
  }
  avvisoAggiornamento.value = trovata;
  return EsitoControllo(trovata, risposto: risposto);
}

/// Scarica l'APK e ne verifica lo SHA-256. Restituisce il percorso del file,
/// oppure `null` se [annullato] ha detto di smettere.
///
/// Solleva [FormatException] se il file scaricato non corrisponde: a quel
/// punto il file è già stato cancellato. Meglio nessun APK che un APK di cui
/// non sappiamo niente.
Future<String?> scarica(
  Novita n, {
  void Function(double)? suProgresso,
  bool Function()? annullato,
}) async {
  if (!n.scaricabile) {
    throw const FormatException(
        'Questa release non allega l\'APK con il suo SHA-256.');
  }
  final somme = await prendiTesto(n.somme!, massimo: 64 * 1024);
  final atteso = somme == null ? null : shaAtteso(somme, nomeApk);
  if (atteso == null) {
    throw const FormatException(
        'Non ho potuto leggere lo SHA-256 della release: scaricalo dalla pagina.');
  }
  final esito = await scaricaInCache(n.download!, nomeApk,
      suProgresso: suProgresso, annullato: annullato);
  if (esito == null) return null;
  if (esito.sha != atteso) {
    await pulisciCache();
    throw const FormatException(
        'Il file scaricato non corrisponde allo SHA-256 della release.');
  }
  return esito.percorso;
}

/// Passa l'APK all'installer di Android. Da qui in avanti decide l'utente:
/// la schermata di sistema chiede conferma, e la può rifiutare.
Future<void> installa(String percorso) => installaApk(percorso);

/// Il generatore di password, portato dal PC.
///
/// Gli alfabeti sono **gli stessi** di `genPassword()` in `index.html`, e per
/// la stessa ragione: niente `l`/`o`, `I`/`O`, `0`/`1`. Una password si legge
/// ad alta voce, si ricopia da uno schermo all'altro, si detta al telefono —
/// e in quei momenti `l` e `1` sono lo stesso carattere. Il prezzo è qualche
/// bit di entropia, che a 20 caratteri non manca a nessuno.
///
/// Due differenze dal PC, tutte e due volute:
///
///  - **Niente modulo su un numero casuale.** Il PC fa `arr[i] % pool.length`,
///    che su un alfabeto la cui dimensione non divide 2³² rende i primi
///    caratteri leggermente più probabili. È una distorsione minuscola, ma
///    `Random.secure().nextInt()` la evita gratis e non c'è motivo di
///    riprodurla.
///  - **Almeno un carattere per ogni classe scelta.** Il PC pesca a caso e
///    basta: su 20 caratteri con tutte e quattro le classi accese, una
///    password su dieci esce **senza nessuna cifra**, il sito la rifiuta e chi
///    la usa non capisce perché — rigenera finché "funziona". Qui si mette un
///    carattere di ogni classe e poi si mescola.
library;

import 'dart:math';

/// Niente `l` né `o`: si confondono con `1` e `0`.
const alfabetoMinuscole = 'abcdefghijkmnpqrstuvwxyz';

/// Niente `I` né `O`, per la stessa ragione.
const alfabetoMaiuscole = 'ABCDEFGHJKLMNPQRSTUVWXYZ';

/// Niente `0` né `1`, che è l'altra metà della stessa confusione.
const alfabetoCifre = '23456789';

/// Solo simboli che le tastiere italiane hanno davvero, e che i moduli di
/// registrazione accettano quasi sempre.
const alfabetoSimboli = r'!@#$%^&*()-_=+[]{}?';

/// Sotto questa lunghezza non si scende, nemmeno chiedendolo: una password
/// generata dalla macchina non ha nessun motivo di essere corta.
const lunghezzaMinima = 8;
const lunghezzaMassima = 40;

/// Genera una password.
///
/// [caso] esiste **solo per i test**, che devono poter verificare le regole
/// (le classi presenti, la lunghezza) su una sequenza ripetibile. In app resta
/// `null` e si usa `Random.secure()`, cioè il generatore del sistema
/// operativo: `Random()` normale è un algoritmo prevedibile, e per una
/// password è la differenza fra un segreto e un numero scritto in chiaro.
///
/// Restituisce stringa vuota se non è stata scelta **nessuna** classe: non è
/// un errore da sollevare, è un pannello con tutti gli interruttori spenti, e
/// chi chiama mostra semplicemente niente.
String generaPassword({
  int lunghezza = 20,
  bool maiuscole = true,
  bool minuscole = true,
  bool cifre = true,
  bool simboli = true,
  Random? caso,
}) {
  final r = caso ?? Random.secure();
  final classi = <String>[
    if (minuscole) alfabetoMinuscole,
    if (maiuscole) alfabetoMaiuscole,
    if (cifre) alfabetoCifre,
    if (simboli) alfabetoSimboli,
  ];
  if (classi.isEmpty) return '';

  final len = lunghezza.clamp(lunghezzaMinima, lunghezzaMassima);
  final tutto = classi.join();

  // Prima un carattere per classe, poi il resto pescato da tutto l'insieme.
  // Se le classi fossero più della lunghezza chiesta (impossibile oggi: 4
  // classi contro un minimo di 8) le eccedenti verrebbero tagliate dal `take`,
  // e la password resterebbe comunque della lunghezza giusta.
  final caratteri = <String>[
    for (final c in classi.take(len)) c[r.nextInt(c.length)],
  ];
  while (caratteri.length < len) {
    caratteri.add(tutto[r.nextInt(tutto.length)]);
  }

  _mescola(caratteri, r);
  return caratteri.join();
}

/// Fisher-Yates. Senza mescolare, i primi caratteri sarebbero sempre uno per
/// classe nello stesso ordine: chi guarda dieci password generate lo vede a
/// occhio, e chi le attacca lo sa in partenza.
void _mescola(List<String> l, Random r) {
  for (var i = l.length - 1; i > 0; i--) {
    final j = r.nextInt(i + 1);
    final t = l[i];
    l[i] = l[j];
    l[j] = t;
  }
}

/// Quanto è robusta, in bit: `lunghezza × log2(dimensione dell'alfabeto)`.
///
/// È la misura onesta — quanti tentativi servono a chi **conosce le regole**
/// del generatore, che è l'ipotesi giusta perché quelle regole stanno scritte
/// qui sopra e chiunque può leggerle. I "punteggi di robustezza" che premiano
/// le sostituzioni tipo `p4ssw0rd` misurano l'ingegno di chi ha scelto la
/// password, non la fatica di chi la indovina.
double bitDiEntropia({
  required int lunghezza,
  bool maiuscole = true,
  bool minuscole = true,
  bool cifre = true,
  bool simboli = true,
}) {
  var dimensione = 0;
  if (minuscole) dimensione += alfabetoMinuscole.length;
  if (maiuscole) dimensione += alfabetoMaiuscole.length;
  if (cifre) dimensione += alfabetoCifre.length;
  if (simboli) dimensione += alfabetoSimboli.length;
  if (dimensione <= 1) return 0;
  return lunghezza * (log(dimensione) / ln2);
}

/// Il giudizio in una parola, per chi non sa cosa sia un bit.
///
/// Le soglie non sono inventate: 60 bit è più o meno dove una GPU sola smette
/// di farcela in tempi umani, 80 dove smette di farcela chiunque.
String giudizio(double bit) {
  if (bit < 45) return 'Debole';
  if (bit < 60) return 'Discreta';
  if (bit < 80) return 'Robusta';
  return 'Molto robusta';
}

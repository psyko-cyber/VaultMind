/// La ricerca del PC, portata sul telefono.
///
/// **Non è un'imitazione**: è la stessa matematica di `embedding.py` e
/// `search.py`, tradotta in Dart. Il PC non usa un modello di intelligenza
/// artificiale per cercare (`backend: hashing-ngram`), usa un vettorializzatore
/// deterministico — quindi qui si ottengono gli stessi identici punteggi.
///
/// Il principio del progetto vale anche qui: **il match è trovato, non
/// generato**. La richiesta diventa un vettore, si confronta per coseno con
/// le voci, e vince chi somiglia di più. Nessun modello generativo tocca le
/// password.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'vault.dart';

const int _dimensioni = 1024;

/// Parole che non aiutano a distinguere una voce dall'altra: si scartano
/// prima di confrontare. Stessa lista di `search.py`.
const _stopword = {
  'dammi', 'dimmi', 'dammela', 'la', 'le', 'il', 'lo', 'i', 'gli', 'un',
  'una', 'uno', 'di', 'del', 'della', 'dello', 'dei', 'delle', 'dell',
  'nell', 'sull', 'all', 'quell', 'dall', 'coll', 'mia', 'mio', 'mie',
  'miei', 'per', 'quella', 'quello', 'quelli', 'quelle', 'cosa', 'roba',
  'tipo', 'password', 'pass', 'pwd', 'credenziali', 'credenziale',
  'account', 'qual', 'quale', 'e', 'ed', 'a', 'ad', 'da', 'su', 'in',
  'con', 'che', 'mostrami', 'mostra', 'trova', 'trovami', 'cerca',
  'cercami', 'fammi', 'vedere', 'recupera', 'ho', 'voglio', 'serve', 'mi',
  'anche', 'the', 'of', 'my', 'me', 'tutti', 'tutte',
};

/// Famiglia Google: "youtube" e "drive" indicano lo stesso account.
/// Volutamente SENZA gmail, come sul PC: "google" non deve tirare su tutte
/// le voci gmail, e "gmail" deve trovare solo quelle.
const _alias = {
  'google': 'google',
  'youtube': 'google',
  'gsuite': 'google',
  'workspace': 'google',
  'drive': 'google',
};

/// Parti di dominio che non identificano nessun servizio.
const _rumoreTld = {'www', 'com', 'net', 'org', 'info', 'biz', 'gov', 'edu'};

/// Etichette il cui VALORE è segreto: non entrano mai nell'indice.
/// Indicizzare una password significherebbe renderla cercabile.
const _indiziSegreto = [
  'password', 'pass', 'pwd', 'pin', 'puc', 'puk', 'otp', 'totp', '2fa',
  'mfa', 'secret', 'segreto', 'seed', 'recovery', 'backup', 'cvv',
  'token', 'chiave', 'key', 'codice', 'code',
];

String _normalizza(String s) {
  var t = s.toLowerCase();
  // Via gli accenti: "società" e "societa" devono combaciare.
  const con = 'àáâãäåèéêëìíîïòóôõöùúûüçñ';
  const senza = 'aaaaaaeeeeiiiiooooouuuucn';
  for (var i = 0; i < con.length; i++) {
    t = t.replaceAll(con[i], senza[i]);
  }
  t = t.replaceAll(RegExp(r'[^a-z0-9@.\s]'), ' ');
  return t.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// I titoli-dominio vanno spezzati: `amazon.it` indicizzato come token unico
/// non combacerebbe la query "amazon", e su un vault Bitwarden i titoli SONO
/// domini. Stessa correzione già fatta sul PC.
List<String> _token(String s) {
  final out = <String>[];
  for (final t in _normalizza(s).split(' ')) {
    if (t.isEmpty || _stopword.contains(t)) continue;
    out.add(t);
    if (t.contains('.') || t.contains('@')) {
      for (final p in t.split(RegExp(r'[.@]'))) {
        if (p.length >= 3 && !_rumoreTld.contains(p) && !_stopword.contains(p)) {
          out.add(p);
        }
      }
    }
  }
  return out;
}

Set<String> _conAlias(Iterable<String> token) {
  final out = token.toSet();
  for (final t in token) {
    final a = _alias[t];
    if (a != null) out.add(a);
  }
  return out;
}

bool _etichettaSegreta(String label) {
  final l = _normalizza(label);
  return _indiziSegreto.any(l.contains);
}

/// Vettore char-n-gram con hashing, identico a `_HashingNgram` del PC:
/// n-grammi da 3 e 4 caratteri, MD5 del gruppo, somma nella cella
/// corrispondente, infine normalizzazione L2.
Float32List _vettore(String testo) {
  final t = '  ${testo.toLowerCase()}  ';
  final v = Float32List(_dimensioni);
  for (final n in [3, 4]) {
    for (var i = 0; i + n <= t.length; i++) {
      final gram = t.substring(i, i + n);
      final digest = md5.convert(utf8.encode(gram)).bytes;
      // Il PC prende l'intero MD5 come numero e ne fa il modulo. Gli ultimi
      // byte del digest bastano: il modulo di una potenza di due dipende solo
      // da quelli, e 1024 lo è.
      var h = 0;
      for (var k = digest.length - 8; k < digest.length; k++) {
        h = ((h << 8) | digest[k]) & 0x7FFFFFFFFFFFFFF;
      }
      v[h % _dimensioni] += 1.0;
    }
  }
  var norma = 0.0;
  for (final x in v) {
    norma += x * x;
  }
  norma = sqrt(norma);
  if (norma > 0) {
    for (var i = 0; i < v.length; i++) {
      v[i] /= norma;
    }
  }
  return v;
}

/// Il "documento" indicizzato di una voce: titolo, tag, etichette e i valori
/// NON segreti. I valori segreti non entrano mai.
String _documento(Credenziale c) {
  final etichette = c.fields.map((f) => f.label).join(' ');
  final valori =
      c.fields.where((f) => !_etichettaSegreta(f.label)).map((f) => f.value).join(' ');
  return '${c.title} ${c.tags.join(' ')} $etichette $valori';
}

String _perVettore(String s) {
  final t = _conAlias(_token(s)).toList()..sort();
  return t.isEmpty ? _normalizza(s) : t.join(' ');
}

/// Token "forti" di una voce, per il punteggio lessicale: titolo, tag ed
/// etichette. NON i valori, altrimenti ogni servizio registrato con una certa
/// mail finirebbe raggruppato con quella mail.
Set<String> _tokenForti(Credenziale c) => _conAlias([
      ..._token(c.title),
      ..._token(c.tags.join(' ')),
      ..._token(c.fields.map((f) => f.label).join(' ')),
    ]);

class Risultato {
  final Credenziale voce;
  final double punteggio;
  const Risultato(this.voce, this.punteggio);
}

/// Indice costruito una volta sola dopo lo sblocco: i vettori delle voci non
/// cambiano fra una ricerca e l'altra, ricalcolarli a ogni tasto premuto
/// sarebbe lo spreco che sul PC costa mezzo secondo con 800 voci.
class IndiceRicerca {
  final List<Credenziale> _voci;
  final List<Float32List> _vettori;
  final List<Set<String>> _forti;

  IndiceRicerca(List<Credenziale> voci)
      : _voci = voci,
        _vettori = voci.map((c) => _vettore(_perVettore(_documento(c)))).toList(),
        _forti = voci.map(_tokenForti).toList();

  int get quante => _voci.length;

  /// Punteggio lessicale: un termine che compare nel TITOLO pesa molto più
  /// dello stesso termine trovato in un'etichetta.
  double _bonus(Set<String> query, int i) {
    if (query.isEmpty) return 0;
    final titolo = _conAlias(_token(_voci[i].title));
    final forti = _forti[i];
    var b = 0.0;
    for (final t in query) {
      if (titolo.contains(t)) {
        b += 0.45;
      } else if (forti.contains(t)) {
        b += 0.24;
      } else if (forti.any((h) => t.length >= 4 && h.length >= 4 && (h.contains(t) || t.contains(h)))) {
        b += 0.05;
      }
    }
    return min(b, 0.9);
  }

  List<Risultato> cerca(String testo, {int quanti = 60}) {
    if (_voci.isEmpty || testo.trim().isEmpty) {
      return _voci.map((c) => Risultato(c, 0)).toList();
    }
    final qv = _vettore(_perVettore(testo));
    final q = _conAlias(_token(testo));

    final esiti = <Risultato>[];
    for (var i = 0; i < _voci.length; i++) {
      var coseno = 0.0;
      final v = _vettori[i];
      for (var k = 0; k < _dimensioni; k++) {
        coseno += v[k] * qv[k];
      }
      esiti.add(Risultato(_voci[i], coseno + _bonus(q, i)));
    }
    esiti.sort((a, b) => b.punteggio.compareTo(a.punteggio));

    // Sotto questa soglia la somiglianza è rumore: meglio dire "nessuna voce"
    // che mostrare 800 risultati a caso.
    final buoni = esiti.where((r) => r.punteggio >= 0.22).toList();
    return buoni.take(quanti).toList();
  }
}

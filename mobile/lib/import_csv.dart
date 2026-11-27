/// Import dal CSV esportato da un altro password manager, sul telefono.
///
/// È `app/import_csv.py` riscritto in Dart, regola per regola, e serve a chi
/// VaultMind lo usa **solo dal telefono**: senza PC non c'è Ollama, quindi
/// niente import intelligente — e va bene così, è una scelta. Ma l'export di
/// Google, Chrome, Bitwarden, LastPass, KeePass, Apple o Firefox ce l'ha
/// chiunque, e per leggerlo non serve nessun LLM: sono colonne con un nome.
///
/// **I due parser devono dare lo stesso risultato.** I casi stanno in
/// `tests/vettore/import/`, `atteso.json` lo scrive il Python
/// (`py -3 tests\test_import_csv.py --scrivi`) e `import_csv_test.dart` lo
/// confronta campo per campo. Una colonna nuova si aggiunge in tutti e due.
///
/// Niente pacchetto `csv` da pub.dev: il formato è RFC 4180, una trentina di
/// righe, e ogni dipendenza in più è codice che legge le password di qualcuno.
library;

/// Una voce letta dal file, non ancora salvata: l'utente la vede prima.
class VoceImport {
  final String titolo;
  final List<(String, String)> campi; // (etichetta, valore)
  final List<String> tags;
  const VoceImport(this.titolo, this.campi, this.tags);

  String? valore(String etichetta) {
    for (final (l, v) in campi) {
      if (l == etichetta) return v;
    }
    return null;
  }

  /// Ha un secret 2FA: si conta per dirlo a fine import, come fa il PC.
  bool get con2fa => campi.any((c) => c.$1 == etichettaOtp && c.$2.isNotEmpty);

  Map<String, Object> toJson() => {
        'title': titolo,
        'fields': [
          for (final (l, v) in campi) {'label': l, 'value': v}
        ],
        'tags': tags,
      };
}

class RisultatoImport {
  /// Da dove sembra venire il file ("Bitwarden", "Chrome o Google"...): solo
  /// per dirlo all'utente, non cambia come si legge.
  final String origine;
  final List<VoceImport> voci;
  const RisultatoImport(this.origine, this.voci);
}

const etichettaOtp = 'OTP (2FA)';
const _titolo = '__title__';
const _tag = '__tags__';

/// Nome di colonna normalizzato -> etichetta nel vault. Uguale a
/// `_COLUMN_MAP` di `import_csv.py`.
const _colonne = <String, String>{
  'name': _titolo,
  'title': _titolo,
  'account': _titolo,
  'servizio': _titolo,
  'titolo': _titolo,
  'nome': _titolo,
  'loginusername': 'Utente',
  'username': 'Utente',
  'user': 'Utente',
  'utente': 'Utente',
  'nomeutente': 'Utente',
  'email': 'Email',
  'loginemail': 'Email',
  'loginpassword': 'Password',
  'password': 'Password',
  'pass': 'Password',
  'loginuri': 'URL',
  'url': 'URL',
  'uri': 'URL',
  'website': 'URL',
  'sito': 'URL',
  'indirizzo': 'URL',
  'logintotp': etichettaOtp,
  'otpsecret': etichettaOtp,
  'totp': etichettaOtp,
  'otpauth': etichettaOtp,
  'otp': etichettaOtp,
  'notes': 'Note',
  'note': 'Note',
  'nota': 'Note',
  'extra': 'Note',
  'folder': _tag,
  'group': _tag,
  'tags': _tag,
  'collection': _tag,
  'grouping': _tag,
  'category': _tag,
  'cartella': _tag,
  'gruppo': _tag,
  'categoria': _tag,
};

/// Colonne di servizio degli export: come campi della voce sarebbero rumore.
const _ignora = {
  'type', 'favorite', 'fields', 'reprompt', 'revision', 'created',
  'modified', 'icon', 'loginuris', 'androidapp',
  'lastmodified',
  'fav',
  'httprealm', 'formactionorigin', 'guid',
  'timecreated', 'timelastused', 'timepasswordchanged',
  'createtime', 'modifytime', 'vault',
};

const _tagRadice = {'root', 'radice'};
const _urlFinti = {'http://sn'};

final _nonAlfanumerico = RegExp(r'[^\p{L}\p{N}]', unicode: true);
String _normColonna(String nome) => nome.toLowerCase().replaceAll(_nonAlfanumerico, '');

/// `str.title()` di Python: maiuscola dopo ogni carattere che non è una
/// lettera, minuscole le altre. Serve all'etichetta delle colonne sconosciute.
String _comeTitolo(String s) {
  final b = StringBuffer();
  var dopoLettera = false;
  for (final r in s.runes) {
    final c = String.fromCharCode(r);
    final lettera = c.toLowerCase() != c.toUpperCase();
    b.write(lettera ? (dopoLettera ? c.toLowerCase() : c.toUpperCase()) : c);
    dopoLettera = lettera;
  }
  return b.toString();
}

final _secretInUri = RegExp(r'[?&]secret=([^&]+)', caseSensitive: false);

/// Nel vault va solo il base32: da `otpauth://...?secret=X` si tiene X.
String _soloSecret(String v) {
  final t = v.trim();
  if (t.toLowerCase().startsWith('otpauth://')) {
    final m = _secretInUri.firstMatch(t);
    if (m != null) return m.group(1)!.trim();
  }
  return t;
}

String _host(String url) {
  var v = url.trim();
  final i = v.indexOf('://');
  if (i >= 0) v = v.substring(i + 3);
  v = v.split('/').first.split('?').first.split('@').last.split(':').first;
  v = v.toLowerCase();
  return v.startsWith('www.') ? v.substring(4) : v;
}

/// Il separatore più frequente nella prima riga, fuori dalle virgolette.
/// Stessa regola di `_separatore` nel Python: a pari merito vince la virgola.
String _separatore(String testo) {
  final conta = {',': 0, ';': 0, '\t': 0};
  var dentro = false;
  for (var i = 0; i < testo.length; i++) {
    final c = testo[i];
    if (c == '"') {
      dentro = !dentro;
    } else if (!dentro && (c == '\r' || c == '\n')) {
      break;
    } else if (!dentro && conta.containsKey(c)) {
      conta[c] = conta[c]! + 1;
    }
  }
  var migliore = ',';
  for (final k in conta.keys) {
    if (conta[k]! > conta[migliore]!) migliore = k;
  }
  return conta[migliore]! > 0 ? migliore : ',';
}

/// Le righe del CSV come il modulo `csv` di Python con il dialetto "excel":
/// virgolette doppie come escape, a capo dentro le virgolette conservati tali
/// e quali, righe vuote saltate.
List<List<String>> _righe(String testo, String sep) {
  final righe = <List<String>>[];
  var riga = <String>[];
  final campo = StringBuffer();
  var tra = false; // dentro un campo tra virgolette
  var iniziato = false; // la riga ha almeno un carattere

  void chiudiCampo() {
    riga.add(campo.toString());
    campo.clear();
  }

  void chiudiRiga() {
    if (iniziato) {
      chiudiCampo();
      righe.add(riga);
    }
    riga = <String>[];
    campo.clear();
    iniziato = false;
  }

  for (var i = 0; i < testo.length; i++) {
    final c = testo[i];
    if (tra) {
      if (c == '"') {
        if (i + 1 < testo.length && testo[i + 1] == '"') {
          campo.write('"');
          i++;
        } else {
          tra = false;
        }
      } else {
        campo.write(c);
      }
      continue;
    }
    if (c == '"' && campo.isEmpty) {
      tra = true;
      iniziato = true;
    } else if (c == sep) {
      chiudiCampo();
      iniziato = true;
    } else if (c == '\r' || c == '\n') {
      if (c == '\r' && i + 1 < testo.length && testo[i + 1] == '\n') i++;
      chiudiRiga();
    } else {
      campo.write(c);
      iniziato = true;
    }
  }
  chiudiRiga();
  return righe;
}

String _origine(Set<String> col) {
  if (col.contains('loginpassword') || col.contains('loginusername') || col.contains('loginuri')) {
    return 'Bitwarden';
  }
  if (col.contains('grouping') || col.contains('extra')) return 'LastPass';
  if (col.contains('httprealm') || col.contains('formactionorigin')) return 'Firefox';
  if (col.contains('otpauth') && col.contains('title')) return '1Password o Apple';
  if (col.contains('title') && col.contains('username') && col.contains('url')) return 'KeePass';
  if (col.containsAll(['name', 'url', 'username', 'password'])) return 'Chrome o Google';
  return 'CSV generico';
}

/// Legge un export CSV. Non salva niente: le voci si mostrano e l'utente
/// conferma.
RisultatoImport leggiCsv(String testo) {
  var t = testo;
  while (t.startsWith('﻿')) {
    t = t.substring(1); // il BOM che Excel e Windows mettono in testa
  }
  if (t.trim().isEmpty) return const RisultatoImport('vuoto', []);

  final righe = _righe(t, _separatore(t));
  if (righe.isEmpty) return const RisultatoImport('non riconosciuto', []);
  final intestazioni = righe.first;
  final origine = _origine(intestazioni.map(_normColonna).toSet());

  final voci = <VoceImport>[];
  for (final valori in righe.skip(1)) {
    // Come il DictReader: una colonna ripetuta tiene l'ultimo valore ma il
    // posto della prima, e le celle oltre le intestazioni si perdono.
    final riga = <String, String>{};
    for (var i = 0; i < intestazioni.length; i++) {
      riga[intestazioni[i]] = i < valori.length ? valori[i] : '';
    }

    var titolo = '';
    final campi = <(String, String)>[];
    final tags = <String>[];
    riga.forEach((colGrezza, valGrezzo) {
      final col = _normColonna(colGrezza);
      var val = valGrezzo.trim();
      if (val.isEmpty || _ignora.contains(col) || _urlFinti.contains(val.toLowerCase())) {
        return;
      }
      final etichetta = _colonne[col];
      if (etichetta == null) {
        campi.add((_comeTitolo(colGrezza.trim()), val));
      } else if (etichetta == _titolo) {
        if (titolo.isEmpty) titolo = val;
      } else if (etichetta == _tag) {
        for (var x in val.replaceAll('/', ',').split(',')) {
          x = x.trim().toLowerCase();
          if (x.isNotEmpty && !tags.contains(x) && !_tagRadice.contains(x)) tags.add(x);
        }
      } else {
        if (etichetta == etichettaOtp) val = _soloSecret(val);
        campi.add((etichetta, val));
      }
    });

    if (titolo.isEmpty && campi.isEmpty) continue;
    if (titolo.isEmpty) {
      String primo(bool Function(String) quale) =>
          campi.firstWhere((c) => quale(c.$1), orElse: () => ('', '')).$2;
      var cand = _host(primo((l) => l == 'URL'));
      if (cand.isEmpty) cand = primo((l) => l == 'Email' || l == 'Utente');
      titolo = cand.isEmpty ? 'voce senza titolo' : cand;
    }
    voci.add(VoceImport(titolo, campi, tags));
  }
  return RisultatoImport(origine, voci);
}

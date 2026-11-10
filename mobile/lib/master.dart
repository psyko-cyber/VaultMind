/// Quando una master password NUOVA è troppo debole per fissarla. Gemello di
/// `VaultMind_Windows/app/master.py`: stesse regole, stessi messaggi, e il
/// perché sta lì.
///
/// Vale solo dove la password si sceglie: chi ha già un vault con una master
/// corta deve poterlo aprire, sempre.
library;

/// Il minimo per una master password NUOVA, lo stesso di `master.py` sul PC.
/// Contato in caratteri veri (`runes`), come `len()` in Python: con
/// `String.length` un'emoji varrebbe due.
const int kMasterMinima = 12;

const _ovvie = {
  'password', 'passw0rd', 'vaultmind', 'vault', 'master', 'masterpassword',
  'qwerty', 'qwertyuiop', 'admin', 'administrator', 'letmein', 'welcome',
  'benvenuto', 'ciaociao', 'iloveyou', 'tiamo', 'juventus', 'napoli',
  'francesco', 'alessandro', 'giuseppe', 'segreto', 'sicurezza',
};

final _file = [
  '0123456789' * 3,
  'abcdefghijklmnopqrstuvwxyz' * 2,
  'qwertyuiopasdfghjklzxcvbnm' * 2,
  '1qaz2wsx3edc4rfv5tgb6yhn7ujm8ik9ol0p',
];

const _contorno = r'0123456789 .,;:!?@#$%&*+-_=/\';

/// Perché questa master non va bene, in una frase per l'utente; `null` se va
/// bene.
String? masterTroppoDebole(String pw) {
  final caratteri = pw.runes.toList();
  if (caratteri.length < kMasterMinima) {
    return 'Scegli una master password di almeno $kMasterMinima caratteri: '
        'è l\'unica chiave del vault. Una frase di tre o quattro parole va '
        'benissimo.';
  }
  if (caratteri.toSet().length < 5) {
    return 'Questa password ripete sempre gli stessi caratteri: '
        'è fra le prime che si provano.';
  }
  final bassa = pw.toLowerCase();
  final rovescia = String.fromCharCodes(bassa.runes.toList().reversed);
  if (_file.any((f) => f.contains(bassa) || f.contains(rovescia))) {
    return 'Questa password è una sequenza della tastiera: '
        'è fra le prime che si provano.';
  }
  var da = 0, a = bassa.length;
  while (da < a && _contorno.contains(bassa[da])) {
    da++;
  }
  while (a > da && _contorno.contains(bassa[a - 1])) {
    a--;
  }
  final nocciolo = bassa.substring(da, a);
  final meta = nocciolo.substring(0, nocciolo.length ~/ 2);
  if (_ovvie.contains(nocciolo) ||
      (meta.isNotEmpty && meta * 2 == nocciolo && _ovvie.contains(meta))) {
    return 'Questa password è una parola comune con qualcosa attaccato: '
        'è fra le prime che si provano.';
  }
  return null;
}

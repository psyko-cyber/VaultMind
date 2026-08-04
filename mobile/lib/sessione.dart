/// La sessione aperta: il vault decifrato, la chiave per riscriverlo, e tutte
/// le modifiche.
///
/// Esiste da quando il telefono **scrive** il vault e non si limita più a
/// leggerlo (04/08/2026). Prima bastava passare il [Vault] alla schermata: per
/// riscriverlo serve anche la chiave, che l'app buttava via subito dopo lo
/// sblocco.
///
/// La chiave vive **solo qui, solo in RAM, solo per questa sessione**: non
/// viene mai scritta da nessuna parte. L'unico posto in cui sopravvive è il
/// Keystore di Android, e solo se l'utente ha attivato l'impronta.
///
/// Ogni modifica passa da un metodo di questa classe, e ogni metodo salva
/// **prima** su disco e aggiorna la memoria **dopo**: se il salvataggio
/// fallisce, l'interfaccia non deve mostrare una modifica che sul vault non
/// c'è. Il contrario è il modo migliore per far credere a qualcuno di aver
/// salvato una password che non è mai stata scritta.
library;

import 'package:flutter/foundation.dart';

import 'archivio.dart';
import 'vault.dart';

/// Una modifica rifiutata per una ragione che ha senso spiegare all'utente
/// (nome vuoto, categoria che non esiste, doppione).
class ModificaRifiutata implements Exception {
  final String messaggio;
  const ModificaRifiutata(this.messaggio);
  @override
  String toString() => messaggio;
}

class Sessione extends ValueNotifier<Vault> {
  final Uint8List chiave;

  Sessione(super.vault, this.chiave);

  Vault get vault => value;

  // ------------------------------------------------------------ salvataggio

  Future<void> _salva(Vault nuovo) async {
    await salvaVaultCifrato(await cifraVault(nuovo, chiave));
    value = nuovo; // solo a disco a posto
  }

  /// Il testo cifrato del vault, per il backup da condividere. Non tocca il
  /// file: è la stessa cifratura, con un nonce suo.
  Future<String> testoCifrato() => cifraVault(value, chiave);

  // -------------------------------------------------------------- categorie

  String? _registrata(String nome) {
    final n = normalizzaCategoria(nome).toLowerCase();
    if (n.isEmpty) return null;
    for (final c in value.categorie) {
      if (c.toLowerCase() == n) return c;
    }
    return null;
  }

  /// Crea una categoria vuota. Se esiste già (anche con altre maiuscole) non
  /// la duplica: restituisce quella.
  Future<String> creaCategoria(String nome) async {
    final pulito = normalizzaCategoria(nome);
    if (pulito.isEmpty) {
      throw const ModificaRifiutata('Il nome della categoria non può essere vuoto.');
    }
    final esistente = _registrata(pulito);
    if (esistente != null) return esistente;
    await _salva(value.con(categorie: [...value.categorie, pulito]));
    return pulito;
  }

  Future<String> rinominaCategoria(String vecchia, String nuova) async {
    final da = _registrata(vecchia);
    if (da == null) throw ModificaRifiutata('La categoria «$vecchia» non esiste.');
    final a = normalizzaCategoria(nuova);
    if (a.isEmpty) {
      throw const ModificaRifiutata('Il nome della categoria non può essere vuoto.');
    }
    final altra = _registrata(a);
    if (altra != null && altra != da) {
      throw ModificaRifiutata('Esiste già una categoria «$altra».');
    }
    await _salva(value.con(
      categorie: value.categorie.map((c) => c == da ? a : c).toList(),
      credenziali:
          value.credenziali.map((c) => c.categoria == da ? c.conCategoria(a) : c).toList(),
    ));
    return a;
  }

  /// Elimina la categoria. Le voci che ci stavano dentro **restano nel vault**,
  /// solo senza categoria: cancellare un raggruppamento non può cancellare le
  /// password che raggruppava.
  Future<int> eliminaCategoria(String nome) async {
    final da = _registrata(nome);
    if (da == null) return 0;
    final liberate = value.credenziali.where((c) => c.categoria == da).length;
    await _salva(value.con(
      categorie: value.categorie.where((c) => c != da).toList(),
      credenziali:
          value.credenziali.map((c) => c.categoria == da ? c.conCategoria('') : c).toList(),
    ));
    return liberate;
  }

  /// Assegna la categoria a più voci in un colpo solo; nome vuoto la toglie.
  /// Una sola riscrittura del vault: cifrarlo per intero una volta per voce
  /// costerebbe come l'import quadratico che sul PC costava minuti.
  Future<int> assegnaCategoria(Iterable<int> ids, String nome) async {
    final String cat;
    if (normalizzaCategoria(nome).isEmpty) {
      cat = '';
    } else {
      final trovata = _registrata(nome);
      if (trovata == null) {
        // Crearla al volo trasformerebbe un errore di battitura in una
        // categoria nuova, ed è proprio l'automatismo che non vogliamo.
        throw ModificaRifiutata('La categoria «$nome» non esiste.');
      }
      cat = trovata;
    }
    final voluti = ids.toSet();
    var toccate = 0;
    final nuove = value.credenziali.map((c) {
      if (voluti.contains(c.id) && c.categoria != cat) {
        toccate++;
        return c.conCategoria(cat);
      }
      return c;
    }).toList();
    if (toccate == 0) return 0; // niente da cambiare, niente da ri-cifrare
    await _salva(value.con(credenziali: nuove));
    return toccate;
  }

  // ------------------------------------------------------------------- voci

  int get _prossimoId =>
      value.credenziali.fold<int>(0, (m, c) => c.id > m ? c.id : m) + 1;

  /// I campi del tutto vuoti si scartano, l'ordine scelto dall'utente resta:
  /// non è estetica, è come vede la voce. Stessa regola di `_clean_fields`.
  List<Campo> _ripulisci(List<Campo> campi) => campi
      .map((c) => Campo(c.label.trim(), c.value))
      .where((c) => c.label.isNotEmpty || c.value.trim().isNotEmpty)
      .toList();

  Future<Credenziale> aggiungiVoce({
    required String titolo,
    required List<Campo> campi,
    List<String> tags = const [],
    bool critica = false,
    String categoria = '',
  }) async {
    final t = titolo.trim();
    if (t.isEmpty) throw const ModificaRifiutata('Il titolo non può essere vuoto.');
    if (categoria.isNotEmpty && _registrata(categoria) == null) {
      throw ModificaRifiutata('La categoria «$categoria» non esiste.');
    }
    final voce = Credenziale(
      id: _prossimoId,
      title: t,
      tags: tags.map((x) => x.trim().toLowerCase()).where((x) => x.isNotEmpty).toList(),
      critical: critica,
      fields: _ripulisci(campi),
      categoria: _registrata(categoria) ?? '',
      // uid casuale e non ricavato dall'id: due dispositivi scollegati che
      // aggiungono una voce prendono entrambi lo stesso `id` (max+1), e al
      // primo sync una delle due sparirebbe.
      uid: uidNuovo(),
      mod: oraOra(),
    );
    // In testa, come fa il PC: l'ultima aggiunta è quella che si cerca.
    await _salva(value.con(credenziali: [voce, ...value.credenziali]));
    return voce;
  }

  Future<void> modificaVoce(
    int id, {
    required String titolo,
    required List<Campo> campi,
    required List<String> tags,
    required bool critica,
    required String categoria,
  }) async {
    final t = titolo.trim();
    if (t.isEmpty) throw const ModificaRifiutata('Il titolo non può essere vuoto.');
    if (categoria.isNotEmpty && _registrata(categoria) == null) {
      throw ModificaRifiutata('La categoria «$categoria» non esiste.');
    }
    var trovata = false;
    final nuove = value.credenziali.map((c) {
      if (c.id != id) return c;
      trovata = true;
      // modificata() conserva uid e i campi sconosciuti, e fa avanzare il
      // contatore: senza, il sync non si accorgerebbe della modifica.
      return c.modificata(
        title: t,
        tags: tags.map((x) => x.trim().toLowerCase()).where((x) => x.isNotEmpty).toList(),
        critical: critica,
        fields: _ripulisci(campi),
        categoria: _registrata(categoria) ?? '',
      );
    }).toList();
    if (!trovata) throw const ModificaRifiutata('Voce non trovata.');
    await _salva(value.con(credenziali: nuove));
  }

  /// Toglie la voce e ne lascia la lapide: senza, l'altro dispositivo — che
  /// ce l'ha ancora — la rimanderebbe indietro al primo sync.
  Future<void> eliminaVoce(int id) async => _salva(value.senzaVoce(id));
}

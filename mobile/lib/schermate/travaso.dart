/// Il primo travaso: prendere il vault dal PC senza passare da un file.
///
/// Prima l'unica strada era: salva un backup sul PC, mandatelo su WhatsApp,
/// aprilo qui. Funziona — il file è cifrato e chi lo intercetta non ci fa
/// niente — ma è un passaggio che si spiega, e ogni passaggio che si spiega è
/// un cliente che si ferma. Con l'app aperta su tutti e due, non serve.
///
/// ## Non c'è nessun protocollo nuovo
///
/// Il canale esisteva già: durante i 120 secondi di abbinamento il PC risponde
/// **anche a chi non firma la sonda**, e nella risposta mette il `salt` — che
/// non è un segreto, è la manciata di byte casuali da cui Argon2 ricava la
/// chiave insieme alla master password. Da lì in poi il telefono ha la stessa
/// chiave del PC, e quello che segue è un sync normalissimo: si crea un vault
/// **vuoto** con quel salt e si lascia che la fusione lo riempia.
///
/// Il vantaggio di riusare la fusione invece di scrivere un "ricevi e salva":
/// se un domani il telefono avesse già qualcosa, non lo perderebbe.
///
/// ## Niente finisce su disco finché non è andata bene
///
/// Il vault vuoto vive **in memoria** fino alla stretta di mano. Se la master
/// password è sbagliata le impronte non tornano, il collegamento si chiude, e
/// sul telefono non resta un vault vuoto cifrato con la chiave sbagliata — che
/// sarebbe la cosa peggiore: un file che si apre e non contiene niente, senza
/// che nessuno capisca perché.
///
/// ## Il limite, dichiarato
///
/// Serve la **stessa rete locale**: il salt arriva dalla scoperta, che è in
/// broadcast e non attraversa una VPN. Fuori casa resta il backup su file.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../impostazioni.dart';
import '../sessione.dart';
import '../sync_gestore.dart';
import '../sync_protocollo.dart';
import '../sync_rete.dart';
import '../tema.dart';
import '../vault.dart';
import 'casa.dart';
import '../icone.dart';

class SchermataTravaso extends StatefulWidget {
  const SchermataTravaso({super.key});

  @override
  State<SchermataTravaso> createState() => _SchermataTravasoState();
}

class _SchermataTravasoState extends State<SchermataTravaso> {
  final _password = TextEditingController();
  final _codice = TextEditingController();
  bool _occupato = false;
  String? _errore;
  String _passo = '';

  @override
  void dispose() {
    _password.dispose();
    _codice.dispose();
    super.dispose();
  }

  /// Chi sta offrendo il vault in questo momento.
  ///
  /// La sonda non si può firmare: la chiave si ricava dal vault, e il vault è
  /// esattamente quello che stiamo chiedendo. Si manda con una chiave finta —
  /// chi ha l'abbinamento aperto risponde lo stesso, ed è l'unico momento in
  /// cui lo fa.
  Future<List<Trovato>> _chiOffreIlVault() async {
    final imp = impostazioni.value;
    final ctx = ContestoSync(
      idDispositivo: imp.idDispositivo,
      nome: imp.nomeDispositivo,
      chiaveVault: List<int>.filled(32, 0),
      leggiVaultCifrato: () async => '',
      riceviVault: (_, _) async => {},
    );
    final trovati =
        await cercaDispositivi(ctx, attesa: const Duration(seconds: 3));
    return trovati.where((t) => t.abbinabile && t.salt.isNotEmpty).toList();
  }

  Future<void> _ricevi() async {
    final master = _password.text;
    final codice = _codice.text.trim();
    if (master.isEmpty) {
      setState(() => _errore = 'Serve la master password del PC.');
      return;
    }
    if (codice.length != 6) {
      setState(() => _errore = 'Il codice ha 6 cifre.');
      return;
    }

    setState(() {
      _occupato = true;
      _errore = null;
      _passo = 'Cerco il PC sulla rete…';
    });

    GestoreSync? gestore;
    try {
      final candidati = await _chiOffreIlVault();
      if (candidati.isEmpty) {
        setState(() => _errore =
            'Nessun PC in attesa. Sul PC apri Sincronizza e premi «Abbina un '
            'dispositivo»: il codice vale 120 secondi, e dovete essere sulla '
            'stessa rete WiFi.');
        return;
      }

      String? ultimoErrore;
      // Si prova con tutti quelli che rispondono: se in casa ci fossero due
      // computer con l'abbinamento aperto, sbagliare il primo non deve
      // costare un giro da capo. Il codice fa da filtro.
      for (final d in candidati) {
        setState(() => _passo = 'Ricavo la chiave dalla master password…');
        final salt = Uint8List.fromList(daEsa(d.salt));
        final chiave = await derivaChiave(master, salt);

        // In memoria, non su disco: ci scrive solo la fusione, e solo dopo
        // che la stretta di mano è andata bene.
        final sessione = Sessione(Vault(const [], salt: salt), chiave);
        gestore = GestoreSync(sessione);
        if (!await gestore.avvia()) {
          ultimoErrore = 'La porta del sync non si è aperta su questo telefono.';
          gestore.dispose();
          gestore = null;
          continue;
        }

        if (!mounted) return;
        setState(() => _passo = 'Ricevo il vault…');
        final esito = await gestore.sincronizzaCon(d, codice: codice);

        if (esito.errore == null) {
          // Prima di andare a casa si chiude QUESTO ascoltatore: la schermata
          // di casa ne apre uno suo, e due sulla stessa porta significa che il
          // secondo non si apre e il sync automatico non parte più.
          await gestore.ferma();
          gestore.dispose();
          if (!mounted) return;
          _password.clear();
          Navigator.of(context).pushReplacement(MaterialPageRoute(
              builder: (_) => SchermataCasa(sessione: sessione)));
          return;
        }

        ultimoErrore = esito.errore;
        await gestore.ferma();
        gestore.dispose();
        gestore = null;
      }
      setState(() => _errore = ultimoErrore ?? 'Travaso non riuscito.');
    } catch (e) {
      setState(() => _errore = 'Travaso non riuscito: $e');
    } finally {
      if (gestore != null) {
        await gestore.ferma();
        gestore.dispose();
      }
      if (mounted) {
        setState(() {
          _occupato = false;
          _passo = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ricevi il vault dal PC')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Sul PC: menu → Sincronizza → «Abbina un dispositivo». '
                'Compare un codice di 6 cifre che vale 120 secondi.',
                style: TextStyle(
                    fontSize: 13, color: context.cTenue, height: 1.55),
              ),
              const SizedBox(height: 22),
              TextField(
                controller: _password,
                obscureText: true,
                autofocus: true,
                enabled: !_occupato,
                decoration: InputDecoration(
                  labelText: 'Master password del PC',
                  prefixIcon: IconaVM(Icone.lucchetto, color: context.cTenue),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _codice,
                keyboardType: TextInputType.number,
                maxLength: 6,
                enabled: !_occupato,
                onSubmitted: (_) => _ricevi(),
                decoration: InputDecoration(
                  labelText: 'Codice mostrato sul PC',
                  hintText: '000000',
                  counterText: '',
                  prefixIcon: IconaVM(Icone.tastierino, color: context.cTenue),
                ),
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: _occupato ? null : _ricevi,
                style: FilledButton.styleFrom(
                  backgroundColor: context.cAccento,
                  foregroundColor: context.cSuAccento,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                ),
                child: _occupato
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: context.cSuAccento))
                    : const Text('Ricevi il vault',
                        style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              if (_passo.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(_passo,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12.5, color: context.cTenue)),
              ],
              if (_errore != null) ...[
                const SizedBox(height: 16),
                Text(_errore!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: context.cErrore, fontSize: 13, height: 1.5)),
              ],
              const SizedBox(height: 26),
              Text(
                'Il vault viaggia cifrato, come il file di backup: sulla rete '
                'non passa niente in chiaro. Serve la stessa WiFi — la ricerca '
                'è in broadcast e non attraversa una VPN.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11.5, color: context.cTenue, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

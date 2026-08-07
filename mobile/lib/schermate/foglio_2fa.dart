/// Come entra un secret 2FA nel telefono: tre strade.
///
/// **Fotocamera** quando il QR è su un altro schermo. **Immagine** quando la
/// 2FA la stai attivando sul browser di *questo* telefono — lì il QR sta sullo
/// schermo che dovresti fotografare, e l'unica via è lo screenshot. **A mano**
/// quando il sito ha già dato il codice scritto, o quando la fotocamera non
/// c'è. Nessuna delle tre copre le altre due: per questo ci sono tutte.
///
/// Il campo a mano accetta sia il secret nudo sia l'`otpauth://` intero — chi
/// copia da una pagina di setup non sa quale dei due ha fra le mani, e
/// chiedergli di distinguerli sarebbe chiedergli di sapere una cosa inutile.
///
/// Legge anche il QR di **«Trasferisci account» di Google Authenticator**, che
/// è un formato diverso (`otpauth-migration://`) e che Google usa **anche per
/// un account solo**: è quindi la prima cosa in cui inciampa chi arriva da lì,
/// non un caso raro. Scoperto sul campo il 07/08/2026, provando l'app.
library;

import 'package:flutter/material.dart';

import '../icone.dart';
import '../ponte_file.dart';
import '../sessione.dart';
import '../tema.dart';
import '../totp.dart';
import '../vault.dart';

/// Apre il foglio e restituisce il secret letto, o `null` se si chiude senza.
///
/// [sessione] serve solo all'import in blocco da un QR di esportazione con più
/// account: senza, quel QR si può ancora usare, ma un account alla volta.
Future<DatiOtp?> mostraFoglio2FA(BuildContext context, {Sessione? sessione}) {
  return showModalBottomSheet<DatiOtp>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _Foglio2FA(sessione: sessione),
  );
}

class _Foglio2FA extends StatefulWidget {
  final Sessione? sessione;
  const _Foglio2FA({this.sessione});

  @override
  State<_Foglio2FA> createState() => _Foglio2FAState();
}

class _Foglio2FAState extends State<_Foglio2FA> {
  final _aMano = TextEditingController();
  bool _campoAperto = false;
  bool _occupato = false;
  String? _errore;

  /// I conti trovati in un QR di esportazione con più di uno dentro: si sceglie
  /// quale va in questa voce, o si importano tutti.
  List<DatiOtp> _daScegliere = const [];

  /// Il riassunto dell'import in blocco, quando è stato fatto.
  String? _fatto;

  @override
  void dispose() {
    _aMano.dispose();
    super.dispose();
  }

  /// Gli errori restano **dentro il foglio** e non in uno SnackBar: uno
  /// SnackBar comparirebbe dietro al foglio stesso, cioè non comparirebbe.
  void _di(String? messaggio) {
    if (mounted) setState(() => _errore = messaggio);
  }

  Future<void> _leggi(Future<RisultatoQr> Function() come) async {
    setState(() {
      _occupato = true;
      _errore = null;
    });
    final r = await come();
    if (!mounted) return;
    setState(() => _occupato = false);

    switch (r.esito) {
      case EsitoQr.annullato:
        return;   // ha deciso lui: non c'è niente da dire
      case EsitoQr.permessoNegato:
        return _di('Senza il permesso della fotocamera non si può inquadrare. '
            'Puoi darlo dalle impostazioni di Android, oppure usare uno '
            'screenshot del QR.');
      case EsitoQr.fotocameraNonDisponibile:
        return _di('La fotocamera non si è aperta: forse la sta usando '
            'un\'altra app. Prova con uno screenshot del QR.');
      case EsitoQr.nessunQr:
        return _di('In quell\'immagine non c\'è nessun QR leggibile. '
            'Serve lo screenshot intero, non una foto dello schermo storta.');
      case EsitoQr.immagineIllegibile:
        return _di('Quel file non si apre come immagine.');
      case EsitoQr.letto:
        break;
    }

    _usa(r.testo!);
  }

  void _daTesto() {
    if (_aMano.text.trim().toLowerCase().startsWith('otpauth-migration')) {
      return _usa(_aMano.text);
    }
    final dati = interpretaSecret(_aMano.text);
    if (dati == null) {
      return _di('Non è un secret valido. Dev\'essere il codice in lettere e '
          'cifre che il sito mostra sotto il QR (base32), oppure '
          'l\'indirizzo otpauth:// intero.');
    }
    _consegna(dati);
  }

  /// Cosa c'era dentro il QR: una 2FA sola, un'esportazione, o altro.
  void _usa(String contenuto) {
    final singolo = leggiOtpauth(contenuto);
    if (singolo != null) {
      _consegna(singolo);
      return;
    }

    // Non è un otpauth: può essere l'esportazione di Google Authenticator, che
    // Google produce anche per un conto solo.
    final elenco = leggiMigrazione(contenuto);
    if (elenco.length == 1) {
      _consegna(elenco.first);
      return;
    }
    if (elenco.length > 1) {
      setState(() {
        _daScegliere = elenco;
        _errore = null;
      });
      return;
    }

    _di(_perche(descriviQr(contenuto)));
  }

  /// Il messaggio deve dire **cosa hai inquadrato**, non solo cosa ci si
  /// aspettava. È la lezione che in questo progetto è già costata tre volte:
  /// un errore che descrive le aspettative di chi l'ha scritto manda a cercare
  /// nel posto sbagliato.
  String _perche(String cosa) => switch (cosa) {
        'esportazione' =>
          'Questo è il QR di esportazione di Google Authenticator, ma dentro '
              'non c\'è nessun conto che VaultMind sappia calcolare — forse '
              'sono tutti a contatore (HOTP), che è un\'altra cosa.',
        'hotp' => 'Questa 2FA è a contatore (HOTP): avanza a ogni codice invece '
            'che con l\'orologio, e VaultMind non tiene contatori. Va tenuta '
            'nell\'app dell\'autenticatore.',
        'otpauth-rotto' =>
          'È un codice otpauth, ma senza un secret leggibile dentro. Prova con '
              'l\'inserimento manuale del sito.',
        'indirizzo' => 'Questo QR contiene un indirizzo web, non una 2FA.',
        'vuoto' => 'Il QR è vuoto.',
        _ => 'Il QR è stato letto, ma dentro non c\'è una 2FA: ci si aspetta un '
            'codice otpauth://totp/, oppure il QR «Trasferisci account» di '
            'Google Authenticator.',
      };

  /// Import in blocco da un QR di esportazione.
  ///
  /// Per ogni conto: se nel vault c'è già una voce con quel nome ci **aggiunge**
  /// il secret, altrimenti ne crea una nuova. Senza l'accorpamento, chi ha già
  /// "Epic Games" con utente e password si ritroverebbe una seconda voce spoglia
  /// con dentro solo la 2FA, e due voci per lo stesso servizio sono peggio di
  /// nessuna.
  Future<void> _importaTutti() async {
    final sessione = widget.sessione;
    if (sessione == null) return;
    setState(() {
      _occupato = true;
      _errore = null;
    });

    var accorpati = 0, creati = 0, saltati = 0;
    for (final d in _daScegliere) {
      if (!d.standard) {
        // Non si importa in silenzio una 2FA che darà codici sempre
        // rifiutati: in blocco non si può nemmeno chiedere venti volte.
        saltati++;
        continue;
      }
      try {
        final esistente = _voceChiamata(sessione.vault, d);
        if (esistente != null) {
          final campi = [
            ...esistente.fields.where((c) => !etichettaSembraOtp(c.label)),
            Campo('OTP (2FA)', d.secret),
          ];
          await sessione.modificaVoce(
            esistente.id,
            titolo: esistente.title,
            campi: campi,
            tags: esistente.tags,
            critica: esistente.critical,
            categoria: esistente.categoria,
          );
          accorpati++;
        } else {
          await sessione.aggiungiVoce(
            titolo: d.titoloProposto.isEmpty ? 'Account 2FA' : d.titoloProposto,
            campi: [Campo('OTP (2FA)', d.secret)],
          );
          creati++;
        }
      } catch (_) {
        saltati++;
      }
    }

    if (!mounted) return;
    setState(() {
      _occupato = false;
      _daScegliere = const [];
      _fatto = [
        if (accorpati > 0) '$accorpati aggiunti a voci che c\'erano già',
        if (creati > 0) '$creati salvati come voci nuove',
        if (saltati > 0) '$saltati saltati perché fuori standard',
      ].join(', ');
    });
  }

  /// La voce del vault che parla dello stesso servizio, se c'è.
  ///
  /// Si guarda il titolo e basta: è quello che una persona riconosce, ed è
  /// l'unica cosa che i due lati hanno davvero in comune.
  Credenziale? _voceChiamata(Vault vault, DatiOtp d) {
    final chiavi = [d.issuer, d.nome, d.titoloProposto]
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.length >= 3)
        .toList();
    for (final c in vault.credenziali) {
      final titolo = c.title.toLowerCase();
      if (chiavi.any((k) => titolo == k || titolo.contains(k))) return c;
    }
    return null;
  }

  /// Un secret con cifre o periodo diversi dallo standard produrrebbe codici
  /// **plausibili e sempre sbagliati**, che è il modo peggiore di rompersi:
  /// chi lo usa dà la colpa al sito. Si dice prima, e si lascia decidere.
  Future<void> _consegna(DatiOtp dati) async {
    if (!dati.standard) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Questa 2FA è fuori standard'),
          content: Text(
            'Il servizio chiede ${dati.cifre} cifre ogni ${dati.periodo} '
            'secondi con ${dati.algoritmo}; VaultMind calcola 6 cifre ogni 30 '
            'con SHA1, come il PC.\n\n'
            'I codici che vedresti sarebbero credibili e sempre rifiutati. '
            'Meglio tenere questa 2FA nell\'app dell\'autenticatore.',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(c).pop(false),
                child: const Text('Lascia perdere')),
            TextButton(
                onPressed: () => Navigator.of(c).pop(true),
                child: const Text('Salvalo lo stesso')),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (mounted) Navigator.of(context).pop(dati);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.cPannello,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        border: Border.all(color: context.cBordo),
      ),
      padding: EdgeInsets.only(
        left: 18,
        right: 18,
        top: 10,
        bottom: MediaQuery.of(context).viewInsets.bottom + 22,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: context.cBordo,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                IconaVM(Icone.qr, size: 20, color: context.cAccento),
                const SizedBox(width: 8),
                Text('Aggiungi la 2FA',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: context.cTesto)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _daScegliere.isNotEmpty
                  ? 'Il QR di Google Authenticator contiene '
                      '${_daScegliere.length} conti. Tocca quello che va in '
                      'questa voce, oppure portali dentro tutti.'
                  : 'Il secret si vede una volta sola: quando attivi la 2FA sul '
                      'sito. È il QR, oppure il codice sotto la voce '
                      '«inserimento manuale». Da un\'app di autenticazione già '
                      'configurata non si estrae più.',
              style: TextStyle(fontSize: 12, color: context.cTenue, height: 1.45),
            ),
            const SizedBox(height: 16),

            if (_fatto != null)
              _riassunto(context)
            else if (_daScegliere.isNotEmpty && !_occupato)
              ..._sceltaConti(context)
            else if (_occupato)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                    child: CircularProgressIndicator(color: context.cAccento)),
              )
            else ...[
              _Strada(
                icona: Icone.fotocamera,
                titolo: 'Inquadra il QR',
                dettaglio: 'Il QR è su un altro schermo, o su carta',
                onTap: () => _leggi(() =>
                    qrDaFotocamera(coloreAccento: context.cAccento.toARGB32())),
              ),
              _Strada(
                icona: Icone.immagine,
                titolo: 'Da uno screenshot',
                dettaglio:
                    'La 2FA la stai attivando su questo telefono: fai lo '
                    'screenshot del QR e scegli quello',
                onTap: () => _leggi(qrDaImmagine),
              ),
              _Strada(
                icona: Icone.tastierino,
                titolo: 'Scrivi il codice',
                dettaglio: 'Hai il secret in lettere e cifre, o il link otpauth',
                onTap: () => setState(() => _campoAperto = !_campoAperto),
              ),
            ],

            if (_campoAperto && !_occupato && _daScegliere.isEmpty && _fatto == null) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _aMano,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Secret o otpauth://',
                  hintText: 'JBSW Y3DP EHPK 3PXP',
                  isDense: true,
                ),
                style: const TextStyle(fontFamily: 'JetBrains Mono', fontSize: 13),
                onSubmitted: (_) => _daTesto(),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _daTesto,
                  style: FilledButton.styleFrom(
                    backgroundColor: context.cAccento,
                    foregroundColor: context.cSuAccento,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  child: const Text('Controlla e aggiungi',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
            ],

            if (_errore != null) ...[
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconaVM(Icone.avviso, size: 16, color: context.cErrore),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_errore!,
                        style: TextStyle(
                            fontSize: 12,
                            height: 1.45,
                            color: context.cErrore)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// L'elenco dei conti trovati in un QR di esportazione.
///
/// Si tocca quello che va **in questa voce**, perché è il gesto che si sta
/// facendo: il foglio è aperto dentro un modulo, non da solo. Portarli dentro
/// tutti resta un pulsante a parte, e non il comportamento automatico — un QR
/// inquadrato per sbaglio non deve creare venti voci.
extension _SceltaConti on _Foglio2FAState {
  List<Widget> _sceltaConti(BuildContext context) => [
        for (final d in _daScegliere)
          InkWell(
            onTap: () => _consegna(d),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              child: Row(
                children: [
                  IconaVM(
                      d.standard ? Icone.scudoOk : Icone.avviso,
                      size: 18,
                      color: d.standard ? context.cVerde : context.cErrore),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            d.titoloProposto.isEmpty
                                ? '(senza nome)'
                                : d.titoloProposto,
                            style: TextStyle(
                                fontSize: 14, color: context.cTesto)),
                        if (!d.standard)
                          Text(
                              '${d.cifre} cifre, ${d.algoritmo}: VaultMind non '
                              'sa calcolarla',
                              style: TextStyle(
                                  fontSize: 11, color: context.cErrore)),
                      ],
                    ),
                  ),
                  IconaVM(Icone.chevronDestra, size: 18, color: context.cTenue),
                ],
              ),
            ),
          ),
        if (widget.sessione != null) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _importaTutti,
              icon: IconaVM(Icone.importa, size: 18, color: context.cAccento),
              label: Text('Portali dentro tutti',
                  style: TextStyle(color: context.cAccento, fontSize: 13)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: context.cAccento.withValues(alpha: 0.55)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Dove c\'è già una voce con quel nome il secret ci si aggiunge; '
              'per gli altri nasce una voce nuova.',
              style: TextStyle(fontSize: 11.5, color: context.cTenue, height: 1.4),
            ),
          ),
        ],
      ];

  Widget _riassunto(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconaVM(Icone.spunta, size: 18, color: context.cVerde),
              const SizedBox(width: 10),
              Expanded(
                child: Text(_fatto!,
                    style: TextStyle(
                        fontSize: 13, height: 1.45, color: context.cTesto)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Controlla i codici che scorrono prima di fidarti: se uno non '
            'corrisponde a quello che il sito chiede, quel secret non è il suo.',
            style: TextStyle(fontSize: 11.5, color: context.cTenue, height: 1.4),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              style: FilledButton.styleFrom(
                backgroundColor: context.cAccento,
                foregroundColor: context.cSuAccento,
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
              child: const Text('Chiudi',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      );
}

/// Una delle tre strade. Icone con **sagome diverse**, non tre varianti della
/// stessa: stanno una sotto l'altra, e se si somigliano tocca leggere il
/// titolo per capire quale sia — cioè l'icona non serve a niente.
class _Strada extends StatelessWidget {
  final String icona;
  final String titolo;
  final String dettaglio;
  final VoidCallback onTap;

  const _Strada({
    required this.icona,
    required this.titolo,
    required this.dettaglio,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: IconaVM(icona, size: 22, color: context.cAccento),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titolo,
                      style: TextStyle(fontSize: 14.5, color: context.cTesto)),
                  const SizedBox(height: 2),
                  Text(dettaglio,
                      style: TextStyle(
                          fontSize: 12, height: 1.35, color: context.cTenue)),
                ],
              ),
            ),
            IconaVM(Icone.chevronDestra, size: 18, color: context.cTenue),
          ],
        ),
      ),
    );
  }
}

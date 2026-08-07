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
library;

import 'package:flutter/material.dart';

import '../icone.dart';
import '../ponte_file.dart';
import '../tema.dart';
import '../totp.dart';

/// Apre il foglio e restituisce il secret letto, o `null` se si chiude senza.
Future<DatiOtp?> mostraFoglio2FA(BuildContext context) {
  return showModalBottomSheet<DatiOtp>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _Foglio2FA(),
  );
}

class _Foglio2FA extends StatefulWidget {
  const _Foglio2FA();

  @override
  State<_Foglio2FA> createState() => _Foglio2FAState();
}

class _Foglio2FAState extends State<_Foglio2FA> {
  final _aMano = TextEditingController();
  bool _campoAperto = false;
  bool _occupato = false;
  String? _errore;

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

    final dati = leggiOtpauth(r.testo!);
    if (dati == null) {
      return _di('Il QR è stato letto, ma non contiene una 2FA: '
          'ci si aspetta un codice che comincia per otpauth://totp/.');
    }
    _consegna(dati);
  }

  void _daTesto() {
    final dati = interpretaSecret(_aMano.text);
    if (dati == null) {
      return _di('Non è un secret valido. Dev\'essere il codice in lettere e '
          'cifre che il sito mostra sotto il QR (base32), oppure '
          'l\'indirizzo otpauth:// intero.');
    }
    _consegna(dati);
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
              'Il secret si vede una volta sola: quando attivi la 2FA sul '
              'sito. È il QR, oppure il codice sotto la voce «inserimento '
              'manuale». Da un\'app di autenticazione già configurata non si '
              'estrae più.',
              style: TextStyle(fontSize: 12, color: context.cTenue, height: 1.45),
            ),
            const SizedBox(height: 16),

            if (_occupato)
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

            if (_campoAperto && !_occupato) ...[
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

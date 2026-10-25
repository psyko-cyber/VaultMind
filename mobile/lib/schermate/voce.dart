/// La schermata di una voce: tutto quello che c'è dentro, e cosa farci.
///
/// È il dettaglio che sul PC sta accanto all'elenco. Prima la voce si apriva
/// sul posto, dentro la riga dell'elenco: i campi stavano stretti, il 2FA era
/// una striscia, e Modifica ed Elimina erano due icone a un centimetro da
/// Copia. Qui il codice 2FA si legge da lontano ed Elimina sta in fondo, da
/// sola.
library;

import 'package:flutter/material.dart';

import '../impostazioni.dart';
import '../sessione.dart';
import '../tema.dart';
import '../totp.dart';
import '../vault.dart';
import '../icone.dart';
import 'dialoghi.dart';
import 'modulo_voce.dart';
import 'scheda_voce.dart';

const _mesi = [
  'gennaio', 'febbraio', 'marzo', 'aprile', 'maggio', 'giugno', 'luglio',
  'agosto', 'settembre', 'ottobre', 'novembre', 'dicembre',
];

/// «25 ottobre 2026». Senza `intl`: un pacchetto per dodici parole no.
String dataEstesa(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.day} ${_mesi[d.month - 1]} ${d.year}';
}

class SchermataVoce extends StatelessWidget {
  final Sessione sessione;

  /// L'id e non la voce: la schermata segue la sessione, quindi una modifica
  /// fatta da qui o arrivata dal sync si vede subito, e una voce cancellata
  /// dall'altro dispositivo non resta a schermo come se ci fosse.
  final int id;

  const SchermataVoce({super.key, required this.sessione, required this.id});

  Credenziale? _voce(Vault v) {
    for (final c in v.credenziali) {
      if (c.id == id) return c;
    }
    return null;
  }

  Future<void> _modifica(BuildContext context, Credenziale c) =>
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ModuloVoce(sessione: sessione, voce: c)));

  Future<void> _elimina(BuildContext context, Credenziale c) async {
    final ok = await confermaDistruttiva(
      context,
      titolo: 'Eliminare "${c.title}"?',
      dettaglio: 'La voce viene tolta dal vault di questo telefono. '
          'Non esiste un cestino, e se il PC non ne ha una copia è persa.',
    );
    if (ok != true || !context.mounted) return;
    try {
      await sessione.eliminaVoce(c.id);
      if (context.mounted) Navigator.of(context).pop();
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Non è stato possibile eliminare la voce.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Vault>(
      valueListenable: sessione,
      builder: (context, vault, _) {
        final c = _voce(vault);
        return Scaffold(
          appBar: AppBar(
            // Trasparente sopra il chiarore: la barra piena tagliava la
            // schermata in due proprio sopra il monogramma.
            backgroundColor: Colors.transparent,
            shape: const Border(),
            actions: c == null
                ? null
                : [
                    ValueListenableBuilder<Impostazioni>(
                      valueListenable: impostazioni,
                      builder: (context, _, _) {
                        final fissata = eFissata(c.id);
                        return IconButton(
                          tooltip: fissata ? 'Togli dalla cima' : 'Fissa in cima',
                          isSelected: fissata,
                          icon: IconaVM(Icone.fissa,
                              color: fissata ? context.cAccento : context.cTenue),
                          onPressed: () => cambiaFissata(c.id),
                        );
                      },
                    ),
                    IconButton(
                      tooltip: 'Modifica',
                      icon: const IconaVM(Icone.matita),
                      onPressed: () => _modifica(context, c),
                    ),
                  ],
          ),
          extendBodyBehindAppBar: true,
          body: c == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Text(
                      'Questa voce non c\'è più: è stata eliminata, forse da '
                      'un altro dispositivo.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.cTenue),
                    ),
                  ),
                )
              : _corpo(context, c),
        );
      },
    );
  }

  Widget _corpo(BuildContext context, Credenziale c) {
    final k = context.cristallo;
    final campi = c.fields.where((f) => f.value.trim().isNotEmpty).toList();
    final normali = campi.where((f) => !etichettaSembraOtp(f.label)).toList();
    final otp = campi.where((f) => etichettaSembraOtp(f.label)).toList();
    final top = MediaQuery.of(context).padding.top + kToolbarHeight;

    return DecoratedBox(
      // Un chiarore fermo dietro al monogramma, al posto del cielo che si
      // muove nella casa: questa schermata si apre e si chiude spesso, e un
      // secondo cielo animato sotto il primo costerebbe senza aggiungere.
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -.78),
          radius: .9,
          colors: [k.alone1, k.alone2.withValues(alpha: 0), context.cFondo.withValues(alpha: 0)],
          stops: const [0, .55, 1],
        ),
      ),
      child: ListView(
        padding: EdgeInsets.fromLTRB(20, top + 8, 20, 32),
        children: [
          Center(child: Monogramma.voce(c, lato: 84)),
          const SizedBox(height: 16),
          Text(c.title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontFamily: 'Space Grotesk',
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                  height: 1.15)),
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              if (c.categoria.isNotEmpty) Pillola(c.categoria),
              if (c.critical)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconaVM(Icone.stella, size: 14, color: context.cAccento),
                    const SizedBox(width: 4),
                    Text('Critica',
                        style: TextStyle(fontSize: 12.5, color: context.cAccento)),
                  ],
                ),
              if (c.mod > 0)
                Text('Modificata il ${dataEstesa(c.mod)}',
                    style: TextStyle(fontSize: 12.5, color: context.cTenue)),
            ],
          ),
          const SizedBox(height: 24),
          if (normali.isNotEmpty)
            Container(
              padding: const EdgeInsets.fromLTRB(16, 4, 6, 4),
              decoration: BoxDecoration(
                color: context.cPannello,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: context.cBordo),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < normali.length; i++) ...[
                    if (i > 0) Divider(height: 1, color: context.cBordo),
                    RigaCampo(campo: normali[i], grande: true),
                  ],
                ],
              ),
            ),
          for (final f in otp) RigaCampo(campo: f, grande: true),
          if (c.tags.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text('Tag', style: TextStyle(fontSize: 13, color: context.cTenue)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final t in c.tags) Pillola(t)],
            ),
          ],
          if (campi.isEmpty)
            Text('Questa voce non ha ancora nessun campo. Modifica per aggiungerne.',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.cTenue)),
          const SizedBox(height: 32),
          Center(
            child: OutlinedButton.icon(
              onPressed: () => _elimina(context, c),
              icon: IconaVM(Icone.cestino, size: 18, color: context.cErrore),
              label: Text('Elimina la voce', style: TextStyle(color: context.cErrore)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: context.cErrore.withValues(alpha: .45)),
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

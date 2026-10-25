/// L'interruttore in vetro, lo stesso del PC.
///
/// Perché non `Switch` di Material: le tre app devono avere lo stesso gesto e
/// la stessa faccia, e la faccia qui è quella decisa in
/// `design/anteprima.html` — vetro che sfoca ciò che ha dietro, un riflesso
/// in alto, e una molla che fa superare di poco la fine corsa. `Switch` ha
/// una forma sua che non si piega fin lì.
///
/// Il pezzo che non si intuisce: **il vetro deve avere qualcosa dietro**.
/// `BackdropFilter` sfoca ciò che è già stato dipinto sotto di lui; sopra un
/// pannello di tinta piatta non c'è niente da sfocare e resta una pillola
/// semitrasparente. Sul PC dietro ci sono due aloni fissi (`body::before`);
/// qui il lavoro lo fa lo sfondo della schermata. Dove non c'è nulla dietro,
/// l'interruttore è comunque leggibile — solo meno interessante.
///
/// Un `BackdropFilter` costa: ridipinge la porzione di schermo che copre. Qui
/// sono pillole da 52x31 e sono poche per schermata, quindi la spesa è
/// trascurabile; metterne uno per riga in una lista lunga non lo sarebbe.
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'tema.dart';

class InterruttoreVetro extends StatelessWidget {
  const InterruttoreVetro({
    super.key,
    required this.acceso,
    required this.onChanged,
  });

  final bool acceso;

  /// `null` disattiva l'interruttore: si vede che c'è e che non si può toccare.
  final ValueChanged<bool>? onChanged;

  static const _larghezza = 52.0;
  static const _altezza = 31.0;
  static const _pallina = 25.0;

  @override
  Widget build(BuildContext context) {
    final chiaro = context.temaChiaro;
    final k = context.cristallo;
    final attivo = onChanged != null;

    // La traccia spenta non può essere un velo bianco come il resto del
    // vetro: la pallina è bianca e nel tema chiaro ci sparirebbe dentro.
    final tracciaSpenta = chiaro
        ? const Color(0xFF0F1729).withValues(alpha: .10)
        : Colors.white.withValues(alpha: .10);
    final bordo = chiaro
        ? const Color(0xFF0F1729).withValues(alpha: .12)
        : Colors.white.withValues(alpha: .16);
    final luce = Colors.white.withValues(alpha: chiaro ? .9 : .34);

    return Semantics(
      toggled: acceso,
      enabled: attivo,
      child: Opacity(
        opacity: attivo ? 1 : .4,
        child: GestureDetector(
          onTap: attivo ? () => onChanged!(!acceso) : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_altezza / 2),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                width: _larghezza,
                height: _altezza,
                // Acceso, la stessa sfumatura dei pulsanti pieni: il neon
                // vuol dire «attivo» in tutta l'app. `AnimatedContainer`
                // passa da tinta a sfumatura senza scatti.
                decoration: BoxDecoration(
                  color: acceso ? null : tracciaSpenta,
                  gradient: acceso
                      ? LinearGradient(colors: [
                          k.neon1.withValues(alpha: .78),
                          k.neon2.withValues(alpha: .78),
                        ])
                      : null,
                  borderRadius: BorderRadius.circular(_altezza / 2),
                  border: Border.all(
                    color: acceso ? k.neon2.withValues(alpha: .7) : bordo,
                  ),
                ),
                child: Stack(
                  children: [
                    // Il riflesso: l'arco di luce che sul vetro vero si forma
                    // dove la superficie curva verso l'alto. Senza, è plastica.
                    Positioned(
                      left: 2,
                      right: 2,
                      top: 1,
                      height: _altezza * .44,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(_altezza / 2),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [luce, luce.withValues(alpha: 0)],
                          ),
                        ),
                      ),
                    ),
                    AnimatedAlign(
                      duration: const Duration(milliseconds: 380),
                      // `easeOutBack` supera di poco e torna: è la molla che
                      // si sente col dito, ed è tutta la differenza fra un
                      // interruttore e un rettangolo che cambia colore.
                      curve: Curves.easeOutBack,
                      alignment:
                          acceso ? Alignment.centerRight : Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2.5),
                        child: Container(
                          width: _pallina,
                          height: _pallina,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0xFFFFFFFF), Color(0xFFE9EEF6)],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: .32),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Una riga di impostazione: titolo, spiegazione, interruttore.
///
/// Sostituisce `SwitchListTile`, che oltre al `Switch` di Material portava con
/// sé una spaziatura sua e non lasciava mettere un'icona accanto al titolo.
class RigaInterruttore extends StatelessWidget {
  const RigaInterruttore({
    super.key,
    required this.titolo,
    required this.acceso,
    required this.onChanged,
    this.descrizione,
    this.icona,
  });

  final String titolo;
  final String? descrizione;

  /// Nome da `Icone`, non un widget: chi chiama non deve sapere come si
  /// disegna un'icona.
  final Widget? icona;
  final bool acceso;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onChanged == null ? null : () => onChanged!(!acceso),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            if (icona != null) ...[icona!, const SizedBox(width: 10)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    titolo,
                    style: TextStyle(fontSize: 15, color: context.cTesto),
                  ),
                  if (descrizione != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        descrizione!,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.35,
                          color: context.cTenue,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            InterruttoreVetro(acceso: acceso, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}

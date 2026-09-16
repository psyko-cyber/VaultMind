/// Su iPhone, prima di tutto: aggiungere VaultMind alla schermata Home.
///
/// Non è un invito di cortesia, è la condizione perché il vault non sparisca.
/// Due fatti di iOS, entrambi muti:
///
/// 1. **Safari svuota la memoria di un sito dopo sette giorni senza uso.** Il
///    vault di chi apre VaultMind una volta a settimana se ne andrebbe da solo.
///    Le app aggiunte alla Home hanno un conteggio a parte e non subiscono
///    questa regola (WebKit, "Updates to Storage Policy").
/// 2. **L'icona sulla Home ha una memoria sua, separata da Safari.** Un vault
///    creato nella scheda di Safari non si vede dall'icona: chi lo crea qui e
///    poi installa crede di averlo perso.
///
/// Per questo la schermata viene **prima** di quella del vault, e non dopo.
/// Si può proseguire nel browser — per provare, o su un iPad in prestito — ma
/// con un pulsante piccolo, e dopo aver letto il perché.
library;

import 'package:flutter/material.dart';

import '../icone.dart';
import '../tema.dart';

class SchermataInstalla extends StatelessWidget {
  final VoidCallback onProsegui;
  const SchermataInstalla({super.key, required this.onProsegui});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(26),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Image.asset('assets/logo.png', width: 80, height: 80),
                  ),
                ),
                const SizedBox(height: 22),
                const Text(
                  'Aggiungi VaultMind alla schermata Home',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontFamily: 'Space Grotesk',
                      fontSize: 22,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                Text(
                  'Da lì si apre come un\'app, funziona senza rete, e il vault '
                  'resta al sicuro.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13.5, color: context.cTenue, height: 1.5),
                ),
                const SizedBox(height: 26),
                const _Passo(
                  numero: 1,
                  testo: 'Tocca Condividi: il quadrato con la freccia verso '
                      'l\'alto. Nelle versioni più recenti di iOS sta nel menu '
                      '«···» della barra di Safari.',
                ),
                const _Passo(
                  numero: 2,
                  testo: 'Scegli «Aggiungi alla schermata Home», poi «Aggiungi».',
                ),
                const _Passo(
                  numero: 3,
                  testo: 'Chiudi Safari e apri VaultMind dalla nuova icona. '
                      'Il vault si crea lì.',
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: context.cPannello,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: context.cBordo),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      IconaVM(Icone.avviso, size: 18, color: context.cErrore),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Perché non qui: Safari cancella i dati di un sito '
                          'dopo 7 giorni senza usarlo, e l\'icona sulla Home ha '
                          'una memoria separata. Un vault creato in questa '
                          'pagina non si vedrebbe dall\'icona.',
                          style: TextStyle(
                              fontSize: 12.5, color: context.cTesto, height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                TextButton(
                  onPressed: onProsegui,
                  child: Text('Continua in Safari, solo per provare',
                      style: TextStyle(color: context.cTenue, fontSize: 13)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Passo extends StatelessWidget {
  final int numero;
  final String testo;
  const _Passo({required this.numero, required this.testo});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: context.cAccento,
              ),
              child: Text('$numero',
                  style: TextStyle(
                      color: context.cSuAccento,
                      fontWeight: FontWeight.w700,
                      fontSize: 14)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(testo, style: const TextStyle(fontSize: 14, height: 1.45)),
              ),
            ),
          ],
        ),
      );
}

// GENERATO DA design/genera_icone.py -- non modificare a mano.
// La sorgente e' design/icone.json; dopo averla cambiata:
//     py -3 design/genera_icone.py

/// Le icone di VaultMind, le stesse identiche del PC e dell'estensione.
///
/// Sono tracciati, non un font e non `Icons.*`: cosi' le tre app disegnano lo
/// stesso lucchetto, invece di tre lucchetti che si somigliano. I comandi SVG
/// sono gia' stati tradotti in chiamate su `Path` dal generatore, quindi qui
/// non c'e' niente da interpretare a runtime e nessun pacchetto in piu'.
///
/// Il colore arriva da `currentColor` come sul web: se non lo si passa,
/// `IconaVM` prende `IconTheme.of(context).color`, che il tema riempie da se'.
library;

import 'package:flutter/widgets.dart';

class Icone {
  static const String lucchetto = 'lucchetto';
  static const String lucchettoAperto = 'lucchetto-aperto';
  static const String chiave = 'chiave';
  static const String scudo = 'scudo';
  static const String scudoOk = 'scudo-ok';
  static const String database = 'database';
  static const String cartella = 'cartella';
  static const String cartellaPiu = 'cartella-piu';
  static const String cartellaOff = 'cartella-off';
  static const String tastierino = 'tastierino';
  static const String chat = 'chat';
  static const String impostazioni = 'impostazioni';
  static const String tema = 'tema';
  static const String sole = 'sole';
  static const String luna = 'luna';
  static const String notte = 'notte';
  static const String backup = 'backup';
  static const String documentoSu = 'documento-su';
  static const String importa = 'importa';
  static const String sync = 'sync';
  static const String aggiorna = 'aggiorna';
  static const String cerca = 'cerca';
  static const String occhio = 'occhio';
  static const String occhioBarrato = 'occhio-barrato';
  static const String copia = 'copia';
  static const String spunta = 'spunta';
  static const String chiudi = 'chiudi';
  static const String piu = 'piu';
  static const String menoCerchio = 'meno-cerchio';
  static const String matita = 'matita';
  static const String cestino = 'cestino';
  static const String microfono = 'microfono';
  static const String stop = 'stop';
  static const String orologio = 'orologio';
  static const String invia = 'invia';
  static const String menu = 'menu';
  static const String altro = 'altro';
  static const String documento = 'documento';
  static const String elenco = 'elenco';
  static const String dado = 'dado';
  static const String qr = 'qr';
  static const String esterno = 'esterno';
  static const String chevronGiu = 'chevron-giu';
  static const String chevronDestra = 'chevron-destra';
  static const String su = 'su';
  static const String giu = 'giu';
  static const String indietro = 'indietro';
  static const String avanti = 'avanti';
  static const String avviso = 'avviso';
  static const String info = 'info';
  static const String scintilla = 'scintilla';
  static const String banca = 'banca';
  static const String identita = 'identita';
  static const String estensione = 'estensione';
  static const String dispositivo = 'dispositivo';
  static const String dispositivi = 'dispositivi';
  static const String rete = 'rete';
  static const String impronta = 'impronta';
  static const String fissa = 'fissa';
  static const String stella = 'stella';
  static const String utente = 'utente';
  static const String globo = 'globo';
}

/// Disegna un'icona da 24x24 alla misura richiesta.
class IconaVM extends StatelessWidget {
  const IconaVM(this.nome, {super.key, this.size = 24, this.color});

  final String nome;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ??
        IconTheme.of(context).color ??
        DefaultTextStyle.of(context).style.color ??
        const Color(0xFF000000);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _PittoreIcona(nome, c)),
    );
  }
}

class _PittoreIcona extends CustomPainter {
  _PittoreIcona(this.nome, this.colore);

  final String nome;
  final Color colore;

  @override
  void paint(Canvas tela, Size misura) {
    final p = _cache.putIfAbsent(nome, () => _tracciati[nome]!());
    final k = misura.width / 24.0;
    tela.save();
    tela.scale(k);
    tela.drawPath(
      p,
      Paint()
        ..style = PaintingStyle.stroke
        // 1.5 nelle unita' della griglia 24, non in pixel: `scale()` lo
        // moltiplica insieme al resto. E' quello che fa anche il browser con
        // un `viewBox` di 24, quindi le due app restano identiche a ogni
        // misura -- che e' tutto il punto di generarle da una sorgente sola.
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = colore,
    );
    tela.restore();
  }

  @override
  bool shouldRepaint(_PittoreIcona v) => v.nome != nome || v.colore != colore;
}

final Map<String, Path> _cache = {};

const Map<String, Path Function()> _tracciati = {
  'lucchetto': _lucchetto,
  'lucchetto-aperto': _lucchettoAperto,
  'chiave': _chiave,
  'scudo': _scudo,
  'scudo-ok': _scudoOk,
  'database': _database,
  'cartella': _cartella,
  'cartella-piu': _cartellaPiu,
  'cartella-off': _cartellaOff,
  'tastierino': _tastierino,
  'chat': _chat,
  'impostazioni': _impostazioni,
  'tema': _tema,
  'sole': _sole,
  'luna': _luna,
  'notte': _notte,
  'backup': _backup,
  'documento-su': _documentoSu,
  'importa': _importa,
  'sync': _sync,
  'aggiorna': _aggiorna,
  'cerca': _cerca,
  'occhio': _occhio,
  'occhio-barrato': _occhioBarrato,
  'copia': _copia,
  'spunta': _spunta,
  'chiudi': _chiudi,
  'piu': _piu,
  'meno-cerchio': _menoCerchio,
  'matita': _matita,
  'cestino': _cestino,
  'microfono': _microfono,
  'stop': _stop,
  'orologio': _orologio,
  'invia': _invia,
  'menu': _menu,
  'altro': _altro,
  'documento': _documento,
  'elenco': _elenco,
  'dado': _dado,
  'qr': _qr,
  'esterno': _esterno,
  'chevron-giu': _chevronGiu,
  'chevron-destra': _chevronDestra,
  'su': _su,
  'giu': _giu,
  'indietro': _indietro,
  'avanti': _avanti,
  'avviso': _avviso,
  'info': _info,
  'scintilla': _scintilla,
  'banca': _banca,
  'identita': _identita,
  'estensione': _estensione,
  'dispositivo': _dispositivo,
  'dispositivi': _dispositivi,
  'rete': _rete,
  'impronta': _impronta,
  'fissa': _fissa,
  'stella': _stella,
  'utente': _utente,
  'globo': _globo,
};

Path _lucchetto() {
  final p = Path();
  p.addRRect(RRect.fromLTRBR(4, 10.5, 20, 21.0, const Radius.circular(2.5)));
  p.moveTo(7.75, 10.5);
  p.lineTo(7.75, 7);
  p.arcToPoint(const Offset(16.25, 7), radius: const Radius.elliptical(4.25, 4.25), rotation: 0, largeArc: false, clockwise: true);
  p.lineTo(16.25, 10.5);
  p.moveTo(12, 14.75);
  p.lineTo(12, 17.25);
  return p;
}
Path _lucchettoAperto() {
  final p = Path();
  p.addRRect(RRect.fromLTRBR(4, 10.5, 20, 21.0, const Radius.circular(2.5)));
  p.moveTo(7.75, 10.5);
  p.lineTo(7.75, 7);
  p.arcToPoint(const Offset(15.91, 5.3), radius: const Radius.elliptical(4.25, 4.25), rotation: 0, largeArc: false, clockwise: true);
  p.moveTo(12, 14.75);
  p.lineTo(12, 17.25);
  return p;
}
Path _chiave() {
  final p = Path();
  p.addOval(Rect.fromCircle(center: const Offset(7.2, 12), radius: 4));
  p.addOval(Rect.fromCircle(center: const Offset(7.2, 12), radius: 1.3));
  p.moveTo(11.2, 12);
  p.lineTo(20.8, 12);
  p.moveTo(17.2, 12);
  p.lineTo(17.2, 15.4);
  p.moveTo(20.4, 12);
  p.lineTo(20.4, 14.6);
  return p;
}
Path _scudo() {
  final p = Path();
  p.moveTo(12, 3.2);
  p.lineTo(4.6, 6.1);
  p.lineTo(4.6, 12.3);
  p.cubicTo(4.6, 16.7, 7.7, 19.9, 12, 21.4);
  p.cubicTo(16.3, 19.9, 19.4, 16.7, 19.4, 12.3);
  p.lineTo(19.4, 6.1);
  p.close();
  return p;
}
Path _scudoOk() {
  final p = Path();
  p.moveTo(12, 3.2);
  p.lineTo(4.6, 6.1);
  p.lineTo(4.6, 12.3);
  p.cubicTo(4.6, 16.7, 7.7, 19.9, 12, 21.4);
  p.cubicTo(16.3, 19.9, 19.4, 16.7, 19.4, 12.3);
  p.lineTo(19.4, 6.1);
  p.close();
  p.moveTo(9, 11.9);
  p.lineTo(11.3, 14.2);
  p.lineTo(15.4, 10.1);
  return p;
}
Path _database() {
  final p = Path();
  p.moveTo(4, 6);
  p.cubicTo(4, 4.34, 7.58, 3, 12, 3);
  p.cubicTo(16.42, 3, 20, 4.34, 20, 6);
  p.cubicTo(20, 7.66, 16.42, 9, 12, 9);
  p.cubicTo(7.58, 9, 4, 7.66, 4, 6);
  p.close();
  p.moveTo(4, 6);
  p.lineTo(4, 12);
  p.cubicTo(4, 13.66, 7.58, 15, 12, 15);
  p.cubicTo(16.42, 15, 20, 13.66, 20, 12);
  p.lineTo(20, 6);
  p.moveTo(4, 12);
  p.lineTo(4, 18);
  p.cubicTo(4, 19.66, 7.58, 21, 12, 21);
  p.cubicTo(16.42, 21, 20, 19.66, 20, 18);
  p.lineTo(20, 12);
  return p;
}
Path _cartella() {
  final p = Path();
  p.moveTo(3.5, 7);
  p.arcToPoint(const Offset(5.5, 5), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: true);
  p.lineTo(8.8, 5);
  p.lineTo(11, 7.6);
  p.lineTo(18.5, 7.6);
  p.arcToPoint(const Offset(20.5, 9.6), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: true);
  p.lineTo(20.5, 18);
  p.arcToPoint(const Offset(18.5, 20), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: true);
  p.lineTo(5.5, 20);
  p.arcToPoint(const Offset(3.5, 18), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: true);
  p.close();
  return p;
}
Path _cartellaPiu() {
  final p = Path();
  p.moveTo(3.5, 7);
  p.arcToPoint(const Offset(5.5, 5), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: true);
  p.lineTo(8.8, 5);
  p.lineTo(11, 7.6);
  p.lineTo(18.5, 7.6);
  p.arcToPoint(const Offset(20.5, 9.6), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: true);
  p.lineTo(20.5, 18);
  p.arcToPoint(const Offset(18.5, 20), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: true);
  p.lineTo(5.5, 20);
  p.arcToPoint(const Offset(3.5, 18), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: true);
  p.close();
  p.moveTo(12, 10.8);
  p.lineTo(12, 16.4);
  p.moveTo(9.2, 13.6);
  p.lineTo(14.8, 13.6);
  return p;
}
Path _cartellaOff() {
  final p = Path();
  p.moveTo(3.5, 7);
  p.arcToPoint(const Offset(5.5, 5), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: true);
  p.lineTo(8.8, 5);
  p.lineTo(11, 7.6);
  p.lineTo(18.5, 7.6);
  p.arcToPoint(const Offset(20.5, 9.6), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: true);
  p.lineTo(20.5, 18);
  p.arcToPoint(const Offset(18.5, 20), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: true);
  p.lineTo(5.5, 20);
  p.arcToPoint(const Offset(3.5, 18), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: true);
  p.close();
  p.moveTo(3.2, 3.2);
  p.lineTo(20.8, 20.8);
  return p;
}
Path _tastierino() {
  final p = Path();
  p.addRRect(RRect.fromLTRBR(3.4, 3.4, 20.599999999999998, 20.599999999999998, const Radius.circular(3)));
  p.addOval(Rect.fromCircle(center: const Offset(8.4, 8.4), radius: 1.15));
  p.addOval(Rect.fromCircle(center: const Offset(15.6, 8.4), radius: 1.15));
  p.addOval(Rect.fromCircle(center: const Offset(8.4, 15.6), radius: 1.15));
  p.addOval(Rect.fromCircle(center: const Offset(15.6, 15.6), radius: 1.15));
  return p;
}
Path _chat() {
  final p = Path();
  p.addRRect(RRect.fromLTRBR(3, 4.5, 21, 17.0, const Radius.circular(3)));
  p.moveTo(8, 17);
  p.lineTo(8, 21);
  p.lineTo(12.4, 17);
  return p;
}
Path _impostazioni() {
  final p = Path();
  p.moveTo(3.5, 7.5);
  p.lineTo(11.5, 7.5);
  p.moveTo(16.5, 7.5);
  p.lineTo(20.5, 7.5);
  p.moveTo(3.5, 16.5);
  p.lineTo(7.5, 16.5);
  p.moveTo(12.5, 16.5);
  p.lineTo(20.5, 16.5);
  p.addOval(Rect.fromCircle(center: const Offset(14, 7.5), radius: 2.5));
  p.addOval(Rect.fromCircle(center: const Offset(10, 16.5), radius: 2.5));
  return p;
}
Path _tema() {
  final p = Path();
  p.addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 8.5));
  p.moveTo(12, 3.5);
  p.arcToPoint(const Offset(12, 20.5), radius: const Radius.elliptical(8.5, 8.5), rotation: 0, largeArc: false, clockwise: true);
  p.close();
  return p;
}
Path _sole() {
  final p = Path();
  p.addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 4));
  p.moveTo(12, 2.8);
  p.lineTo(12, 5);
  p.moveTo(12, 19);
  p.lineTo(12, 21.2);
  p.moveTo(2.8, 12);
  p.lineTo(5, 12);
  p.moveTo(19, 12);
  p.lineTo(21.2, 12);
  p.moveTo(5.5, 5.5);
  p.lineTo(7, 7);
  p.moveTo(17, 17);
  p.lineTo(18.5, 18.5);
  p.moveTo(18.5, 5.5);
  p.lineTo(17, 7);
  p.moveTo(7, 17);
  p.lineTo(5.5, 18.5);
  return p;
}
Path _luna() {
  final p = Path();
  p.moveTo(20.2, 14.6);
  p.arcToPoint(const Offset(9.4, 3.8), radius: const Radius.elliptical(8.7, 8.7), rotation: 0, largeArc: false, clockwise: true);
  p.arcToPoint(const Offset(20.2, 14.6), radius: const Radius.elliptical(8.7, 8.7), rotation: 0, largeArc: true, clockwise: false);
  p.close();
  return p;
}
Path _notte() {
  final p = Path();
  p.moveTo(20.4, 15.3);
  p.arcToPoint(const Offset(10.1, 5), radius: const Radius.elliptical(8.4, 8.4), rotation: 0, largeArc: false, clockwise: true);
  p.arcToPoint(const Offset(20.4, 15.3), radius: const Radius.elliptical(8.4, 8.4), rotation: 0, largeArc: true, clockwise: false);
  p.close();
  p.moveTo(16.6, 3.2);
  p.lineTo(17.3, 5.1);
  p.lineTo(19.2, 5.8);
  p.lineTo(17.3, 6.5);
  p.lineTo(16.6, 8.4);
  p.lineTo(15.9, 6.5);
  p.lineTo(14, 5.8);
  p.lineTo(15.9, 5.1);
  p.close();
  return p;
}
Path _backup() {
  final p = Path();
  p.moveTo(12, 3.2);
  p.lineTo(12, 13.5);
  p.moveTo(8.2, 9.7);
  p.lineTo(12, 13.5);
  p.lineTo(15.8, 9.7);
  p.moveTo(4.5, 15.6);
  p.lineTo(4.5, 18.5);
  p.arcToPoint(const Offset(6.5, 20.5), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: false);
  p.lineTo(17.5, 20.5);
  p.arcToPoint(const Offset(19.5, 18.5), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: false);
  p.lineTo(19.5, 15.6);
  return p;
}
Path _documentoSu() {
  final p = Path();
  p.moveTo(13.4, 3.6);
  p.lineTo(7.2, 3.6);
  p.arcToPoint(const Offset(5.2, 5.6), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: false);
  p.lineTo(5.2, 18.4);
  p.arcToPoint(const Offset(7.2, 20.4), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: false);
  p.lineTo(16.8, 20.4);
  p.arcToPoint(const Offset(18.8, 18.4), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: false);
  p.lineTo(18.8, 8.8);
  p.close();
  p.moveTo(13.4, 3.6);
  p.lineTo(13.4, 8.8);
  p.lineTo(18.6, 8.8);
  p.moveTo(12, 17.2);
  p.lineTo(12, 10.8);
  p.moveTo(9.6, 13.2);
  p.lineTo(12, 10.8);
  p.lineTo(14.4, 13.2);
  return p;
}
Path _importa() {
  final p = Path();
  p.moveTo(12, 13.5);
  p.lineTo(12, 3.2);
  p.moveTo(8.2, 7);
  p.lineTo(12, 3.2);
  p.lineTo(15.8, 7);
  p.moveTo(4.5, 15.6);
  p.lineTo(4.5, 18.5);
  p.arcToPoint(const Offset(6.5, 20.5), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: false);
  p.lineTo(17.5, 20.5);
  p.arcToPoint(const Offset(19.5, 18.5), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: false);
  p.lineTo(19.5, 15.6);
  return p;
}
Path _sync() {
  final p = Path();
  p.moveTo(20.4, 12.6);
  p.arcToPoint(const Offset(6.1, 18.3), radius: const Radius.elliptical(8.5, 8.5), rotation: 0, largeArc: false, clockwise: true);
  p.moveTo(3.6, 11.4);
  p.arcToPoint(const Offset(17.9, 5.7), radius: const Radius.elliptical(8.5, 8.5), rotation: 0, largeArc: false, clockwise: true);
  p.moveTo(17.4, 2.6);
  p.lineTo(17.4, 5.9);
  p.lineTo(14.1, 5.9);
  p.moveTo(6.6, 21.4);
  p.lineTo(6.6, 18.1);
  p.lineTo(9.9, 18.1);
  return p;
}
Path _aggiorna() {
  final p = Path();
  p.moveTo(20.3, 9.6);
  p.arcToPoint(const Offset(20.5, 14), radius: const Radius.elliptical(8.6, 8.6), rotation: 0, largeArc: true, clockwise: false);
  p.moveTo(20.6, 3.9);
  p.lineTo(20.6, 9.6);
  p.lineTo(14.9, 9.6);
  return p;
}
Path _cerca() {
  final p = Path();
  p.addOval(Rect.fromCircle(center: const Offset(11, 11), radius: 6.8));
  p.moveTo(15.9, 15.9);
  p.lineTo(21, 21);
  return p;
}
Path _occhio() {
  final p = Path();
  p.moveTo(2.6, 12);
  p.cubicTo(2.6, 12, 6.1, 5.6, 12, 5.6);
  p.cubicTo(17.9, 5.6, 21.4, 12, 21.4, 12);
  p.cubicTo(21.4, 12, 17.9, 18.4, 12, 18.4);
  p.cubicTo(6.1, 18.4, 2.6, 12, 2.6, 12);
  p.close();
  p.addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 3));
  return p;
}
Path _occhioBarrato() {
  final p = Path();
  p.moveTo(10.1, 5.8);
  p.arcToPoint(const Offset(12, 5.6), radius: const Radius.elliptical(9.5, 9.5), rotation: 0, largeArc: false, clockwise: true);
  p.cubicTo(17.9, 5.6, 21.4, 12, 21.4, 12);
  p.arcToPoint(const Offset(18.5, 15.8), radius: const Radius.elliptical(17.4, 17.4), rotation: 0, largeArc: false, clockwise: true);
  p.moveTo(6.4, 7.9);
  p.arcToPoint(const Offset(2.6, 12), radius: const Radius.elliptical(17.4, 17.4), rotation: 0, largeArc: false, clockwise: false);
  p.cubicTo(2.6, 12, 6.1, 18.4, 12, 18.4);
  p.arcToPoint(const Offset(16, 17.5), radius: const Radius.elliptical(9.5, 9.5), rotation: 0, largeArc: false, clockwise: false);
  p.moveTo(10, 10);
  p.arcToPoint(const Offset(14, 14), radius: const Radius.elliptical(2.8, 2.8), rotation: 0, largeArc: false, clockwise: false);
  p.moveTo(3.2, 3.2);
  p.lineTo(20.8, 20.8);
  return p;
}
Path _copia() {
  final p = Path();
  p.addRRect(RRect.fromLTRBR(9, 9, 20.5, 20.5, const Radius.circular(2.5)));
  p.moveTo(6, 15);
  p.lineTo(5.5, 15);
  p.arcToPoint(const Offset(3, 12.5), radius: const Radius.elliptical(2.5, 2.5), rotation: 0, largeArc: false, clockwise: true);
  p.lineTo(3, 5.5);
  p.arcToPoint(const Offset(5.5, 3), radius: const Radius.elliptical(2.5, 2.5), rotation: 0, largeArc: false, clockwise: true);
  p.lineTo(12.5, 3);
  p.arcToPoint(const Offset(15, 5.5), radius: const Radius.elliptical(2.5, 2.5), rotation: 0, largeArc: false, clockwise: true);
  p.lineTo(15, 6);
  return p;
}
Path _spunta() {
  final p = Path();
  p.moveTo(4.5, 12.6);
  p.lineTo(9.6, 17.7);
  p.lineTo(19.5, 6.6);
  return p;
}
Path _chiudi() {
  final p = Path();
  p.moveTo(6.2, 6.2);
  p.lineTo(17.8, 17.8);
  p.moveTo(17.8, 6.2);
  p.lineTo(6.2, 17.8);
  return p;
}
Path _piu() {
  final p = Path();
  p.moveTo(12, 4.8);
  p.lineTo(12, 19.2);
  p.moveTo(4.8, 12);
  p.lineTo(19.2, 12);
  return p;
}
Path _menoCerchio() {
  final p = Path();
  p.addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 8.5));
  p.moveTo(8, 12);
  p.lineTo(16, 12);
  return p;
}
Path _matita() {
  final p = Path();
  p.moveTo(16.4, 3.6);
  p.arcToPoint(const Offset(19.4, 6.6), radius: const Radius.elliptical(2.15, 2.15), rotation: 0, largeArc: false, clockwise: true);
  p.lineTo(7.4, 18.6);
  p.lineTo(3, 20);
  p.lineTo(4.4, 15.6);
  p.close();
  p.moveTo(14.4, 5.6);
  p.lineTo(17.4, 8.6);
  return p;
}
Path _cestino() {
  final p = Path();
  p.moveTo(4, 6.6);
  p.lineTo(20, 6.6);
  p.moveTo(9.6, 6.6);
  p.lineTo(9.6, 4.8);
  p.arcToPoint(const Offset(10.8, 3.6), radius: const Radius.elliptical(1.2, 1.2), rotation: 0, largeArc: false, clockwise: true);
  p.lineTo(13.2, 3.6);
  p.arcToPoint(const Offset(14.4, 4.8), radius: const Radius.elliptical(1.2, 1.2), rotation: 0, largeArc: false, clockwise: true);
  p.lineTo(14.4, 6.6);
  p.moveTo(6.2, 6.6);
  p.lineTo(7.1, 19.3);
  p.arcToPoint(const Offset(9.1, 21.2), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: false);
  p.lineTo(14.9, 21.2);
  p.arcToPoint(const Offset(16.9, 19.3), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: false);
  p.lineTo(17.8, 6.6);
  p.moveTo(10.2, 10.8);
  p.lineTo(10.2, 17);
  p.moveTo(13.8, 10.8);
  p.lineTo(13.8, 17);
  return p;
}
Path _microfono() {
  final p = Path();
  p.addRRect(RRect.fromLTRBR(9, 2.6, 15, 14.0, const Radius.circular(3)));
  p.moveTo(5.6, 11.6);
  p.arcToPoint(const Offset(18.4, 11.6), radius: const Radius.elliptical(6.4, 6.4), rotation: 0, largeArc: false, clockwise: false);
  p.moveTo(12, 18);
  p.lineTo(12, 21.4);
  p.moveTo(8.6, 21.4);
  p.lineTo(15.4, 21.4);
  return p;
}
Path _stop() {
  final p = Path();
  p.addRRect(RRect.fromLTRBR(6.6, 6.6, 17.4, 17.4, const Radius.circular(2.5)));
  return p;
}
Path _orologio() {
  final p = Path();
  p.addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 8.5));
  p.moveTo(12, 7.2);
  p.lineTo(12, 12);
  p.lineTo(15.4, 14);
  return p;
}
Path _invia() {
  final p = Path();
  p.moveTo(21, 3);
  p.lineTo(3, 9.8);
  p.lineTo(10.4, 13.2);
  p.lineTo(13.8, 21);
  p.close();
  p.moveTo(21, 3);
  p.lineTo(10.4, 13.2);
  return p;
}
Path _menu() {
  final p = Path();
  p.moveTo(4, 7);
  p.lineTo(20, 7);
  p.moveTo(4, 12);
  p.lineTo(20, 12);
  p.moveTo(4, 17);
  p.lineTo(20, 17);
  return p;
}
Path _altro() {
  final p = Path();
  p.addOval(Rect.fromCircle(center: const Offset(12, 5.4), radius: 1.4));
  p.addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 1.4));
  p.addOval(Rect.fromCircle(center: const Offset(12, 18.6), radius: 1.4));
  return p;
}
Path _documento() {
  final p = Path();
  p.moveTo(13.8, 3.5);
  p.lineTo(7.5, 3.5);
  p.arcToPoint(const Offset(5.5, 5.5), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: false);
  p.lineTo(5.5, 18.5);
  p.arcToPoint(const Offset(7.5, 20.5), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: false);
  p.lineTo(16.5, 20.5);
  p.arcToPoint(const Offset(18.5, 18.5), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: false);
  p.lineTo(18.5, 8.2);
  p.close();
  p.moveTo(13.8, 3.5);
  p.lineTo(13.8, 8.2);
  p.lineTo(18.5, 8.2);
  return p;
}
Path _elenco() {
  final p = Path();
  p.moveTo(8.5, 7);
  p.lineTo(20, 7);
  p.moveTo(8.5, 12);
  p.lineTo(20, 12);
  p.moveTo(8.5, 17);
  p.lineTo(20, 17);
  p.moveTo(4, 7);
  p.lineTo(4.01, 7);
  p.moveTo(4, 12);
  p.lineTo(4.01, 12);
  p.moveTo(4, 17);
  p.lineTo(4.01, 17);
  return p;
}
Path _dado() {
  final p = Path();
  p.addRRect(RRect.fromLTRBR(3.5, 3.5, 20.5, 20.5, const Radius.circular(3.5)));
  p.addOval(Rect.fromCircle(center: const Offset(8.6, 8.6), radius: 1.3));
  p.addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 1.3));
  p.addOval(Rect.fromCircle(center: const Offset(15.4, 15.4), radius: 1.3));
  return p;
}
Path _qr() {
  final p = Path();
  p.addRRect(RRect.fromLTRBR(3.4, 3.4, 10.4, 10.4, const Radius.circular(1.8)));
  p.addRRect(RRect.fromLTRBR(13.6, 3.4, 20.6, 10.4, const Radius.circular(1.8)));
  p.addRRect(RRect.fromLTRBR(3.4, 13.6, 10.4, 20.6, const Radius.circular(1.8)));
  p.moveTo(13.6, 13.6);
  p.lineTo(16.8, 13.6);
  p.lineTo(16.8, 16.8);
  p.lineTo(13.6, 16.8);
  p.close();
  p.moveTo(20.6, 17.4);
  p.lineTo(20.6, 20.6);
  p.lineTo(17.4, 20.6);
  return p;
}
Path _esterno() {
  final p = Path();
  p.moveTo(14.2, 3.6);
  p.lineTo(20.4, 3.6);
  p.lineTo(20.4, 9.8);
  p.moveTo(20.4, 3.6);
  p.lineTo(11.6, 12.4);
  p.moveTo(18.2, 14);
  p.lineTo(18.2, 18.4);
  p.arcToPoint(const Offset(16.2, 20.4), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: true);
  p.lineTo(5.6, 20.4);
  p.arcToPoint(const Offset(3.6, 18.4), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: true);
  p.lineTo(3.6, 7.8);
  p.arcToPoint(const Offset(5.6, 5.8), radius: const Radius.elliptical(2, 2), rotation: 0, largeArc: false, clockwise: true);
  p.lineTo(10, 5.8);
  return p;
}
Path _chevronGiu() {
  final p = Path();
  p.moveTo(6.4, 9.4);
  p.lineTo(12, 15);
  p.lineTo(17.6, 9.4);
  return p;
}
Path _chevronDestra() {
  final p = Path();
  p.moveTo(9.4, 6.4);
  p.lineTo(15, 12);
  p.lineTo(9.4, 17.6);
  return p;
}
Path _su() {
  final p = Path();
  p.moveTo(6.4, 14.6);
  p.lineTo(12, 9);
  p.lineTo(17.6, 14.6);
  return p;
}
Path _giu() {
  final p = Path();
  p.moveTo(6.4, 9.4);
  p.lineTo(12, 15);
  p.lineTo(17.6, 9.4);
  return p;
}
Path _indietro() {
  final p = Path();
  p.moveTo(20, 12);
  p.lineTo(4.6, 12);
  p.moveTo(10.6, 5.8);
  p.lineTo(4.4, 12);
  p.lineTo(10.6, 18.2);
  return p;
}
Path _avanti() {
  final p = Path();
  p.moveTo(4, 12);
  p.lineTo(19.4, 12);
  p.moveTo(13.4, 5.8);
  p.lineTo(19.6, 12);
  p.lineTo(13.4, 18.2);
  return p;
}
Path _avviso() {
  final p = Path();
  p.moveTo(10.7, 4.3);
  p.lineTo(2.7, 18.1);
  p.arcToPoint(const Offset(4, 20.4), radius: const Radius.elliptical(1.5, 1.5), rotation: 0, largeArc: false, clockwise: false);
  p.lineTo(20, 20.4);
  p.arcToPoint(const Offset(21.3, 18.1), radius: const Radius.elliptical(1.5, 1.5), rotation: 0, largeArc: false, clockwise: false);
  p.lineTo(13.3, 4.3);
  p.arcToPoint(const Offset(10.7, 4.3), radius: const Radius.elliptical(1.5, 1.5), rotation: 0, largeArc: false, clockwise: false);
  p.close();
  p.moveTo(12, 9.5);
  p.lineTo(12, 13.5);
  p.moveTo(12, 17);
  p.lineTo(12.01, 17);
  return p;
}
Path _info() {
  final p = Path();
  p.addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 8.5));
  p.moveTo(12, 11.2);
  p.lineTo(12, 16.2);
  p.moveTo(12, 7.9);
  p.lineTo(12.01, 7.9);
  return p;
}
Path _scintilla() {
  final p = Path();
  p.moveTo(11, 3.4);
  p.lineTo(12.9, 8.3);
  p.lineTo(17.8, 10.2);
  p.lineTo(12.9, 12.1);
  p.lineTo(11, 17);
  p.lineTo(9.1, 12.1);
  p.lineTo(4.2, 10.2);
  p.lineTo(9.1, 8.3);
  p.close();
  p.moveTo(17.9, 15.1);
  p.lineTo(18.7, 17.1);
  p.lineTo(20.7, 17.9);
  p.lineTo(18.7, 18.7);
  p.lineTo(17.9, 20.7);
  p.lineTo(17.1, 18.7);
  p.lineTo(15.1, 17.9);
  p.lineTo(17.1, 17.1);
  p.close();
  return p;
}
Path _banca() {
  final p = Path();
  p.moveTo(3.4, 9.4);
  p.lineTo(12, 4.2);
  p.lineTo(20.6, 9.4);
  p.moveTo(5.8, 9.8);
  p.lineTo(5.8, 18.2);
  p.moveTo(9.9, 9.8);
  p.lineTo(9.9, 18.2);
  p.moveTo(14.1, 9.8);
  p.lineTo(14.1, 18.2);
  p.moveTo(18.2, 9.8);
  p.lineTo(18.2, 18.2);
  p.moveTo(3.2, 20.6);
  p.lineTo(20.8, 20.6);
  return p;
}
Path _identita() {
  final p = Path();
  p.addRRect(RRect.fromLTRBR(2.6, 4.8, 21.400000000000002, 19.2, const Radius.circular(2.5)));
  p.addOval(Rect.fromCircle(center: const Offset(8.6, 11), radius: 2.1));
  p.moveTo(5.4, 16.6);
  p.arcToPoint(const Offset(11.8, 16.6), radius: const Radius.elliptical(3.6, 3.6), rotation: 0, largeArc: false, clockwise: true);
  p.moveTo(14.6, 10);
  p.lineTo(18.8, 10);
  p.moveTo(14.6, 13.6);
  p.lineTo(18.8, 13.6);
  return p;
}
Path _estensione() {
  final p = Path();
  p.addRRect(RRect.fromLTRBR(3, 4.6, 21, 19.4, const Radius.circular(2.5)));
  p.moveTo(3, 9.4);
  p.lineTo(21, 9.4);
  p.addOval(Rect.fromCircle(center: const Offset(6.2, 7), radius: 0.75));
  p.addOval(Rect.fromCircle(center: const Offset(8.9, 7), radius: 0.75));
  return p;
}
Path _dispositivo() {
  final p = Path();
  p.addRRect(RRect.fromLTRBR(7, 2.6, 17, 21.400000000000002, const Radius.circular(2.5)));
  p.moveTo(10.6, 5.6);
  p.lineTo(13.4, 5.6);
  p.moveTo(12, 18.2);
  p.lineTo(12.01, 18.2);
  return p;
}
Path _dispositivi() {
  final p = Path();
  p.addRRect(RRect.fromLTRBR(2.6, 5, 15.0, 14.4, const Radius.circular(2)));
  p.moveTo(6, 18);
  p.lineTo(11.6, 18);
  p.moveTo(8.8, 14.4);
  p.lineTo(8.8, 18);
  p.addRRect(RRect.fromLTRBR(16.6, 9.6, 21.400000000000002, 20.0, const Radius.circular(1.6)));
  return p;
}
Path _rete() {
  final p = Path();
  p.moveTo(4.6, 8.6);
  p.arcToPoint(const Offset(19.4, 8.6), radius: const Radius.elliptical(10.5, 10.5), rotation: 0, largeArc: false, clockwise: true);
  p.moveTo(7.6, 11.9);
  p.arcToPoint(const Offset(16.4, 11.9), radius: const Radius.elliptical(6.2, 6.2), rotation: 0, largeArc: false, clockwise: true);
  p.moveTo(10.4, 15.2);
  p.arcToPoint(const Offset(13.6, 15.2), radius: const Radius.elliptical(2.3, 2.3), rotation: 0, largeArc: false, clockwise: true);
  p.moveTo(12, 18.6);
  p.lineTo(12.01, 18.6);
  return p;
}
Path _impronta() {
  final p = Path();
  p.moveTo(4.7, 19.6);
  p.lineTo(4.7, 18.2);
  p.arcToPoint(const Offset(19.6, 17.6), radius: const Radius.elliptical(8.6, 9.4), rotation: 0, largeArc: true, clockwise: true);
  p.lineTo(19.6, 20);
  p.moveTo(7.3, 18);
  p.lineTo(7.3, 15.8);
  p.arcToPoint(const Offset(16.9, 15.2), radius: const Radius.elliptical(5.2, 5.9), rotation: 0, largeArc: true, clockwise: true);
  p.lineTo(16.9, 18.2);
  p.moveTo(10.2, 16.7);
  p.lineTo(10.2, 13.9);
  p.arcToPoint(const Offset(13.9, 13.7), radius: const Radius.elliptical(1.9, 2.4), rotation: 0, largeArc: true, clockwise: true);
  p.lineTo(13.9, 17.1);
  return p;
}
Path _fissa() {
  final p = Path();
  p.moveTo(14.8, 3.4);
  p.lineTo(20.6, 9.2);
  p.lineTo(17.5, 12.3);
  p.lineTo(16.6, 17.8);
  p.lineTo(8.2, 9.4);
  p.lineTo(13.7, 8.5);
  p.close();
  p.moveTo(8.2, 15.8);
  p.lineTo(3.4, 20.6);
  return p;
}
Path _stella() {
  final p = Path();
  p.moveTo(12, 3.4);
  p.lineTo(14.7, 8.8);
  p.lineTo(20.7, 9.7);
  p.lineTo(16.4, 13.9);
  p.lineTo(17.4, 19.9);
  p.lineTo(12, 17.1);
  p.lineTo(6.6, 19.9);
  p.lineTo(7.6, 13.9);
  p.lineTo(3.3, 9.7);
  p.lineTo(9.3, 8.8);
  p.close();
  return p;
}
Path _utente() {
  final p = Path();
  p.addOval(Rect.fromCircle(center: const Offset(12, 8.2), radius: 3.9));
  p.moveTo(4.6, 20.4);
  p.arcToPoint(const Offset(19.4, 20.4), radius: const Radius.elliptical(7.6, 7.6), rotation: 0, largeArc: false, clockwise: true);
  return p;
}
Path _globo() {
  final p = Path();
  p.addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 8.5));
  p.moveTo(3.5, 12);
  p.lineTo(20.5, 12);
  p.moveTo(12, 3.5);
  p.arcToPoint(const Offset(12, 20.5), radius: const Radius.elliptical(13, 13), rotation: 0, largeArc: false, clockwise: true);
  p.arcToPoint(const Offset(12, 3.5), radius: const Radius.elliptical(13, 13), rotation: 0, largeArc: false, clockwise: true);
  p.close();
  return p;
}

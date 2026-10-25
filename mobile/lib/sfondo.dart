/// Lo sfondo delle tre sezioni: costellazione, aurora o tinta unita.
///
/// È la stessa scena del PC (`#sfondo` e `Costellazione` in `index.html`): un
/// fondo sfumato, tre aloni che derivano lentissimi e, per la costellazione,
/// una nuvola di punti su un guscio sferico, ruotata piano e proiettata in
/// prospettiva, coi vicini legati da fili sottili. Le coppie di vicini si
/// calcolano una volta sola: una rotazione non cambia le distanze.
///
/// Quello che sul telefono cambia, e perché:
/// - **meno punti** (120 invece di 180): la sfera qui è larga metà di quella
///   del PC, e con gli stessi punti diventava una ragnatela;
/// - **le pose** ([posaSblocco] e le altre): lo schermo è stretto e alto, e il
///   raggio si misura sul lato corto;
/// - **niente sfocatura sopra**: ogni fotogramma della costellazione la
///   farebbe ricalcolare, e la batteria è del telefono. Per questo schede e
///   bolle restano opache: il testo sta sempre su un colore pieno, mai su
///   punti che si muovono;
/// - **niente onda e niente lampo** quando la chat trova una voce: sul PC c'è
///   spazio accanto alla colonna per vederli, qui la scheda copre tutto;
/// - **niente grana**: sul PC toglie le bande alle sfumature grandi di un
///   monitor; sullo schermo di un telefono non si vedono.
///
/// Gira solo se si vede: un'altra schermata sopra spegne il `Ticker` da sola
/// (`TickerMode`), un'app in secondo piano non riceve fotogrammi, e la tinta
/// unita non lo accende nemmeno. Con «Rimuovi animazioni» di Android la scena
/// si disegna una volta e sta ferma.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'tema.dart';

enum Sfondo { costellazione, aurora, tinta }

const nomiSfondo = {
  Sfondo.costellazione: 'Costellazione',
  Sfondo.aurora: 'Aurora',
  Sfondo.tinta: 'Tinta unita',
};

/// Dove sta la nuvola: centro e raggio in frazioni dello schermo, e quanto si
/// vede (le sezioni piene di testo la vogliono più tenue).
@immutable
class PosaCielo {
  const PosaCielo({
    required this.cx,
    required this.cy,
    required this.raggio,
    this.intensita = 1,
  });

  final double cx, cy, raggio, intensita;

  PosaCielo verso(PosaCielo b, double t) => PosaCielo(
        cx: cx + (b.cx - cx) * t,
        cy: cy + (b.cy - cy) * t,
        raggio: raggio + (b.raggio - raggio) * t,
        intensita: intensita + (b.intensita - intensita) * t,
      );

  @override
  bool operator ==(Object other) =>
      other is PosaCielo &&
      other.cx == cx &&
      other.cy == cy &&
      other.raggio == raggio &&
      other.intensita == intensita;

  @override
  int get hashCode => Object.hash(cx, cy, raggio, intensita);
}

/// Dietro al logo, nello sblocco; più in alto e più tenue dietro la chat; a
/// destra nel database, dove le schede lasciano un po' di margine.
const posaSblocco = PosaCielo(cx: .5, cy: .34, raggio: .46);
const posaChat = PosaCielo(cx: .5, cy: .40, raggio: .44, intensita: .75);
const posaDatabase = PosaCielo(cx: .64, cy: .52, raggio: .52, intensita: .62);

double _morbido(double p) =>
    p < .5 ? 4 * p * p * p : 1 - math.pow(-2 * p + 2, 3) / 2;

class SfondoCristallo extends StatefulWidget {
  const SfondoCristallo({
    super.key,
    required this.tipo,
    required this.posa,
    this.seme = 3,
  });

  final Sfondo tipo;
  final PosaCielo posa;
  final int seme;

  @override
  State<SfondoCristallo> createState() => _SfondoCristalloState();
}

class _SfondoCristalloState extends State<SfondoCristallo>
    with SingleTickerProviderStateMixin {
  /// Il tempo della rotazione, condiviso fra uno sfondo e il successivo:
  /// sbloccando, la nuvola della casa riparte da dove era quella dello
  /// sblocco invece di saltare.
  static double _orologio = 24;

  late final _Scena _s;
  late final Ticker _ticker;
  Duration _prima = Duration.zero;
  double _dalDisegno = 1;
  bool _ferma = false;

  PosaCielo? _da;
  double _corsa = 1;   // 0..1 lo spostamento verso la posa nuova; 1 = arrivato

  double get _auroraVoluta => widget.tipo == Sfondo.tinta ? 0 : 1;
  double get _cieloVoluto => widget.tipo == Sfondo.costellazione ? 1 : 0;

  bool get _inTransito =>
      _corsa < 1 ||
      _s.opAurora != _auroraVoluta ||
      _s.opCielo != _cieloVoluto;

  @override
  void initState() {
    super.initState();
    _s = _Scena(widget.seme)
      ..t = _orologio
      ..posa = widget.posa
      ..opAurora = _auroraVoluta
      ..opCielo = _cieloVoluto;
    _ticker = createTicker(_passo);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ferma = MediaQuery.disableAnimationsOf(context);
    _governa();
  }

  @override
  void didUpdateWidget(SfondoCristallo vecchio) {
    super.didUpdateWidget(vecchio);
    if (widget.posa != vecchio.posa) {
      _da = _s.posa;
      _corsa = 0;
    }
    _governa();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _s.dispose();
    super.dispose();
  }

  /// Accende o spegne il giro secondo quello che c'è da far muovere.
  void _governa() {
    if (_ferma) {
      _ticker.stop();
      _corsa = 1;
      _s
        ..posa = widget.posa
        ..opAurora = _auroraVoluta
        ..opCielo = _cieloVoluto
        ..ridisegna();
      return;
    }
    final serve = widget.tipo != Sfondo.tinta || _inTransito;
    if (serve && !_ticker.isActive) {
      _prima = Duration.zero;
      _ticker.start();
    } else if (!serve && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _passo(Duration ora) {
    // Al ritorno da una pausa la rotazione riprende da dov'era, non salta
    // avanti di quanto è rimasta ferma.
    final dt = math.min(.1, (ora - _prima).inMicroseconds / 1e6);
    _prima = ora;
    _s.t += dt;
    _orologio = _s.t;

    final transito = _inTransito;
    if (transito) {
      // I livelli sfumano in 0,7 s, come sul PC: passare da una sezione
      // all'altra non deve fare un lampo.
      _s.opAurora = _avvicina(_s.opAurora, _auroraVoluta, dt / .7);
      _s.opCielo = _avvicina(_s.opCielo, _cieloVoluto, dt / .7);
      if (_corsa < 1) {
        _corsa = math.min(1, _corsa + dt / 1.1);
        _s.posa = _da!.verso(widget.posa, _morbido(_corsa));
      }
    }

    // A riposo la costellazione va a 30 fotogrammi al secondo e l'aurora a
    // 10: gli aloni si spostano di un pixel al secondo, e ridisegnarli più
    // spesso consumerebbe batteria per un movimento che l'occhio non vede.
    _dalDisegno += dt;
    final ogni = transito
        ? 0.0
        : widget.tipo == Sfondo.costellazione
            ? 1 / 30
            : 1 / 10;
    if (_dalDisegno >= ogni) {
      _dalDisegno = 0;
      _s.ridisegna();
    }
    if (!transito && widget.tipo == Sfondo.tinta) _ticker.stop();
  }

  static double _avvicina(double da, double a, double passo) =>
      da < a ? math.min(a, da + passo) : math.max(a, da - passo);

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        // Il confine fra lo sfondo e il resto: senza, ogni fotogramma della
        // costellazione ridipingerebbe anche le schede che le stanno sopra.
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _Pittore(_s, context.cFondo, context.cristallo),
            size: Size.infinite,
            isComplex: true,
            willChange: true,
          ),
        ),
      ),
    );
  }
}

class _Punto {
  _Punto(this.x, this.y, this.z, this.f, {this.polvere = false});
  final double x, y, z, f;
  final bool polvere;
  Color col = const Color(0x00000000);
  double sx = 0, sy = 0, d = 0;
}

/// Lo stato della scena, fuori dai widget: il pittore lo ascolta, e un
/// fotogramma nuovo ridipinge solo lui, senza ricostruire niente.
class _Scena extends ChangeNotifier {
  _Scena(int seme) {
    _semina(seme);
  }

  double t = 24;
  double opAurora = 1, opCielo = 1;
  PosaCielo posa = posaSblocco;

  final punti = <_Punto>[];
  late final List<_Punto> ordinati;

  /// Le coppie di vicini, in fila: i, j, i, j...
  final coppie = <int>[];

  Color? _n1, _n2, _p;

  void ridisegna() => notifyListeners();

  void _semina(int seme) {
    // Lo stesso generatore del PC: la nuvola è la stessa a ogni avvio, e non
    // dipende da Random (che fra Android e browser darebbe due cieli diversi).
    // Il prodotto resta sotto 2^53, quindi è esatto anche nel browser.
    var s = seme * 7919 + 13;
    double rnd() {
      s = (s * 16807) % 2147483647;
      return (s - 1) / 2147483646;
    }

    const n = 120;
    final oro = math.pi * (3 - math.sqrt(5));
    for (var i = 0; i < n; i++) {
      final y = 1 - (i / (n - 1)) * 2;
      final r = math.sqrt(1 - y * y);
      final th = oro * i;
      final k = .84 + rnd() * .18;
      final px = math.cos(th) * r * k + (rnd() - .5) * .07;
      final py = y * k + (rnd() - .5) * .07;
      final pz = math.sin(th) * r * k + (rnd() - .5) * .07;
      punti.add(_Punto(px, py, pz, rnd()));
    }
    for (var i = 0; i < (n * .18).round(); i++) {
      final a = rnd() * 6.283;
      final b = math.acos(2 * rnd() - 1);
      final k = 1.2 + rnd() * .7;
      punti.add(_Punto(
        math.sin(b) * math.cos(a) * k * 1.3,
        math.cos(b) * k * .8,
        math.sin(b) * math.sin(a) * k,
        rnd(),
        polvere: true,
      ));
    }
    ordinati = [...punti];

    // Circa quattro vicini per punto: la distanza media fra punti su una
    // sfera di raggio ~0,93 è 3,3/sqrt(n). Con meno fili è un cielo stellato
    // qualunque, con di più una ragnatela.
    final soglia = math.min(.5, 4 / math.sqrt(n));
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        final a = punti[i], b = punti[j];
        final dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
        if (math.sqrt(dx * dx + dy * dy + dz * dz) < soglia) {
          coppie
            ..add(i)
            ..add(j);
        }
      }
    }
  }

  /// Ogni punto ha la sua tinta fra i due neon, secondo dove sta: una nuvola
  /// tutta bianca si legge come stelle, non come una rete di voci.
  void colora(Cristallo k) {
    if (k.neon1 == _n1 && k.neon2 == _n2 && k.punto == _p) return;
    _n1 = k.neon1;
    _n2 = k.neon2;
    _p = k.punto;
    for (final q in punti) {
      final t = ((q.x * .7 - q.y * .5 + 1) / 2).clamp(0.0, 1.0);
      q.col = Color.lerp(Color.lerp(k.neon1, k.neon2, t), k.punto, .4)!;
    }
  }
}

class _Pittore extends CustomPainter {
  _Pittore(this.s, this.fondo, this.k) : super(repaint: s);

  final _Scena s;
  final Color fondo;
  final Cristallo k;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    if (w <= 0 || h <= 0) return;
    canvas.drawRect(Offset.zero & size, Paint()..color = fondo);

    final a = s.opAurora;
    if (a > .001) {
      // Il fondo sfumato: più chiaro in alto, come una luce che non si vede.
      _ellisse(canvas, size, Offset(w / 2, 0), 1.2 * w, .9 * h,
          [k.abisso.withValues(alpha: a), fondo.withValues(alpha: a)], [0, .7]);
      _aloni(canvas, w, h, a);
    }
    final c = s.opCielo * s.posa.intensita;
    if (c > .001) _cielo(canvas, w, h, c);
    _ellisse(canvas, size, Offset(w / 2, .4 * h), 1.3 * w, h,
        [k.vignetta.withValues(alpha: 0), k.vignetta], [.55, 1]);
  }

  /// Un'ellisse sfumata grande quanto lo schermo: `ui.Gradient.radial` è un
  /// cerchio, quindi si schiaccia la tela invece del gradiente.
  void _ellisse(Canvas canvas, Size size, Offset centro, double rx, double ry,
      List<Color> colori, List<double> fermate) {
    canvas.save();
    canvas.translate(centro.dx, centro.dy);
    canvas.scale(rx, ry);
    canvas.drawRect(
      Rect.fromLTRB(-centro.dx / rx, -centro.dy / ry,
          (size.width - centro.dx) / rx, (size.height - centro.dy) / ry),
      Paint()..shader = ui.Gradient.radial(Offset.zero, 1, colori, fermate),
    );
    canvas.restore();
  }

  /// I tre aloni dell'aurora. Sul PC derivano in 70, 90 e 80 secondi andando
  /// avanti e indietro; qui uguale, ma ricollocati per uno schermo verticale:
  /// con le posizioni del PC due su tre sarebbero finiti sopra lo schermo.
  void _aloni(Canvas canvas, double w, double h, double a) {
    final r = .62 * math.min(w, h);
    void alone(Color col, double cx, double cy, double dx, double dy,
        double scala, double periodo) {
      final p = (s.t / periodo) % 2;
      final e = _morbido(p < 1 ? p : 2 - p);
      final c = Offset(cx * w + dx * r * e, cy * h + dy * r * e);
      final rr = r * (1 + (scala - 1) * e);
      canvas.drawCircle(
        c,
        rr,
        Paint()
          ..shader = ui.Gradient.radial(c, rr, [
            col.withValues(alpha: col.a * a),
            col.withValues(alpha: 0),
          ]),
      );
    }

    alone(k.alone1, .12, .10, .30, .20, 1.15, 70);
    alone(k.alone2, .95, .45, -.25, .28, .9, 90);
    alone(k.alone3, .40, .98, -.20, -.25, 1.2, 80);
  }

  void _cielo(Canvas canvas, double w, double h, double intensita) {
    s.colora(k);
    final posa = s.posa;
    final t = s.t;
    final an = t / 150 * 2 * math.pi, b = .36 + .07 * math.sin(t / 41);
    final ca = math.cos(an), sa = math.sin(an);
    final cb = math.cos(b), sb = math.sin(b);
    final raggio = posa.raggio * math.min(w, h) * 1.15;
    final cx = posa.cx * w, cy = posa.cy * h;
    const prospettiva = 3.4;
    for (final q in s.punti) {
      final x1 = q.x * ca + q.z * sa;
      final z1 = -q.x * sa + q.z * ca;
      final y2 = q.y * cb - z1 * sb;
      final z2 = q.y * sb + z1 * cb;
      final scala = prospettiva / (prospettiva - z2);
      q.sx = cx + x1 * scala * raggio;
      q.sy = cy + y2 * scala * raggio;
      q.d = ((z2 + 1.2) / 2.4).clamp(0.0, 1.0);
    }

    // Fili più sottili che sul PC (0,5 invece di 0,7): qui un pixel logico
    // sono tre pixel veri, e a 0,7 la rete pesava più delle schede.
    final filo = Paint()..strokeWidth = .5;
    for (var i = 0; i < s.coppie.length; i += 2) {
      final p = s.punti[s.coppie[i]], q = s.punti[s.coppie[i + 1]];
      final al = ((.04 + .22 * math.min(p.d, q.d)) * intensita).clamp(0.0, 1.0);
      filo.color = p.col.withValues(alpha: al);
      canvas.drawLine(Offset(p.sx, p.sy), Offset(q.sx, q.sy), filo);
    }

    // Dal più lontano al più vicino, così quelli davanti coprono gli altri.
    s.ordinati.sort((p, q) => p.d.compareTo(q.d));
    final pieno = Paint();
    for (final q in s.ordinati) {
      final r = (q.polvere ? .5 : .8) + 1.6 * q.d;
      final al = (((q.polvere ? .10 : .18) + .52 * q.d) *
              intensita *
              (.82 + .18 * math.sin(t * .7 + q.f * 30)))
          .clamp(0.0, 1.0);
      final col = q.polvere ? k.punto : q.col;
      final o = Offset(q.sx, q.sy);
      // I punti davanti hanno un alone: è quello che li fa sembrare luce.
      if (q.d > .66 && !q.polvere) {
        pieno.color = col.withValues(alpha: al * .14);
        canvas.drawCircle(o, r * 3.4, pieno);
      }
      pieno.color = col.withValues(alpha: al);
      canvas.drawCircle(o, r, pieno);
    }
  }

  @override
  bool shouldRepaint(_Pittore vecchio) =>
      vecchio.fondo != fondo || vecchio.k != k || vecchio.s != s;
}

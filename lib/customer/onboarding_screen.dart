import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'location_flow_screen.dart';

/// AquaDirect onboarding: one screen that explains the marketplace.
///
/// Motion (all one-shot, nothing loops):
///  - Intro: the art layers and the copy slide up in a staggered sequence,
///    each layer at its own speed, which reads as depth.
///  - Parallax: touching or dragging shifts the layers by different amounts
///    and they ease back when released. Mouse hover works the same on desktop.
///  - Outro: tapping the button slides the copy down and the art up and away
///    before the location step opens.
///
/// The art is drawn in code, so no image assets are required. To use your own
/// illustration instead of the map, pass [heroImageAsset].
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, this.heroImageAsset});

  /// Optional PNG/JPG shown instead of the built-in map illustration.
  final String? heroImageAsset;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin {
  static const Color navy = Color(0xFF10294B);
  static const Color blue = Color(0xFF2478F2);
  static const Color muted = Color(0xFF718096);
  static const Color hairline = Color(0xFFDCE9F8);

  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );
  late final AnimationController _outro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 560),
  );
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  /// Normalised pointer position, -1..1 on both axes. Drives the parallax.
  final ValueNotifier<Offset> _tilt = ValueNotifier(Offset.zero);
  Offset _settleFrom = Offset.zero;
  bool _introStarted = false;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _settle.addListener(() {
      _tilt.value = Offset.lerp(
        _settleFrom,
        Offset.zero,
        Curves.easeOutCubic.transform(_settle.value),
      )!;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_introStarted) return;
    _introStarted = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _intro.value = 1;
    } else {
      _intro.forward();
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    _outro.dispose();
    _settle.dispose();
    _tilt.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ parallax

  void _onPointer(Offset position, Size size) {
    if (_leaving || MediaQuery.disableAnimationsOf(context)) return;
    _settle.stop();
    final target = Offset(
      (((position.dx / size.width) - .5) * 2).clamp(-1.0, 1.0),
      (((position.dy / size.height) - .5) * 2).clamp(-1.0, 1.0),
    );
    _tilt.value = Offset.lerp(_tilt.value, target, .35)!;
  }

  void _release() {
    _settleFrom = _tilt.value;
    _settle
      ..reset()
      ..forward();
  }

  // ------------------------------------------------------------ navigation

  Future<void> _start() async {
    if (_leaving) return;
    final reduce = MediaQuery.disableAnimationsOf(context);
    setState(() => _leaving = true);
    if (!reduce) await _outro.forward();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        transitionDuration: reduce
            ? Duration.zero
            : const Duration(milliseconds: 360),
        pageBuilder: (_, _, _) => const LocationFlowScreen(browsingOnly: true),
        transitionsBuilder: (_, animation, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        ),
      ),
    );
  }

  // ------------------------------------------------------------ motion math

  /// Eased 0..1 progress of [t] between [begin] and [end].
  double _seg(
    double t,
    double begin,
    double end, [
    Curve curve = Curves.easeOutCubic,
  ]) => curve.transform(((t - begin) / (end - begin)).clamp(0.0, 1.0));

  /// One parallax layer: slides up while fading in, shifts with the pointer by
  /// [depth], and lifts away on exit by [lift] (deeper layers move more).
  Widget _layer({
    required double depth,
    required double begin,
    required double end,
    required double rise,
    required double lift,
    required Widget child,
    double pop = 0,
  }) {
    final enter = _seg(_intro.value, begin, end);
    final leave = _seg(_outro.value, 0, 1, Curves.easeInCubic);
    final tilt = _tilt.value;
    final dy = (1 - enter) * rise - leave * lift + tilt.dy * depth * 9;
    final dx = tilt.dx * depth * 14;
    Widget moved = Transform.translate(offset: Offset(dx, dy), child: child);
    if (pop > 0) {
      moved = Transform.scale(
        scale: (1 - pop) + pop * enter,
        alignment: Alignment.bottomCenter,
        child: moved,
      );
    }
    return Opacity(
      opacity: (enter * (1 - leave)).clamp(0.0, 1.0),
      child: moved,
    );
  }

  /// One line of copy: slides up in sequence, slides down on exit.
  Widget _reveal(int index, Widget child) {
    final enter = _seg(_intro.value, .32 + index * .055, .72 + index * .055);
    final leave = _seg(
      _outro.value,
      index * .05,
      .75 + index * .05,
      Curves.easeInCubic,
    );
    return Opacity(
      opacity: (enter * (1 - leave)).clamp(0.0, 1.0),
      child: Transform.translate(
        offset: Offset(0, (1 - enter) * 28 + leave * 36),
        child: child,
      ),
    );
  }

  Widget _revealRight(int index, Widget child) {
    final enter = _seg(_intro.value, .32 + index * .16, .67 + index * .16);
    final leave = _seg(
      _outro.value,
      index * .05,
      .75 + index * .05,
      Curves.easeInCubic,
    );
    return Opacity(
      opacity: (enter * (1 - leave)).clamp(0.0, 1.0),
      child: Transform.translate(
        offset: Offset((1 - enter) * -28 - leave * 24, 0),
        child: child,
      ),
    );
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final compact = size.height < 740;
    final contentEstimate = compact ? 300.0 : 332.0;
    final plateTop = padding.top + 62;
    final plateHeight = (size.height - plateTop - contentEstimate - 64).clamp(
      190.0,
      390.0,
    );

    return Scaffold(
      backgroundColor: Colors.white,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (details) => _onPointer(details.localPosition, size),
        onPanUpdate: (details) => _onPointer(details.localPosition, size),
        onPanEnd: (_) => _release(),
        onPanCancel: _release,
        child: MouseRegion(
          onHover: (event) => _onPointer(event.localPosition, size),
          onExit: (_) => _release(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xFFE8F2FF),
                      Color(0xFFF6FAFF),
                      Colors.white,
                    ],
                    stops: [0, .45, .74],
                  ),
                ),
              ),
              AnimatedBuilder(
                animation: Listenable.merge([_intro, _outro, _tilt]),
                builder: (context, _) => Stack(
                  fit: StackFit.expand,
                  children: [
                    ExcludeSemantics(
                      child: _buildArt(size, plateTop, plateHeight),
                    ),
                    _buildTopBar(padding.top),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _buildContent(padding.bottom, compact),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(double topInset) => Positioned(
    top: 0,
    left: 0,
    right: 0,
    child: Opacity(
      opacity: (_seg(_intro.value, .04, .4) * (1 - _outro.value)).clamp(
        0.0,
        1.0,
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, topInset + 18, 24, 0),
        child: RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: 'Aqua',
                style: GoogleFonts.plusJakartaSans(
                  color: navy,
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.5,
                ),
              ),
              TextSpan(
                text: 'Direct',
                style: GoogleFonts.manrope(
                  color: blue,
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.4,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  // ------------------------------------------------------------ art

  Widget _buildArt(Size size, double plateTop, double plateHeight) {
    final hero = widget.heroImageAsset;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Far layer: soft halo behind everything.
        _layer(
          depth: .3,
          begin: 0,
          end: .45,
          rise: 0,
          lift: 24,
          child: const CustomPaint(painter: _HaloPainter()),
        ),
        // Mid layer: the map.
        Positioned(
          left: 24,
          right: 24,
          top: plateTop,
          height: plateHeight,
          child: _layer(
            depth: .8,
            begin: .08,
            end: .6,
            rise: 46,
            lift: 70,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(30),
                boxShadow: [
                  BoxShadow(
                    color: navy.withValues(alpha: .10),
                    blurRadius: 36,
                    offset: const Offset(0, 18),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(30),
                child: hero != null
                    ? Image.asset(
                        hero,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const CustomPaint(
                          painter: _MapPainter(),
                          size: Size.infinite,
                        ),
                      )
                    : const CustomPaint(
                        painter: _MapPainter(),
                        size: Size.infinite,
                      ),
              ),
            ),
          ),
        ),
        // Near layer: station pins and the "you are here" marker.
        if (hero == null)
          Positioned(
            left: 24,
            right: 24,
            top: plateTop,
            height: plateHeight,
            child: Stack(
              children: [
                _pin(const Alignment(-.55, -.42), '0.8 km', 0),
                _pin(const Alignment(.58, -.5), '1.2 km', 1),
                _pin(const Alignment(.52, .5), '2.1 km', 2),
                Align(
                  alignment: const Alignment(0, .12),
                  child: _layer(
                    depth: 1.1,
                    begin: .3,
                    end: .62,
                    rise: 24,
                    lift: 80,
                    pop: .5,
                    child: const _YouAreHere(),
                  ),
                ),
              ],
            ),
          ),
        // Front layer: a station card overlapping the map's lower edge.
        Positioned(
          left: 46,
          right: 46,
          top: plateTop + plateHeight - 34,
          child: _layer(
            depth: 1.7,
            begin: .45,
            end: .85,
            rise: 64,
            lift: 110,
            child: const _StationPreviewCard(),
          ),
        ),
      ],
    );
  }

  Widget _pin(Alignment alignment, String label, int index) => Align(
    alignment: alignment,
    child: _layer(
      depth: 1.3,
      begin: .26 + index * .07,
      end: .6 + index * .07,
      rise: 34,
      lift: 90,
      pop: .45,
      child: _StationPin(label: label),
    ),
  );

  // ------------------------------------------------------------ content

  Widget _buildContent(double bottomInset, bool compact) {
    final titleSize = compact ? 29.0 : 33.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        (bottomInset > 0 ? bottomInset : 16) + 12,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _revealRight(
            0,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Find water stations',
                  style: GoogleFonts.manrope(
                    color: navy,
                    fontSize: titleSize,
                    height: 1.1,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1.1,
                  ),
                ),
                Text(
                  'near you.',
                  style: GoogleFonts.manrope(
                    color: blue,
                    fontSize: titleSize,
                    height: 1.1,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1.1,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: compact ? 10 : 14),
          _revealRight(
            1,
            Text(
              'Compare nearby refilling stations, order a refill or a new gallon, and pay on delivery.',
              style: GoogleFonts.manrope(
                color: muted,
                fontSize: compact ? 13 : 14,
                height: 1.55,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          SizedBox(height: compact ? 14 : 18),
          _reveal(
            3,
            const Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _FeatureChip(
                  icon: Icons.verified_rounded,
                  label: 'Verified stations',
                ),
                _FeatureChip(
                  icon: Icons.water_drop_rounded,
                  label: 'Refill or new gallon',
                ),
                _FeatureChip(
                  icon: Icons.payments_rounded,
                  label: 'Pay on delivery',
                ),
              ],
            ),
          ),
          SizedBox(height: compact ? 18 : 24),
          _reveal(4, _StartButton(onPressed: _leaving ? null : _start)),
          const SizedBox(height: 14),
          _reveal(
            5,
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.lock_outline_rounded,
                    size: 14,
                    color: muted,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Your location is only used to find nearby stations.',
                    style: GoogleFonts.manrope(
                      color: muted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// BUTTON + CHIP
// ============================================================

class _StartButton extends StatefulWidget {
  const _StartButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  State<_StartButton> createState() => _StartButtonState();
}

class _StartButtonState extends State<_StartButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Find stations near me',
    child: AnimatedScale(
      scale: _pressed ? .975 : 1,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: _OnboardingScreenState.blue.withValues(alpha: .28),
              blurRadius: 22,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Material(
          color: _OnboardingScreenState.blue,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            onTap: widget.onPressed,
            onHighlightChanged: (value) => setState(() => _pressed = value),
            borderRadius: BorderRadius.circular(18),
            child: SizedBox(
              height: 56,
              width: double.infinity,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Find stations near me',
                    style: GoogleFonts.manrope(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.arrow_forward_rounded,
                    color: Colors.white,
                    size: 19,
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

class _FeatureChip extends StatelessWidget {
  const _FeatureChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: _OnboardingScreenState.hairline),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: _OnboardingScreenState.blue),
        const SizedBox(width: 6),
        Text(
          label,
          style: GoogleFonts.manrope(
            color: _OnboardingScreenState.navy,
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

// ============================================================
// ART
// ============================================================

class _HaloPainter extends CustomPainter {
  const _HaloPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * .5, size.height * .26);
    final radius = size.width * .78;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            _OnboardingScreenState.blue.withValues(alpha: .13),
            _OnboardingScreenState.blue.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
    final dot = Paint()
      ..color = _OnboardingScreenState.blue.withValues(alpha: .18);
    canvas.drawCircle(Offset(size.width * .1, size.height * .2), 4, dot);
    canvas.drawCircle(Offset(size.width * .9, size.height * .3), 6, dot);
    canvas.drawCircle(Offset(size.width * .82, size.height * .1), 3, dot);
  }

  @override
  bool shouldRepaint(covariant _HaloPainter oldDelegate) => false;
}

/// A calm, abstract map: blocks, roads, a river and distance rings.
class _MapPainter extends CustomPainter {
  const _MapPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFEAF3FF),
    );

    final block = Paint()..color = const Color(0xFFDCEAFA);
    const blocks = [
      [.06, .08, .2, .18],
      [.38, .06, .2, .14],
      [.78, .1, .16, .22],
      [.06, .56, .22, .2],
      [.7, .6, .22, .22],
      [.4, .7, .2, .14],
    ];
    for (final b in blocks) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(w * b[0], h * b[1], w * b[2], h * b[3]),
          const Radius.circular(12),
        ),
        block,
      );
    }

    canvas.drawPath(
      Path()
        ..moveTo(-12, h * .82)
        ..cubicTo(w * .24, h * .62, w * .5, h * .98, w * 1.05, h * .7),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 20
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFFCBE3FA),
    );

    final road = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 9
      ..color = Colors.white;
    canvas.drawLine(Offset(-6, h * .4), Offset(w + 6, h * .36), road);
    canvas.drawLine(Offset(w * .3, -6), Offset(w * .34, h + 6), road);
    canvas.drawLine(Offset(w * .68, -6), Offset(w * .64, h + 6), road);
    canvas.drawLine(
      Offset(w * .05, h * .95),
      Offset(w * .95, h * .1),
      road..strokeWidth = 6,
    );

    // Distance rings around the "you are here" point.
    final center = Offset(w * .5, h * .56);
    for (final ring in const [(.36, .10), (.25, .14), (.14, .2)]) {
      canvas.drawCircle(
        center,
        w * ring.$1,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = _OnboardingScreenState.blue.withValues(alpha: ring.$2),
      );
    }
    canvas.drawCircle(
      center,
      w * .14,
      Paint()..color = _OnboardingScreenState.blue.withValues(alpha: .06),
    );
  }

  @override
  bool shouldRepaint(covariant _MapPainter oldDelegate) => false;
}

class _YouAreHere extends StatelessWidget {
  const _YouAreHere();

  @override
  Widget build(BuildContext context) => Container(
    width: 22,
    height: 22,
    decoration: BoxDecoration(
      color: _OnboardingScreenState.blue,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 3.5),
      boxShadow: [
        BoxShadow(
          color: _OnboardingScreenState.blue.withValues(alpha: .4),
          blurRadius: 14,
        ),
      ],
    ),
  );
}

class _StationPin extends StatelessWidget {
  const _StationPin({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: _OnboardingScreenState.navy.withValues(alpha: .12),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Text(
          label,
          style: GoogleFonts.manrope(
            color: _OnboardingScreenState.navy,
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      const SizedBox(height: 3),
      SizedBox(
        width: 46,
        height: 52,
        child: Stack(
          alignment: Alignment.topCenter,
          children: [
            Icon(
              Icons.location_on_rounded,
              size: 52,
              color: _OnboardingScreenState.blue,
              shadows: [
                Shadow(
                  color: _OnboardingScreenState.blue.withValues(alpha: .35),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            const Positioned(
              top: 11,
              child: Icon(
                Icons.water_drop_rounded,
                size: 17,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

/// An illustration of what the customer will see, not real data.
class _StationPreviewCard extends StatelessWidget {
  const _StationPreviewCard();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: _OnboardingScreenState.hairline),
      boxShadow: [
        BoxShadow(
          color: _OnboardingScreenState.navy.withValues(alpha: .12),
          blurRadius: 28,
          offset: const Offset(0, 14),
        ),
      ],
    ),
    child: Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: const Color(0xFFEAF5FF),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Icon(
            Icons.storefront_rounded,
            color: _OnboardingScreenState.blue,
            size: 22,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Nearest station',
                style: GoogleFonts.manrope(
                  color: _OnboardingScreenState.navy,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      color: Color(0xFF16A37F),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Open now · 0.8 km',
                    style: GoogleFonts.manrope(
                      color: _OnboardingScreenState.muted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Icon(
          Icons.chevron_right_rounded,
          color: _OnboardingScreenState.muted,
          size: 22,
        ),
      ],
    ),
  );
}

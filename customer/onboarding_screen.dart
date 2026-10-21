import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'location_flow_screen.dart';

/// AquaDirect onboarding: one screen that explains the marketplace.
///
/// Motion is slide-only and one-shot. Nothing loops, nothing follows the
/// finger, and no controller is created anywhere in this file. Every piece
/// uses an implicit animation (TweenAnimationBuilder): it is told where it
/// starts and how long to wait, and it slides into place by itself.
///
///  - Intro: the logo drops down, the map rises, the station pins slide in
///    from the left, right and top, the headline and text slide in from the
///    left, the chips slide in from the right one by one, and the button and
///    note rise last. Each piece has its own delay, so it reads as a sequence.
///  - Outro: tapping the button slides everything back out the way it came,
///    bottom items first, before the location step opens.
///
/// Respects the system "reduce motion" setting: everything is shown in place
/// and the screen changes without any movement.
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

// ------------------------------------------------------------------ timing

/// How long one piece takes to slide out. Each piece may add its own delay.
const Duration _exitDuration = Duration(milliseconds: 460);

/// The longest exit delay used below, so navigation waits for the last piece.
const Duration _longestExitDelay = Duration(milliseconds: 160);

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const Color navy = Color(0xFF10294B);
  static const Color blue = Color(0xFF2478F2);
  static const Color muted = Color(0xFF718096);
  static const Color hairline = Color(0xFFDCE9F8);

  bool _leaving = false;

  // ------------------------------------------------------------ navigation

  Future<void> _start() async {
    if (_leaving) return;
    final reduce = MediaQuery.disableAnimationsOf(context);
    setState(() => _leaving = true);
    // The exit plays by itself once _leaving flips. Wait for the slowest piece
    // to finish, plus a couple of frames, before the next screen takes over.
    if (!reduce) {
      await Future<void>.delayed(
        _exitDuration + _longestExitDelay + const Duration(milliseconds: 40),
      );
    }
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

  /// Shorthand for one slide: where it starts, how long it waits, how long it
  /// takes, and how long it waits before leaving.
  Widget _slide({
    required Offset from,
    required int delay,
    required Widget child,
    int ms = 700,
    int exitDelay = 0,
  }) => _Slide(
    leaving: _leaving,
    from: from,
    delay: Duration(milliseconds: delay),
    duration: Duration(milliseconds: ms),
    exitDelay: Duration(milliseconds: exitDelay),
    child: child,
  );

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
      body: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFE8F2FF), Color(0xFFF6FAFF), Colors.white],
                stops: [0, .45, .74],
              ),
            ),
          ),
          ExcludeSemantics(child: _buildArt(plateTop, plateHeight)),
          _buildTopBar(padding.top),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildContent(padding.bottom, compact),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(double topInset) => Positioned(
    top: 0,
    left: 0,
    right: 0,
    child: _slide(
      from: const Offset(0, -18),
      delay: 0,
      ms: 600,
      exitDelay: 120,
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

  Widget _buildArt(double plateTop, double plateHeight) {
    final hero = widget.heroImageAsset;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Soft halo behind everything: fades in without moving.
        _slide(
          from: Offset.zero,
          delay: 0,
          ms: 900,
          exitDelay: 120,
          child: const CustomPaint(painter: _HaloPainter()),
        ),
        // The map rises from below.
        Positioned(
          left: 24,
          right: 24,
          top: plateTop,
          height: plateHeight,
          child: _slide(
            from: const Offset(0, 56),
            delay: 120,
            ms: 850,
            exitDelay: 80,
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
        // Station pins and the "you are here" dot: each slides in from a
        // different side, one after another.
        if (hero == null)
          Positioned(
            left: 24,
            right: 24,
            top: plateTop,
            height: plateHeight,
            child: Stack(
              children: [
                Align(
                  alignment: const Alignment(-.55, -.42),
                  child: _slide(
                    from: const Offset(-44, 0),
                    delay: 520,
                    ms: 700,
                    exitDelay: 40,
                    child: const _StationPin(label: '0.8 km'),
                  ),
                ),
                Align(
                  alignment: const Alignment(.58, -.5),
                  child: _slide(
                    from: const Offset(44, 0),
                    delay: 640,
                    ms: 700,
                    exitDelay: 40,
                    child: const _StationPin(label: '1.2 km'),
                  ),
                ),
                Align(
                  alignment: const Alignment(.52, .5),
                  child: _slide(
                    from: const Offset(0, -40),
                    delay: 760,
                    ms: 700,
                    exitDelay: 40,
                    child: const _StationPin(label: '2.1 km'),
                  ),
                ),
                Align(
                  alignment: const Alignment(0, .12),
                  child: _slide(
                    from: const Offset(0, 18),
                    delay: 560,
                    ms: 600,
                    exitDelay: 40,
                    child: const _YouAreHere(),
                  ),
                ),
              ],
            ),
          ),
        // A station card overlapping the map's lower edge rises last.
        Positioned(
          left: 46,
          right: 46,
          top: plateTop + plateHeight - 34,
          child: _slide(
            from: const Offset(0, 72),
            delay: 800,
            ms: 800,
            child: const _StationPreviewCard(),
          ),
        ),
      ],
    );
  }

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
          // Headline and text slide in from the left.
          _slide(
            from: const Offset(-36, 0),
            delay: 380,
            exitDelay: 80,
            child: Column(
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
          _slide(
            from: const Offset(-36, 0),
            delay: 520,
            exitDelay: 60,
            child: Text(
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
          // Chips slide in from the right, one by one.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _slide(
                from: const Offset(40, 0),
                delay: 700,
                ms: 600,
                exitDelay: 40,
                child: const _FeatureChip(
                  icon: Icons.verified_rounded,
                  label: 'Verified stations',
                ),
              ),
              _slide(
                from: const Offset(40, 0),
                delay: 790,
                ms: 600,
                exitDelay: 20,
                child: const _FeatureChip(
                  icon: Icons.water_drop_rounded,
                  label: 'Refill or new gallon',
                ),
              ),
              _slide(
                from: const Offset(40, 0),
                delay: 880,
                ms: 600,
                child: const _FeatureChip(
                  icon: Icons.payments_rounded,
                  label: 'Pay on delivery',
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 18 : 24),
          // Button and note rise from the bottom last.
          _slide(
            from: const Offset(0, 44),
            delay: 1000,
            child: _StartButton(onPressed: _leaving ? null : _start),
          ),
          const SizedBox(height: 14),
          _slide(
            from: const Offset(0, 24),
            delay: 1140,
            ms: 600,
            child: Center(
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
// MOTION
// ============================================================

/// One slide with no controller to manage.
///
/// On first build the child waits [delay], then slides from [from] to its
/// place while fading in. When [leaving] becomes true it waits [exitDelay]
/// and slides back toward [from] while fading out.
///
/// The child is cached on its own layer, so while it moves it is only
/// shifted, never repainted. That is what keeps the motion smooth.
class _Slide extends StatelessWidget {
  const _Slide({
    required this.leaving,
    required this.from,
    required this.delay,
    required this.duration,
    required this.exitDelay,
    required this.child,
  });

  final bool leaving;
  final Offset from;
  final Duration delay;
  final Duration duration;
  final Duration exitDelay;
  final Widget child;

  /// The delay is the first part of the animation, where nothing moves yet.
  static Curve _after(Duration wait, Duration total, Curve curve) => Interval(
    wait.inMilliseconds / total.inMilliseconds,
    1,
    curve: curve,
  );

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    final enterTotal = delay + duration;
    final exitTotal = _exitDuration + exitDelay;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: reduce ? 1.0 : 0.0, end: 1.0),
      duration: reduce ? Duration.zero : enterTotal,
      curve: _after(delay, enterTotal, Curves.easeOutCubic),
      child: RepaintBoundary(child: child),
      builder: (context, appear, cached) => TweenAnimationBuilder<double>(
        tween: Tween<double>(end: leaving ? 1.0 : 0.0),
        duration: reduce ? Duration.zero : exitTotal,
        curve: _after(exitDelay, exitTotal, Curves.easeInCubic),
        child: cached,
        builder: (context, vanish, cached) => Opacity(
          opacity: (appear * (1 - vanish)).clamp(0.0, 1.0),
          child: Transform.translate(
            offset: from * ((1 - appear) + vanish),
            child: cached,
          ),
        ),
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
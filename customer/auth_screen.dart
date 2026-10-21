import 'dart:async';

import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, AuthException, AuthState, OAuthProvider;

import '../config/app_colors.dart';
import '../config/supabase_config.dart';
import '../services/location_service.dart';
import '../services/supabase_service.dart';
import 'main_wrapper_screen.dart';

// Your original header colors. One gradient sits behind the whole screen so
// the sheet's rounded corners match it exactly.
const _heroTop = Color(0xFF2860E8);
const _heroBottom = Color(0xFF1743B5);
const _ink = Color(0xFF14233B);
//const _muted = Color(0xFF68758A);

final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');
const _minPasswordLength = 6;

/// Login and sign-up flow backed by Supabase Auth.
///
/// Both modes live on one screen: the header and form swap in place, so
/// switching feels continuous instead of pushing a new page.
class LoginScreen extends StatefulWidget {
  /// Opens directly on the sign-up form.
  final bool startOnSignup;
  final DeliveryLocation? initialBrowsingLocation;

  /// Called with "Terms of Service" or "Privacy Policy" when a link is tapped.
  /// When null, a short "coming soon" message is shown instead.
  final ValueChanged<String>? onOpenTerms;
  const LoginScreen({
    super.key,
    this.startOnSignup = false,
    this.initialBrowsingLocation,
    this.onOpenTerms,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

/// Kept for backwards compatibility with any existing `SignupScreen()` calls.
class SignupScreen extends StatelessWidget {
  const SignupScreen({super.key});

  @override
  Widget build(BuildContext context) => const LoginScreen(startOnSignup: true);
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  static const _switchDuration = Duration(milliseconds: 380);

  final _scrollController = ScrollController();
  final _loginKey = GlobalKey<FormState>();
  final _signupKey = GlobalKey<FormState>();

  // Login
  final _loginEmail = TextEditingController();
  final _loginPassword = TextEditingController();
  bool _obscureLoginPassword = true;
  bool _rememberMe = true;

  // Sign up
  final _name = TextEditingController();
  final _mobile = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  bool _agreedToTerms = false;
  bool _termsError = false;

  bool _authInProgress = false;
  bool _oauthFlowPending = false;
  String? _formError;
  late bool _isLogin = !widget.startOnSignup;
  StreamSubscription<AuthState>? _authSubscription;

  /// Drives the staggered entrance (header, sheet, then the fields).
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..forward();

  @override
  void dispose() {
    unawaited(_authSubscription?.cancel());
    _intro.dispose();
    _scrollController.dispose();
    _loginEmail.dispose();
    _loginPassword.dispose();
    _name.dispose();
    _mobile.dispose();
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    if (SupabaseConfig.isInitialized) {
      _authSubscription = SupabaseConfig.client.auth.onAuthStateChange.listen(
        _handleAuthState,
        onError: (Object error) {
          if (!mounted || !_oauthFlowPending) return;
          setState(() {
            _oauthFlowPending = false;
            _authInProgress = false;
            _formError = _friendlyError(error);
          });
        },
      );
    }
  }

  void _handleAuthState(AuthState state) {
    if (state.event != AuthChangeEvent.signedIn ||
        state.session == null ||
        !_oauthFlowPending) {
      return;
    }
    _oauthFlowPending = false;
    if (!mounted) return;
    setState(() {
      _authInProgress = false;
      _formError = null;
    });
    _openCustomerHome();
  }

  // ------------------------------------------------------------------ helpers

  /// Fades and lifts [child] into place during the [begin]-[end] slice of the
  /// intro. After the intro finishes it is a no-op.
  Widget _reveal(double begin, double end, Widget child, {double dy = 18}) {
    final curve = Interval(begin, end, curve: Curves.easeOutCubic);
    return AnimatedBuilder(
      animation: _intro,
      child: child,
      builder: (context, child) {
        final v = curve.transform(_intro.value);
        return Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(0, (1 - v) * dy),
            child: child,
          ),
        );
      },
    );
  }

  void _switchMode({required bool toLogin}) {
    if (_isLogin == toLogin) return;
    FocusScope.of(context).unfocus();
    HapticFeedback.selectionClick();
    setState(() {
      _isLogin = toLogin;
      _formError = null;
      _termsError = false;
    });
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: _switchDuration,
        curve: Curves.easeInOutCubic,
      );
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _signInWithProvider(
    OAuthProvider provider,
    String providerName,
  ) async {
    FocusScope.of(context).unfocus();
    if (_authInProgress) return;
    setState(() {
      _authInProgress = true;
      _formError = null;
    });

    try {
      final started = await SupabaseService.signInWithOAuth(
        provider: provider,
        redirectTo: kIsWeb ? null : 'aquadirect://login-callback/',
      );
      if (!started) {
        throw Exception('$providerName sign-in could not be started.');
      }
      _oauthFlowPending = true;
    } on Exception catch (exception) {
      if (!mounted) return;
      setState(() => _formError = _friendlyError(exception));
    } finally {
      if (mounted) setState(() => _authInProgress = false);
    }
  }

  void _openLegal(String document) {
    if (widget.onOpenTerms != null) {
      widget.onOpenTerms!(document);
    } else {
      _toast('$document will be available soon.');
    }
  }

  void _openCustomerHome() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => MainWrapperScreen(
          initialBrowsingLocation: widget.initialBrowsingLocation,
        ),
      ),
    );
  }

  String _friendlyError(Object error) {
    if (!SupabaseConfig.isInitialized) {
      return SupabaseConfig.initializationError ??
          'Supabase is not configured. Check the root .env file.';
    }
    final raw = error is AuthException
        ? error.message
        : error.toString().replaceFirst('Exception: ', '');
    final lower = raw.toLowerCase();
    if (lower.contains('invalid login')) return 'Incorrect email or password.';
    if (lower.contains('already registered') ||
        lower.contains('already been registered')) {
      return 'An account with this email already exists. Try logging in.';
    }
    if (lower.contains('email not confirmed')) {
      return 'Please confirm your email first. Check your inbox.';
    }
    if (lower.contains('socket') ||
        lower.contains('network') ||
        lower.contains('failed host')) {
      return 'No connection. Check your internet and try again.';
    }
    return raw;
  }

  // ------------------------------------------------------------------ actions

  Future<void> _login() async {
    FocusScope.of(context).unfocus();
    _oauthFlowPending = false;
    setState(() => _formError = null);
    if (!(_loginKey.currentState?.validate() ?? false)) return;
    if (_authInProgress) return;
    setState(() => _authInProgress = true);
    try {
      final response = await SupabaseService.signIn(
        identity: _loginEmail.text.trim(),
        password: _loginPassword.text,
      );
      if (!mounted) return;
      if (response.session == null) {
        setState(
          () => _formError =
              'Login did not create an active session. Please try again.',
        );
        return;
      }
      _openCustomerHome();
    } on Exception catch (exception) {
      if (!mounted) return;
      setState(() => _formError = _friendlyError(exception));
    } finally {
      if (mounted) setState(() => _authInProgress = false);
    }
  }

  Future<void> _signup() async {
    FocusScope.of(context).unfocus();
    _oauthFlowPending = false;
    setState(() => _formError = null);
    if (!(_signupKey.currentState?.validate() ?? false)) return;
    if (!_agreedToTerms) {
      setState(() {
        _termsError = true;
        _formError =
            'Please agree to the Terms of Service and Privacy Policy to continue.';
      });
      return;
    }
    if (_authInProgress) return;
    setState(() => _authInProgress = true);
    try {
      final response = await SupabaseService.signUp(
        fullName: _name.text.trim(),
        phone: _mobile.text.trim(),
        email: _email.text.trim(),
        password: _password.text,
      );
      if (!mounted) return;
      if (response.session == null) {
        _loginEmail.text = _email.text.trim();
        _switchMode(toLogin: true);
        _toast('Account created. Check your email to confirm it, then log in.');
        return;
      }
      _openCustomerHome();
    } on Exception catch (exception) {
      if (!mounted) return;
      setState(() => _formError = _friendlyError(exception));
    } finally {
      if (mounted) setState(() => _authInProgress = false);
    }
  }

  Future<void> _forgotPassword() async {
    final email = _loginEmail.text.trim();
    if (!_emailPattern.hasMatch(email)) {
      setState(
        () =>
            _formError = 'Enter your email above, then tap “Forgot password?”.',
      );
      return;
    }
    setState(() => _formError = null);
    try {
      await SupabaseService.client.auth.resetPasswordForEmail(email);
      if (mounted) {
        _toast('If $email has an account, a reset link is on its way.');
      }
    } on Exception catch (exception) {
      if (mounted) setState(() => _formError = _friendlyError(exception));
    }
  }

  // -------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: PopScope(
        // System back on the sign-up form returns to login instead of exiting.
        canPop: _isLogin,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _switchMode(toLogin: true);
        },
        child: Scaffold(
          backgroundColor: _heroBottom,
          body: Stack(
            children: [
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [_heroTop, _heroBottom],
                    ),
                  ),
                ),
              ),
              CustomScrollView(
                controller: _scrollController,
                physics: const ClampingScrollPhysics(),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: [
                  SliverToBoxAdapter(child: _buildHeader(context)),
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _slideUp(
                      _buildSheet(media.padding.bottom),
                      media.size.height,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Slides [child] up from below the bottom edge of the screen.
  Widget _slideUp(Widget child, double distance) {
    const curve = Interval(.04, .72, curve: Cubic(0.22, 1.0, 0.36, 1.0));
    return AnimatedBuilder(
      animation: _intro,
      child: child,
      builder: (context, child) {
        final v = curve.transform(_intro.value);
        return Transform.translate(
          offset: Offset(0, (1 - v) * distance),
          child: child,
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;

    return SizedBox(
      width: double.infinity,
      child: Stack(
        // Not clipped, so the soft circles flow behind the sheet's corners.
        clipBehavior: Clip.none,
        children: [
          Positioned(
            right: -70,
            top: -50,
            child: _Ripple(size: 230, alpha: .07),
          ),
          Positioned(
            right: 24,
            top: top + 56,
            child: _Ripple(size: 92, alpha: .08),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(28, top + 56, 28, 34),
            child: _reveal(
              .1,
              .55,
              Align(
                alignment: Alignment.centerLeft,
                child: AnimatedSize(
                  duration: _switchDuration,
                  curve: Curves.easeInOutCubic,
                  alignment: Alignment.topLeft,
                  child: AnimatedSwitcher(
                    duration: _switchDuration,
                    transitionBuilder: (child, animation) =>
                        FadeTransition(opacity: animation, child: child),
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.topLeft,
                      children: [...previous, ?current],
                    ),
                    child: Column(
                      key: ValueKey('header-$_isLogin'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _isLogin ? 'Welcome back' : 'Create account',
                          style: GoogleFonts.manrope(
                            color: Colors.white,
                            fontSize: 31,
                            height: 1.15,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -.9,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _isLogin
                              ? 'Log in to order clean water in minutes.'
                              : 'Join AquaDirect for convenient water delivery.',
                          style: GoogleFonts.manrope(
                            color: Colors.white.withValues(alpha: .85),
                            fontSize: 14,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSheet(double bottomInset) => Container(
    width: double.infinity,
    decoration: const BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
    ),
    padding: EdgeInsets.fromLTRB(24, 30, 24, 34 + bottomInset),
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: AnimatedSize(
          duration: _switchDuration,
          curve: Curves.easeInOutCubic,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: _switchDuration,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween(
                  begin: const Offset(0, .03),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: _isLogin ? _buildLoginForm() : _buildSignupForm(),
          ),
        ),
      ),
    ),
  );

  // -------------------------------------------------------------------- login

  Widget _buildLoginForm() {
    return Form(
      key: _loginKey,
      child: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _reveal(
              .42,
              .85,
              _field(
                'Email',
                SimpleAuthField(
                  controller: _loginEmail,
                  hint: 'you@example.com',
                  icon: Icons.mail_outline_rounded,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.email],
                  validator: _validateEmail,
                ),
              ),
            ),
            const SizedBox(height: 18),
            _reveal(
              .5,
              .92,
              _field(
                'Password',
                SimpleAuthField(
                  controller: _loginPassword,
                  hint: 'Enter your password',
                  icon: Icons.lock_outline_rounded,
                  obscureText: _obscureLoginPassword,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.password],
                  onSubmitted: (_) => _login(),
                  validator: (value) => value == null || value.isEmpty
                      ? 'Enter your password'
                      : null,
                  suffix: _VisibilityButton(
                    obscured: _obscureLoginPassword,
                    onPressed: () => setState(
                      () => _obscureLoginPassword = !_obscureLoginPassword,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            _reveal(
              .56,
              .96,
              Row(
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => setState(() => _rememberMe = !_rememberMe),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 21,
                            height: 21,
                            child: Checkbox(
                              value: _rememberMe,
                              activeColor: primaryBlue,
                              side: const BorderSide(color: Color(0xFFB8BEC8)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(5),
                              ),
                              onChanged: (value) =>
                                  setState(() => _rememberMe = value ?? false),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Remember me',
                            style: GoogleFonts.manrope(
                              color: const Color(0xFF424B59),
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _authInProgress ? null : _forgotPassword,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      'Forgot password?',
                      style: GoogleFonts.manrope(
                        color: primaryBlue,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _FormError(message: _formError),
            const SizedBox(height: 14),
            _reveal(
              .62,
              1,
              _PrimaryButton(
                label: 'Log in',
                loadingLabel: 'Logging in...',
                onPressed: _login,
                isLoading: _authInProgress,
              ),
            ),
            const SizedBox(height: 26),
            _reveal(.68, 1, const AuthDivider()),
            const SizedBox(height: 18),
            _reveal(
              .72,
              1,
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SocialButton(
                    assetPath: 'assets/images/google.png',
                    label: 'Google',
                    fallbackIcon: Icons.g_mobiledata_rounded,
                    onTap: () =>
                        _signInWithProvider(OAuthProvider.google, 'Google'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            _reveal(
              .78,
              1,
              _SwitchPrompt(
                question: "Don't have an account? ",
                action: 'Sign up',
                onTap: () => _switchMode(toLogin: false),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------- signup

  Widget _buildSignupForm() {
    return Form(
      key: _signupKey,
      child: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _field(
              'Full name',
              SimpleAuthField(
                controller: _name,
                hint: 'Enter your full name',
                icon: Icons.person_outline_rounded,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.name],
                validator: (value) => value == null || value.trim().length < 2
                    ? 'Enter your full name'
                    : null,
              ),
            ),
            const SizedBox(height: 16),
            _field(
              'Mobile number',
              SimpleAuthField(
                controller: _mobile,
                hint: 'e.g. 09XX XXX XXXX',
                icon: Icons.phone_iphone_rounded,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.telephoneNumber],
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9+\s-]')),
                ],
                validator: (value) {
                  final digits = (value ?? '').replaceAll(RegExp(r'\D'), '');
                  if (digits.isEmpty) return 'Enter your mobile number';
                  return digits.length < 7
                      ? 'Enter a valid mobile number'
                      : null;
                },
              ),
            ),
            const SizedBox(height: 16),
            _field(
              'Email',
              SimpleAuthField(
                controller: _email,
                hint: 'you@example.com',
                icon: Icons.mail_outline_rounded,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.email],
                validator: _validateEmail,
              ),
            ),
            const SizedBox(height: 16),
            _field(
              'Password',
              SimpleAuthField(
                controller: _password,
                hint: 'Create a password',
                icon: Icons.lock_outline_rounded,
                obscureText: _obscurePassword,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.newPassword],
                onChanged: (_) => setState(() {}),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Create a password';
                  }
                  if (value.length < _minPasswordLength) {
                    return 'Use at least $_minPasswordLength characters';
                  }
                  return null;
                },
                suffix: _VisibilityButton(
                  obscured: _obscurePassword,
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
            ),
            const SizedBox(height: 9),
            _PasswordRule(
              text: 'At least $_minPasswordLength characters',
              met: _password.text.length >= _minPasswordLength,
              started: _password.text.isNotEmpty,
            ),
            const SizedBox(height: 14),
            _field(
              'Confirm password',
              SimpleAuthField(
                controller: _confirm,
                hint: 'Re-enter your password',
                icon: Icons.lock_reset_rounded,
                obscureText: _obscureConfirm,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.newPassword],
                onSubmitted: (_) => _signup(),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Confirm your password';
                  }
                  return value != _password.text
                      ? 'Passwords do not match'
                      : null;
                },
                suffix: _VisibilityButton(
                  obscured: _obscureConfirm,
                  onPressed: () =>
                      setState(() => _obscureConfirm = !_obscureConfirm),
                ),
              ),
            ),
            const SizedBox(height: 18),
            _TermsCheckbox(
              value: _agreedToTerms,
              hasError: _termsError,
              onChanged: (value) => setState(() {
                _agreedToTerms = value;
                if (value && _termsError) {
                  _termsError = false;
                  _formError = null;
                }
              }),
              onOpen: _openLegal,
            ),
            _FormError(message: _formError),
            const SizedBox(height: 22),
            _PrimaryButton(
              label: 'Create account',
              loadingLabel: 'Creating account...',
              onPressed: _signup,
              isLoading: _authInProgress,
            ),
            const SizedBox(height: 24),
            _SwitchPrompt(
              question: 'Already have an account? ',
              action: 'Log in',
              onTap: () => _switchMode(toLogin: true),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(String label, Widget field) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [SimpleAuthLabel(label), const SizedBox(height: 8), field],
  );

  static String? _validateEmail(String? value) {
    final email = value?.trim() ?? '';
    if (email.isEmpty) return 'Enter your email';
    return _emailPattern.hasMatch(email) ? null : 'Enter a valid email address';
  }
}

// ------------------------------------------------------------ shared widgets

class _Ripple extends StatelessWidget {
  const _Ripple({required this.size, required this.alpha});

  final double size;
  final double alpha;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: alpha),
      ),
    ),
  );
}

/// "I agree to the Terms of Service and Privacy Policy" row with tappable
/// links. Tapping the rest of the sentence toggles the checkbox.
class _TermsCheckbox extends StatefulWidget {
  const _TermsCheckbox({
    required this.value,
    required this.hasError,
    required this.onChanged,
    required this.onOpen,
  });

  final bool value;
  final bool hasError;
  final ValueChanged<bool> onChanged;
  final ValueChanged<String> onOpen;

  @override
  State<_TermsCheckbox> createState() => _TermsCheckboxState();
}

class _TermsCheckboxState extends State<_TermsCheckbox> {
  late final TapGestureRecognizer _terms = TapGestureRecognizer()
    ..onTap = () => widget.onOpen('Terms of Service');
  late final TapGestureRecognizer _privacy = TapGestureRecognizer()
    ..onTap = () => widget.onOpen('Privacy Policy');

  @override
  void dispose() {
    _terms.dispose();
    _privacy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = GoogleFonts.manrope(
      color: const Color(0xFF424B59),
      fontSize: 12.5,
      height: 1.45,
      fontWeight: FontWeight.w600,
    );
    final link = base.copyWith(color: primaryBlue, fontWeight: FontWeight.w800);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: SizedBox(
            width: 21,
            height: 21,
            child: Checkbox(
              value: widget.value,
              activeColor: primaryBlue,
              side: BorderSide(
                color: widget.hasError
                    ? const Color(0xFFDC2626)
                    : const Color(0xFFB8BEC8),
                width: widget.hasError ? 1.6 : 1,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(5),
              ),
              onChanged: (value) => widget.onChanged(value ?? false),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onChanged(!widget.value),
            child: Text.rich(
              TextSpan(
                style: base,
                children: [
                  const TextSpan(text: 'I agree to the '),
                  TextSpan(
                    text: 'Terms of Service',
                    style: link,
                    recognizer: _terms,
                  ),
                  const TextSpan(text: ' and '),
                  TextSpan(
                    text: 'Privacy Policy',
                    style: link,
                    recognizer: _privacy,
                  ),
                  const TextSpan(text: '.'),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _VisibilityButton extends StatelessWidget {
  const _VisibilityButton({required this.obscured, required this.onPressed});

  final bool obscured;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: obscured ? 'Show password' : 'Hide password',
    onPressed: onPressed,
    icon: Icon(
      obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
      color: const Color(0xFF7C8491),
      size: 20,
    ),
  );
}

/// Live hint under the password field: grey until typing starts, then red
/// until the rule is met, then green.
class _PasswordRule extends StatelessWidget {
  const _PasswordRule({
    required this.text,
    required this.met,
    required this.started,
  });

  final String text;
  final bool met;
  final bool started;

  @override
  Widget build(BuildContext context) {
    final color = met
        ? const Color(0xFF16A34A)
        : (started ? const Color(0xFFDC2626) : const Color(0xFF8A94A6));
    return AnimatedDefaultTextStyle(
      duration: const Duration(milliseconds: 200),
      style: GoogleFonts.manrope(
        color: color,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      child: Row(
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Icon(
              met ? Icons.check_circle_rounded : Icons.circle_outlined,
              key: ValueKey(met),
              size: 15,
              color: color,
            ),
          ),
          const SizedBox(width: 7),
          Text(text),
        ],
      ),
    );
  }
}

/// Inline error shown above the primary button. Animates in and out.
class _FormError extends StatelessWidget {
  const _FormError({required this.message});

  final String? message;

  @override
  Widget build(BuildContext context) => AnimatedSize(
    duration: const Duration(milliseconds: 220),
    curve: Curves.easeOut,
    alignment: Alignment.topCenter,
    child: message == null
        ? const SizedBox(width: double.infinity)
        : Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF2F2),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: const Color(0xFFFECACA)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    color: Color(0xFFDC2626),
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      message!,
                      style: GoogleFonts.manrope(
                        color: const Color(0xFF991B1B),
                        fontSize: 12.5,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
  );
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final String loadingLabel;
  final VoidCallback onPressed;
  final bool isLoading;
  const _PrimaryButton({
    required this.label,
    required this.loadingLabel,
    required this.onPressed,
    required this.isLoading,
  });

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(15),
      boxShadow: [
        BoxShadow(
          color: primaryBlue.withValues(alpha: .28),
          blurRadius: 18,
          offset: const Offset(0, 8),
        ),
      ],
    ),
    child: SizedBox(
      height: 54,
      child: ElevatedButton(
        onPressed: isLoading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryBlue,
          foregroundColor: Colors.white,
          disabledBackgroundColor: primaryBlue,
          disabledForegroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: isLoading
              ? Row(
                  key: const ValueKey('loading'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      loadingLabel,
                      style: GoogleFonts.manrope(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                )
              : Text(
                  label,
                  key: const ValueKey('label'),
                  style: GoogleFonts.manrope(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
        ),
      ),
    ),
  );
}

class _SwitchPrompt extends StatelessWidget {
  final String question;
  final String action;
  final VoidCallback onTap;
  const _SwitchPrompt({
    required this.question,
    required this.action,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Center(
    child: Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          question,
          style: GoogleFonts.manrope(
            color: const Color(0xFF777E88),
            fontSize: 13,
          ),
        ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              action,
              style: GoogleFonts.manrope(
                color: primaryBlue,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class SimpleAuthLabel extends StatelessWidget {
  final String text;
  const SimpleAuthLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Text(
      text,
      style: GoogleFonts.manrope(
        color: _ink,
        fontSize: 13,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

class SimpleAuthField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool obscureText;
  final Widget? suffix;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final List<TextInputFormatter>? inputFormatters;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  const SimpleAuthField({
    super.key,
    required this.controller,
    required this.hint,
    required this.icon,
    this.obscureText = false,
    this.suffix,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.textInputAction,
    this.autofillHints,
    this.inputFormatters,
    this.validator,
    this.onChanged,
    this.onSubmitted,
  });

  OutlineInputBorder _border(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: color, width: width),
      );

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textCapitalization: textCapitalization,
      textInputAction: textInputAction,
      autofillHints: autofillHints,
      inputFormatters: inputFormatters,
      validator: validator,
      onChanged: onChanged,
      onFieldSubmitted: onSubmitted,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      cursorColor: primaryBlue,
      style: GoogleFonts.manrope(
        color: _ink,
        fontSize: 14.5,
        fontWeight: FontWeight.w600,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.manrope(
          color: const Color(0xFFA0A7B2),
          fontSize: 13.5,
          fontWeight: FontWeight.w500,
        ),
        errorStyle: GoogleFonts.manrope(
          color: const Color(0xFFDC2626),
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
        ),
        prefixIcon: Icon(icon, color: const Color(0xFF7C8491), size: 20),
        suffixIcon: suffix,
        filled: true,
        fillColor: const Color(0xFFF6F8FC),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 15,
          vertical: 16,
        ),
        border: _border(const Color(0xFFE1E7EF)),
        enabledBorder: _border(const Color(0xFFE1E7EF)),
        focusedBorder: _border(primaryBlue, 1.6),
        errorBorder: _border(const Color(0xFFF1A5A5)),
        focusedErrorBorder: _border(const Color(0xFFDC2626), 1.6),
      ),
    );
  }
}

/// Wide, labelled sign-in button for a social provider.
class SocialButton extends StatelessWidget {
  final String assetPath;
  final String label;
  final IconData fallbackIcon;
  final VoidCallback onTap;

  const SocialButton({
    super.key,
    required this.assetPath,
    required this.label,
    required this.fallbackIcon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Continue with $label',
    child: Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          height: 52,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE1E7EF)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset(
                assetPath,
                width: 21,
                height: 21,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) =>
                    Icon(fallbackIcon, size: 24, color: _ink),
              ),
              const SizedBox(width: 10),
              Text(
                'Continue with $label',
                style: GoogleFonts.manrope(
                  color: _ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Round logo-only button, kept for any other screen that still uses it.
class SocialLogoButton extends StatelessWidget {
  final String assetPath;
  final String semanticLabel;
  final VoidCallback onTap;

  const SocialLogoButton({
    super.key,
    required this.assetPath,
    required this.semanticLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: semanticLabel,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(13),
        child: Ink(
          width: 56,
          height: 50,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: const Color(0xFFE1E5EA)),
          ),
          child: Center(
            child: Image.asset(
              assetPath,
              width: 22,
              height: 22,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Icon(
                Icons.image_outlined,
                size: 20,
                color: Colors.grey,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class AuthDivider extends StatelessWidget {
  const AuthDivider({super.key});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Expanded(child: Divider(color: Color(0xFFE8ECF2))),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Text(
          'or',
          style: GoogleFonts.manrope(
            color: const Color(0xFF858C97),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      const Expanded(child: Divider(color: Color(0xFFE8ECF2))),
    ],
  );
}

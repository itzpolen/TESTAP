import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'config/app_colors.dart';
import 'config/supabase_config.dart';
import 'services/supabase_service.dart';
//import 'customer/onboarding_screen.dart';
import 'customer/auth_screen.dart';
import 'customer/main_wrapper_screen.dart';
import 'customer/splash_screen.dart';
//import 'admin/admin_dashboard_screen.dart';

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;
  String? _lastHandledLink;
  DateTime? _lastLinkHandledAt;

  @override
  void initState() {
    super.initState();
    _appLinks = AppLinks();
    _linkSubscription = _appLinks.uriLinkStream.listen(
      _handlePaymentReturn,
      onError: (Object error) {
        debugPrint('AquaDirect deep link error: $error');
      },
    );
    unawaited(_handleInitialLink());
  }

  Future<void> _handleInitialLink() async {
    try {
      final initialLink = await _appLinks.getInitialLink();
      if (initialLink != null) _handlePaymentReturn(initialLink);
    } on Exception catch (error) {
      debugPrint('Could not read the initial AquaDirect link: $error');
    }
  }

  void _handlePaymentReturn(Uri uri) {
    if (uri.scheme != 'aquadirect' ||
        uri.host != 'payment-return' ||
        uri.path != '/home') {
      return;
    }
    final link = uri.toString();
    final now = DateTime.now();
    if (_lastHandledLink == link &&
        _lastLinkHandledAt != null &&
        now.difference(_lastLinkHandledAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastHandledLink = link;
    _lastLinkHandledAt = now;

    void openHome() {
      _navigatorKey.currentState?.pushNamedAndRemoveUntil(
        '/home',
        (_) => false,
      );
    }

    if (_navigatorKey.currentState == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => openHome());
    } else {
      openHome();
    }
    final orderId = uri.queryParameters['order_id'];
    if (orderId != null && orderId.isNotEmpty) {
      unawaited(_reconcileReturnedPayment(orderId));
    }
  }

  Future<void> _reconcileReturnedPayment(String orderId) async {
    final currentContext = _navigatorKey.currentContext;
    final messenger = currentContext == null
        ? null
        : ScaffoldMessenger.maybeOf(currentContext);
    try {
      await SupabaseService.reconcileOrderPayment(orderId);
      final result = await SupabaseService.getOrderPaymentResult(orderId);
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            result.paid
                ? 'Payment confirmed. The station has been notified.'
                : 'Payment is still processing. Your order will update when confirmed.',
          ),
        ),
      );
    } on Exception catch (error) {
      debugPrint('Could not verify returned PayMongo payment: $error');
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not verify payment yet: $error')),
      );
    }
  }

  @override
  void dispose() {
    unawaited(_linkSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'AquaDirect',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: paleBlue,
        textTheme: GoogleFonts.manropeTextTheme(),
        colorScheme: ColorScheme.fromSeed(seedColor: primaryBlue),
      ),
      routes: {'/home': (_) => const _DeepLinkHome()},
      home: const SplashScreen(),
      //home: const
    );
  }
}

class _DeepLinkHome extends StatelessWidget {
  const _DeepLinkHome();

  @override
  Widget build(BuildContext context) {
    final hasSession =
        SupabaseConfig.isInitialized &&
        SupabaseConfig.client.auth.currentSession != null;
    return hasSession ? const MainWrapperScreen() : const LoginScreen();
  }
}

typedef AquaDirectApp = MyApp;

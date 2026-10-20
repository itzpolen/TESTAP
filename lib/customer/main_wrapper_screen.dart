import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_colors.dart';
import '../services/location_service.dart';
import '../services/supabase_service.dart';
import 'home_screen.dart';
import 'orders_screen.dart';
import 'profile_screen.dart';
import 'station_screen.dart';
import 'tracking_screen.dart';

class MainWrapperScreen extends StatefulWidget {
  final DeliveryLocation? initialBrowsingLocation;

  const MainWrapperScreen({super.key, this.initialBrowsingLocation});

  @override
  State<MainWrapperScreen> createState() => _MainWrapperScreenState();
}

class _MainWrapperScreenState extends State<MainWrapperScreen>
    with WidgetsBindingObserver {
  static const _homeIndex = 0;
  // static const _ordersIndex = 2;
  static const _trackIndex = 3;

  int index = _homeIndex;
  int _cartItemCount = 0;
  int _activeOrderCount = 0;
  late DeliveryLocation? _browsingLocation = widget.initialBrowsingLocation;

  /// Tabs are built the first time they are opened, then kept alive. This
  /// avoids loading Stations, Orders, Track and Profile (and their network
  /// calls) before the customer ever visits them.
  final Set<int> _visited = {_homeIndex};

  RealtimeChannel? _ordersChannel;
  Timer? _ordersDebounce;

  /// Built once so Google Fonts isn't re-resolved on every rebuild.
  TextTheme? _manropeTheme;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshCartCount());
    unawaited(_refreshActiveOrders());
    _listenForOrderChanges();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ordersDebounce?.cancel();
    final channel = _ordersChannel;
    if (channel != null) {
      unawaited(SupabaseService.client.removeChannel(channel));
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from the PayMongo browser, the cart and order badges may
    // have changed while the app was in the background.
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshCartCount());
      unawaited(_refreshActiveOrders());
    }
  }

  void _listenForOrderChanges() {
    final customerId = SupabaseService.client.auth.currentUser?.id;
    if (customerId == null) return;
    _ordersChannel = SupabaseService.client
        .channel('main-wrapper-orders-$customerId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'orders',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'customer_id',
            value: customerId,
          ),
          callback: (_) {
            _ordersDebounce?.cancel();
            _ordersDebounce = Timer(
              const Duration(milliseconds: 400),
              () => unawaited(_refreshActiveOrders()),
            );
          },
        )
        .subscribe();
  }

  /// Badges are a convenience, so failures are silent instead of showing a
  /// snackbar on every tab.
  Future<void> _refreshCartCount() async {
    try {
      final cart = await SupabaseService.getActiveCart();
      if (!mounted) return;
      final count = cart?.itemCount ?? 0;
      if (count != _cartItemCount) setState(() => _cartItemCount = count);
    } on Exception {
      // Keep the last known count.
    }
  }

  Future<void> _refreshActiveOrders() async {
    try {
      final orders = await SupabaseService.getCustomerOrders();
      if (!mounted) return;
      final count = orders.where((order) => order.isInProgress).length;
      if (count != _activeOrderCount) {
        setState(() => _activeOrderCount = count);
      }
    } on Exception {
      // Keep the last known count.
    }
  }

  void _updateBrowsingLocation(DeliveryLocation location) {
    if (_browsingLocation?.latitude == location.latitude &&
        _browsingLocation?.longitude == location.longitude) {
      return;
    }
    setState(() => _browsingLocation = location);
  }

  void _select(int value) {
    if (value == index) return;
    HapticFeedback.selectionClick();
    setState(() {
      index = value;
      _visited.add(value);
    });
  }

  Widget _buildPage(int i) => switch (i) {
    0 => HomeScreen(
      buildMainWrapper: () => const MainWrapperScreen(),
      initialBrowsingLocation: _browsingLocation,
      onBrowsingLocationChanged: _updateBrowsingLocation,
      onTrackOrder: () => _select(_trackIndex),
      cartItemCount: _cartItemCount,
      onCartChanged: _refreshCartCount,
    ),
    1 => StationScreen(
      buildMainWrapper: () => const MainWrapperScreen(),
      initialBrowsingLocation: _browsingLocation,
      onBrowsingLocationChanged: _updateBrowsingLocation,
      onCartChanged: _refreshCartCount,
    ),
    2 => OrdersScreen(onOrdersChanged: _refreshActiveOrders),
    3 => const TrackScreen(),
    _ => const ProfileScreen(),
  };

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    _manropeTheme ??= GoogleFonts.manropeTextTheme(base.textTheme);

    // Back from any tab returns to Home first, then exits the app.
    return PopScope(
      canPop: index == _homeIndex,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => index = _homeIndex);
      },
      child: Theme(
        data: base.copyWith(textTheme: _manropeTheme),
        child: Scaffold(
          body: IndexedStack(
            index: index,
            children: [
              for (var i = 0; i < 5; i++)
                _visited.contains(i) ? _buildPage(i) : const SizedBox.shrink(),
            ],
          ),
          bottomNavigationBar: BottomNav(
            currentIndex: index,
            onChanged: _select,
            trackBadgeCount: _activeOrderCount,
          ),
        ),
      ),
    );
  }
}

class BottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onChanged;

  /// Number of in-progress orders. Shown as a badge on the Track tab.
  final int trackBadgeCount;

  const BottomNav({
    super.key,
    required this.currentIndex,
    required this.onChanged,
    this.trackBadgeCount = 0,
  });

  static const _trackTab = 3;

  static const _items = <_NavItem>[
    _NavItem('Home', Icons.home_outlined, Icons.home_rounded),
    _NavItem('Stations', Icons.storefront_outlined, Icons.storefront_rounded),
    _NavItem('Orders', Icons.receipt_long_outlined, Icons.receipt_long_rounded),
    _NavItem(
      'Track',
      Icons.local_shipping_outlined,
      Icons.local_shipping_rounded,
    ),
    _NavItem('Profile', Icons.person_outline_rounded, Icons.person_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        border: const Border(top: BorderSide(color: Color(0xFFEEF1F5))),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0A2A5C).withValues(alpha: .06),
            blurRadius: 18,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: NavigationBarTheme(
        data: NavigationBarThemeData(
          height: 68,
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          indicatorColor: lightBlue,
          indicatorShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => TextStyle(
              fontSize: 11,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w800
                  : FontWeight.w600,
              color: states.contains(WidgetState.selected)
                  ? primaryBlue
                  : textGray,
            ),
          ),
          iconTheme: WidgetStateProperty.resolveWith(
            (states) => IconThemeData(
              size: 24,
              color: states.contains(WidgetState.selected)
                  ? primaryBlue
                  : textGray,
            ),
          ),
        ),
        child: NavigationBar(
          selectedIndex: currentIndex,
          onDestinationSelected: onChanged,
          elevation: 0,
          destinations: [
            for (var i = 0; i < _items.length; i++)
              NavigationDestination(
                label: _items[i].label,
                tooltip: '',
                icon: _icon(_items[i].icon, i),
                selectedIcon: _icon(_items[i].selectedIcon, i),
              ),
          ],
        ),
      ),
    );
  }

  Widget _icon(IconData data, int i) {
    final icon = Icon(data);
    if (i != _trackTab || trackBadgeCount <= 0) return icon;
    return Badge(
      label: Text(trackBadgeCount > 9 ? '9+' : '$trackBadgeCount'),
      backgroundColor: danger,
      textColor: Colors.white,
      child: icon,
    );
  }
}

class _NavItem {
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  const _NavItem(this.label, this.icon, this.selectedIcon);
}

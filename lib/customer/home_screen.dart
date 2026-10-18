import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/app_colors.dart';
import '../models/nearby_station.dart';
import '../services/location_service.dart';
import '../services/nearby_empty_states.dart';
import '../services/supabase_service.dart';
import '../widgets/custom_button.dart';
import 'cart_checkout_screen.dart';
import 'location_flow_screen.dart';
import 'station_screen.dart';

// ============================================================
// DESIGN TOKENS
// ============================================================

const _pageBackground = Color(0xFFF5F8FC);
const _headerStart = Color(0xFF0A2F6B);
const _headerDark = Color(0xFF0563C1);
const _navy = Color(0xFF0A2A5C);
const _aqua = Color(0xFF1FB5C9);
const _mint = Color(0xFF16A37F);
const _hairline = Color(0xFFE6EEF7);

const _pagePadding = 20.0;
const _cardRadius = 22.0;

/// Short, quiet motion in the style of iOS: ease-out curves, no loops.
/// Everything respects the system "remove animations" setting.
const _fast = Duration(milliseconds: 200);
const _medium = Duration(milliseconds: 320);

bool _reduceMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context);

TextStyle _t(
  double size, {
  FontWeight w = FontWeight.w600,
  Color c = textDark,
  double? h,
  double? ls,
}) => GoogleFonts.manrope(
  fontSize: size,
  fontWeight: w,
  color: c,
  height: h,
  letterSpacing: ls,
);

enum _StationSort { nearest, topRated, lowestPrice }

extension on _StationSort {
  String get label => switch (this) {
    _StationSort.nearest => 'Nearest',
    _StationSort.topRated => 'Top rated',
    _StationSort.lowestPrice => 'Lowest price',
  };

  IconData get icon => switch (this) {
    _StationSort.nearest => Icons.near_me_rounded,
    _StationSort.topRated => Icons.star_rounded,
    _StationSort.lowestPrice => Icons.sell_rounded,
  };
}

String _greeting() {
  final hour = DateTime.now().hour;
  if (hour < 12) return 'Good morning';
  if (hour < 18) return 'Good afternoon';
  return 'Good evening';
}

// ============================================================
// HOME SCREEN
// ============================================================

class HomeScreen extends StatefulWidget {
  final Widget Function() buildMainWrapper;
  final DeliveryLocation? initialBrowsingLocation;
  final ValueChanged<DeliveryLocation>? onBrowsingLocationChanged;

  /// Number shown on the cart badge. Wire this to your cart state later.
  final int cartItemCount;
  final VoidCallback? onCartChanged;

  /// Short status text for an in-progress order, e.g. "Out for delivery".
  /// When non-null a tappable banner is shown under the header.
  final String? activeOrderLabel;
  final VoidCallback? onTrackOrder;

  const HomeScreen({
    super.key,
    required this.buildMainWrapper,
    this.initialBrowsingLocation,
    this.onBrowsingLocationChanged,
    this.cartItemCount = 0,
    this.onCartChanged,
    this.activeOrderLabel,
    this.onTrackOrder,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// Scroll distance after which the compact top bar takes over.
  static const _compactFrom = 96.0;

  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  final _scrollController = ScrollController();
  final _scrollOffset = ValueNotifier<double>(0);
  final _stationsKey = GlobalKey();

  /// Stations that already played their entrance animation, so scrolling
  /// back up does not replay it.
  final _revealed = <String>{};

  late DeliveryLocation? _browsingLocation = widget.initialBrowsingLocation;
  List<NearbyStation> _stations = const [];
  bool _loadingStations = false;
  bool _openNowOnly = false;
  bool _compactBar = false;
  _StationSort _sort = _StationSort.nearest;
  String? _loadError;
  double _searchRadiusKm = NearbyConfig.defaultRadiusKm;
  int _requestNumber = 0;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_searchChanged);
    _scrollController.addListener(_onScroll);
    _initializeBrowsingLocation();
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final updatedLocation = widget.initialBrowsingLocation;
    if (updatedLocation != null &&
        (updatedLocation.latitude != _browsingLocation?.latitude ||
            updatedLocation.longitude != _browsingLocation?.longitude)) {
      _browsingLocation = updatedLocation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadNearbyStations());
      });
    }
  }

  @override
  void dispose() {
    _requestNumber++;
    _searchController
      ..removeListener(_searchChanged)
      ..dispose();
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _scrollOffset.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _searchChanged() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    final offset = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    _scrollOffset.value = offset;
    final compact = offset > _compactFrom + 24;
    if (compact != _compactBar) setState(() => _compactBar = compact);
  }

  // ---------------------------------------------------------- location

  Future<void> _initializeBrowsingLocation() async {
    final initialLocation = _browsingLocation;
    if (initialLocation == null) {
      try {
        final savedLocation =
            await SupabaseService.getCustomerBrowsingLocation();
        if (!mounted) return;
        if (savedLocation != null && _browsingLocation == null) {
          setState(() => _browsingLocation = savedLocation);
          widget.onBrowsingLocationChanged?.call(savedLocation);
        }
      } on Exception catch (exception) {
        if (mounted) {
          _showLocationMessage(
            'Could not load your browsing location: $exception',
          );
        }
      }
    } else {
      try {
        await SupabaseService.saveCustomerBrowsingLocation(initialLocation);
      } on Exception catch (exception) {
        if (mounted) {
          _showLocationMessage(
            'Could not save your browsing location: $exception',
          );
        }
      }
    }
    if (!mounted) return;
    await _loadNearbyStations();
  }

  void _showLocationMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _loadNearbyStations({double? radiusKm}) async {
    final location = _browsingLocation;
    final latitude = location?.latitude;
    final longitude = location?.longitude;
    if (latitude == null || longitude == null) {
      if (!mounted) return;
      setState(() {
        _stations = const [];
        _loadingStations = false;
        _loadError = null;
        if (radiusKm != null) _searchRadiusKm = radiusKm;
      });
      return;
    }

    final request = ++_requestNumber;
    setState(() {
      _loadingStations = true;
      _loadError = null;
      if (radiusKm != null) _searchRadiusKm = radiusKm;
    });

    try {
      final stations = await SupabaseService.getNearbyStations(
        latitude: latitude,
        longitude: longitude,
        radiusKm: radiusKm ?? _searchRadiusKm,
      );
      if (!mounted || request != _requestNumber) return;
      setState(() {
        _stations = stations;
        _loadingStations = false;
      });
    } on Exception catch (exception) {
      if (!mounted || request != _requestNumber) return;
      setState(() {
        _loadingStations = false;
        _loadError = exception.toString();
      });
    }
  }

  Future<void> _chooseBrowsingLocation() async {
    final location = await Navigator.of(context).push<DeliveryLocation>(
      CupertinoPageRoute(
        builder: (flowContext) => LocationFlowScreen(
          browsingOnly: true,
          onLocationSelected: (selected) =>
              Navigator.of(flowContext).pop(selected),
          onSkip: () => Navigator.of(flowContext).pop(),
        ),
      ),
    );
    if (!mounted || location == null) return;
    setState(() => _browsingLocation = location);
    widget.onBrowsingLocationChanged?.call(location);
    try {
      await SupabaseService.saveCustomerBrowsingLocation(location);
    } on Exception catch (exception) {
      if (mounted) {
        _showLocationMessage(
          'Could not save your browsing location: $exception',
        );
      }
    }
    await _loadNearbyStations(radiusKm: NearbyConfig.defaultRadiusKm);
  }

  Future<void> _showLocationOptions() {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _LocationSheet(
        label: _locationLabel,
        location: _browsingLocation,
        onChange: () {
          Navigator.of(sheetContext).pop();
          unawaited(_chooseBrowsingLocation());
        },
      ),
    );
  }

  // ---------------------------------------------------------- actions

  Future<void> _openCart() async {
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => CartScreen(buildMainWrapper: widget.buildMainWrapper),
      ),
    );
    if (mounted) widget.onCartChanged?.call();
  }

  void _clearFilters() {
    _searchController.clear();
    setState(() => _openNowOnly = false);
  }

  void _scrollToStations() {
    final target = _stationsKey.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOutCubic,
      alignment: .1,
    );
  }

  Future<void> _focusSearch() async {
    if (_scrollController.hasClients) {
      await _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    }
    if (mounted) _searchFocus.requestFocus();
  }

  void _showStationDetails(NearbyStation station) {
    Navigator.of(context).push<void>(
      CupertinoPageRoute(
        builder: (_) => StationScreen(
          station: station,
          initialBrowsingLocation: _browsingLocation,
          onCartChanged: widget.onCartChanged,
        ),
      ),
    );
  }

  // ---------------------------------------------------------- derived

  bool get _hasCoordinates =>
      _browsingLocation?.latitude != null &&
      _browsingLocation?.longitude != null;

  /// A friendly name for the browsing location, never raw coordinates.
  String? get _locationLabel {
    if (!_hasCoordinates) return null;
    final address = _browsingLocation?.address?.trim();
    if (address != null && address.isNotEmpty && address != 'Pinned location') {
      return address;
    }
    return 'Pinned map location';
  }

  List<NearbyStation> get _visibleStations {
    final query = _searchController.text.trim().toLowerCase();
    final list = _stations.where((station) {
      if (_openNowOnly && !station.isOpen) return false;
      if (query.isEmpty) return true;
      return station.name.toLowerCase().contains(query) ||
          (station.barangay?.toLowerCase().contains(query) ?? false) ||
          (station.city?.toLowerCase().contains(query) ?? false) ||
          (station.province?.toLowerCase().contains(query) ?? false);
    }).toList();
    switch (_sort) {
      case _StationSort.nearest:
        list.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
      case _StationSort.topRated:
        list.sort(
          (a, b) => (b.ratingAverage ?? 0).compareTo(a.ratingAverage ?? 0),
        );
      case _StationSort.lowestPrice:
        list.sort((a, b) => a.startingPrice.compareTo(b.startingPrice));
    }
    return list;
  }

  // ---------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final stations = _visibleStations;
    final searching = _searchController.text.trim().isNotEmpty;
    final showList =
        _hasCoordinates &&
        !_loadingStations &&
        _loadError == null &&
        stations.isNotEmpty;
    final topInset = MediaQuery.paddingOf(context).top;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _compactBar
          ? SystemUiOverlayStyle.dark
          : SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _pageBackground,
        body: Stack(
          children: [
            RefreshIndicator(
              color: primaryBlue,
              edgeOffset: topInset + 70,
              onRefresh: () => _loadNearbyStations(),
              child: CustomScrollView(
                controller: _scrollController,
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                slivers: [
                  SliverToBoxAdapter(
                    child: _HeaderWithPromo(
                      showPromo: !searching,
                      locationLabel: _locationLabel,
                      onChangeLocation: _showLocationOptions,
                      cartItemCount: widget.cartItemCount,
                      onCart: _openCart,
                      searchController: _searchController,
                      searchFocus: _searchFocus,
                      scrollOffset: _scrollOffset,
                      onPromoTap: _scrollToStations,
                    ),
                  ),
                  if (widget.activeOrderLabel != null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          _pagePadding,
                          4,
                          _pagePadding,
                          0,
                        ),
                        child: _ActiveOrderBanner(
                          label: widget.activeOrderLabel!,
                          onTap: widget.onTrackOrder,
                        ),
                      ),
                    ),
                  SliverToBoxAdapter(
                    child: _SectionHeader(
                      key: _stationsKey,
                      title: 'Nearby stations',
                      trailing: showList
                          ? '${stations.length} found · ${_searchRadiusKm.round()} km'
                          : null,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: _FilterRow(
                      sort: _sort,
                      openNowOnly: _openNowOnly,
                      onSort: (value) {
                        HapticFeedback.selectionClick();
                        setState(() => _sort = value);
                      },
                      onToggleOpen: () {
                        HapticFeedback.selectionClick();
                        setState(() => _openNowOnly = !_openNowOnly);
                      },
                    ),
                  ),
                  if (showList)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(
                        _pagePadding,
                        4,
                        _pagePadding,
                        28,
                      ),
                      sliver: SliverList.separated(
                        itemCount: stations.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 16),
                        itemBuilder: (context, index) {
                          final station = stations[index];
                          final key = '${station.name}#${station.distanceKm}';
                          return _Reveal(
                            key: ValueKey(key),
                            play: _revealed.add(key),
                            delay: Duration(
                              milliseconds: 60 * math.min(index, 4),
                            ),
                            child: _StationCard(
                              station: station,
                              onTap: () => _showStationDetails(station),
                            ),
                          );
                        },
                      ),
                    )
                  else if (_hasCoordinates && _loadingStations)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(
                        _pagePadding,
                        4,
                        _pagePadding,
                        28,
                      ),
                      sliver: SliverList.separated(
                        itemCount: 3,
                        separatorBuilder: (_, _) => const SizedBox(height: 16),
                        itemBuilder: (_, _) => const _SkeletonCard(),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(
                        _pagePadding,
                        4,
                        _pagePadding,
                        28,
                      ),
                      sliver: SliverToBoxAdapter(child: _buildStateView()),
                    ),
                  if (showList && !searching)
                    const SliverToBoxAdapter(child: _HomeFooter()),
                ],
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _CompactBar(
                scrollOffset: _scrollOffset,
                from: _compactFrom,
                locationLabel: _locationLabel,
                onLocation: _showLocationOptions,
                onSearch: _focusSearch,
                cartItemCount: widget.cartItemCount,
                onCart: _openCart,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Everything that is not the station list or the loading skeleton.
  Widget _buildStateView() {
    if (!_hasCoordinates) {
      return NoLocationCard(onSetLocation: _chooseBrowsingLocation);
    }
    if (_loadError != null) {
      return _MarketplaceStateCard(
        child: Column(
          children: [
            const _StateIcon(icon: Icons.cloud_off_rounded, color: danger),
            const SizedBox(height: 14),
            Text(
              'Could not load nearby stations',
              style: _t(15, w: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              'Check your connection and try again.',
              textAlign: TextAlign.center,
              style: _t(12.5, w: FontWeight.w500, c: textGray),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _loadNearbyStations(),
              style: FilledButton.styleFrom(
                backgroundColor: primaryBlue,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Try again'),
            ),
          ],
        ),
      );
    }
    if (_stations.isEmpty) {
      return NoStationsNearby(
        radiusKm: _searchRadiusKm,
        onChangeLocation: _chooseBrowsingLocation,
        onExpandSearch: _searchRadiusKm < NearbyConfig.expandedRadiusKm
            ? () => _loadNearbyStations(radiusKm: NearbyConfig.expandedRadiusKm)
            : null,
      );
    }
    return _MarketplaceStateCard(
      child: Column(
        children: [
          const _StateIcon(icon: Icons.search_off_rounded, color: textGray),
          const SizedBox(height: 14),
          Text(
            _openNowOnly
                ? 'No open stations match your search'
                : 'No stations match your search',
            textAlign: TextAlign.center,
            style: _t(15, w: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            'Try a different name or area, or clear your filters.',
            textAlign: TextAlign.center,
            style: _t(12.5, w: FontWeight.w500, c: textGray, h: 1.4),
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _clearFilters,
            style: OutlinedButton.styleFrom(
              foregroundColor: primaryBlue,
              side: const BorderSide(color: primaryBlue),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: const Text('Clear filters'),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// MOTION PRIMITIVES
// ============================================================

/// Fades and lifts its child in once. Passing `play: false` shows the child
/// immediately, which is how already-seen list items avoid replaying.
class _Reveal extends StatefulWidget {
  const _Reveal({
    super.key,
    required this.child,
    this.play = true,
    this.delay = Duration.zero,
  });

  final Widget child;
  final bool play;
  final Duration delay;

  @override
  State<_Reveal> createState() => _RevealState();
}

class _RevealState extends State<_Reveal> with SingleTickerProviderStateMixin {
  static const _duration = Duration(milliseconds: 440);

  late final AnimationController _controller;
  late final CurvedAnimation _curve;

  @override
  void initState() {
    super.initState();
    final total = _duration + widget.delay;
    _controller = AnimationController(vsync: this, duration: total);
    _curve = CurvedAnimation(
      parent: _controller,
      curve: Interval(
        widget.delay.inMilliseconds / total.inMilliseconds,
        1,
        curve: Curves.easeOutCubic,
      ),
    );
    if (widget.play) {
      _controller.forward();
    } else {
      _controller.value = 1;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduceMotion(context)) _controller.value = 1;
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _curve,
    child: SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, .04),
        end: Offset.zero,
      ).animate(_curve),
      child: widget.child,
    ),
  );
}

// ============================================================
// HEADER
// ============================================================

/// Header with the promo banner overlapping its lower edge. While the
/// customer is searching, the banner collapses away smoothly.
class _HeaderWithPromo extends StatelessWidget {
  const _HeaderWithPromo({
    required this.showPromo,
    required this.locationLabel,
    required this.onChangeLocation,
    required this.cartItemCount,
    required this.onCart,
    required this.searchController,
    required this.searchFocus,
    required this.scrollOffset,
    required this.onPromoTap,
  });

  static const _promoHeight = 156.0;
  static const _overlap = 46.0;
  static const _gap = 20.0;

  final bool showPromo;
  final String? locationLabel;
  final VoidCallback onChangeLocation;
  final int cartItemCount;
  final VoidCallback onCart;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final ValueNotifier<double> scrollOffset;
  final VoidCallback onPromoTap;

  @override
  Widget build(BuildContext context) {
    final header = _HomeHeader(
      locationLabel: locationLabel,
      onChangeLocation: onChangeLocation,
      cartItemCount: cartItemCount,
      onCart: onCart,
      searchController: searchController,
      searchFocus: searchFocus,
      scrollOffset: scrollOffset,
      bottomPadding: showPromo ? _overlap + 22 : 24,
    );
    return AnimatedSize(
      duration: _medium,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: showPromo
          ? Stack(
              clipBehavior: Clip.none,
              children: [
                Column(
                  children: [
                    header,
                    const SizedBox(height: _promoHeight - _overlap + _gap),
                  ],
                ),
                Positioned(
                  left: _pagePadding,
                  right: _pagePadding,
                  bottom: _gap,
                  child: _PromoBanner(height: _promoHeight, onTap: onPromoTap),
                ),
              ],
            )
          : header,
    );
  }
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({
    required this.locationLabel,
    required this.onChangeLocation,
    required this.cartItemCount,
    required this.onCart,
    required this.searchController,
    required this.searchFocus,
    required this.scrollOffset,
    required this.bottomPadding,
  });

  final String? locationLabel;
  final VoidCallback onChangeLocation;
  final int cartItemCount;
  final VoidCallback onCart;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final ValueNotifier<double> scrollOffset;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(30)),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [_headerStart, _headerDark],
          ),
        ),
        child: Stack(
          children: [
            // One still highlight for depth. Nothing here moves.
            Positioned(
              right: -80,
              top: -90,
              child: IgnorePointer(
                child: Container(
                  width: 260,
                  height: 260,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        Colors.white.withValues(alpha: .16),
                        Colors.white.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                _pagePadding,
                top + 12,
                _pagePadding,
                bottomPadding,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _LocationPill(
                            label: locationLabel,
                            onTap: onChangeLocation,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      _CartButton(count: cartItemCount, onTap: onCart),
                    ],
                  ),
                  const SizedBox(height: 26),
                  // Fades and drifts as the page scrolls, like an iOS large title.
                  ValueListenableBuilder<double>(
                    valueListenable: scrollOffset,
                    builder: (context, offset, child) {
                      final t = (1 - offset / 140).clamp(0.0, 1.0);
                      return Opacity(
                        opacity: t,
                        child: Transform.translate(
                          offset: Offset(0, math.min(offset, 140) * .16),
                          child: child,
                        ),
                      );
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _greeting(),
                          style: _t(
                            13.5,
                            c: Colors.white.withValues(alpha: .78),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Fresh water,\ndelivered to your door.',
                          style: _t(
                            27,
                            w: FontWeight.w800,
                            c: Colors.white,
                            h: 1.14,
                            ls: -.7,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  _SearchField(
                    controller: searchController,
                    focusNode: searchFocus,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LocationPill extends StatelessWidget {
  const _LocationPill({required this.label, required this.onTap});

  final String? label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Browsing location: ${label ?? 'not set'}. Double tap to change.',
    child: Material(
      color: Colors.white.withValues(alpha: .12),
      shape: StadiumBorder(
        side: BorderSide(color: Colors.white.withValues(alpha: .22)),
      ),
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 7, 12, 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.location_on_rounded,
                  color: primaryBlue,
                  size: 17,
                ),
              ),
              const SizedBox(width: 9),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Browsing near',
                      style: _t(10.5, c: Colors.white.withValues(alpha: .72)),
                    ),
                    Text(
                      label ?? 'Set your location',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _t(13.5, w: FontWeight.w800, c: Colors.white),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 2),
              const Icon(
                Icons.keyboard_arrow_down_rounded,
                color: Colors.white,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _CartButton extends StatelessWidget {
  const _CartButton({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: count > 0 ? 'Cart, $count items' : 'Cart',
    child: Material(
      color: Colors.white.withValues(alpha: .12),
      shape: CircleBorder(
        side: BorderSide(color: Colors.white.withValues(alpha: .22)),
      ),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 46,
          height: 46,
          child: Center(
            child: Badge(
              isLabelVisible: count > 0,
              label: Text('$count'),
              backgroundColor: danger,
              child: const Icon(
                Icons.shopping_bag_outlined,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.focusNode});

  final TextEditingController controller;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(16),
      boxShadow: [
        BoxShadow(
          color: _headerStart.withValues(alpha: .22),
          blurRadius: 24,
          offset: const Offset(0, 10),
        ),
      ],
    ),
    child: TextField(
      controller: controller,
      focusNode: focusNode,
      textInputAction: TextInputAction.search,
      onTapOutside: (_) => focusNode.unfocus(),
      style: _t(14.5),
      decoration: InputDecoration(
        hintText: 'Search stations or area',
        hintStyle: _t(14.5, w: FontWeight.w500, c: textGray),
        prefixIcon: const Icon(Icons.search_rounded, color: primaryBlue),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                onPressed: controller.clear,
                icon: const Icon(Icons.close_rounded, color: textGray),
              ),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
    ),
  );
}

// ============================================================
// COMPACT BAR (fades in once the header has scrolled away)
// ============================================================

class _CompactBar extends StatelessWidget {
  const _CompactBar({
    required this.scrollOffset,
    required this.from,
    required this.locationLabel,
    required this.onLocation,
    required this.onSearch,
    required this.cartItemCount,
    required this.onCart,
  });

  final ValueNotifier<double> scrollOffset;
  final double from;
  final String? locationLabel;
  final VoidCallback onLocation;
  final VoidCallback onSearch;
  final int cartItemCount;
  final VoidCallback onCart;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return ValueListenableBuilder<double>(
      valueListenable: scrollOffset,
      builder: (context, offset, _) {
        final t = ((offset - from) / 48).clamp(0.0, 1.0);
        if (t == 0) return const SizedBox.shrink();
        return IgnorePointer(
          ignoring: t < .6,
          child: Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, (1 - t) * -12),
              child: ClipRect(
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                  child: Container(
                    padding: EdgeInsets.fromLTRB(16, top + 8, 16, 10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .88),
                      border: const Border(
                        bottom: BorderSide(color: _hairline),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Material(
                            color: _pageBackground,
                            shape: const StadiumBorder(
                              side: BorderSide(color: _hairline),
                            ),
                            child: InkWell(
                              onTap: onLocation,
                              customBorder: const StadiumBorder(),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  9,
                                  10,
                                  9,
                                ),
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.location_on_rounded,
                                      size: 18,
                                      color: primaryBlue,
                                    ),
                                    const SizedBox(width: 7),
                                    Expanded(
                                      child: Text(
                                        locationLabel ?? 'Set your location',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: _t(13, w: FontWeight.w700),
                                      ),
                                    ),
                                    const Icon(
                                      Icons.keyboard_arrow_down_rounded,
                                      size: 20,
                                      color: textGray,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _RoundIconButton(
                          icon: Icons.search_rounded,
                          label: 'Search stations',
                          onTap: onSearch,
                        ),
                        const SizedBox(width: 8),
                        _RoundIconButton(
                          icon: Icons.shopping_bag_outlined,
                          label: 'Cart',
                          badge: cartItemCount,
                          onTap: onCart,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.badge = 0,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: Material(
      color: _pageBackground,
      shape: const CircleBorder(side: BorderSide(color: _hairline)),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: Badge(
              isLabelVisible: badge > 0,
              label: Text('$badge'),
              backgroundColor: danger,
              child: Icon(icon, size: 21, color: textDark),
            ),
          ),
        ),
      ),
    ),
  );
}

// ============================================================
// LOCATION SHEET
// ============================================================

class _LocationSheet extends StatelessWidget {
  const _LocationSheet({
    required this.label,
    required this.location,
    required this.onChange,
  });

  final String? label;
  final DeliveryLocation? location;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final hasLocation =
        location?.latitude != null && location?.longitude != null;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 22),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFD9E5EF),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Browsing location',
              style: _t(19, w: FontWeight.w800, ls: -.2),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _pageBackground,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: _hairline),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: lightBlue,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.location_on_rounded,
                      color: primaryBlue,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          hasLocation
                              ? (label ?? 'Pinned map location')
                              : 'No browsing location selected',
                          style: _t(14.5, w: FontWeight.w700, h: 1.35),
                        ),
                        if (hasLocation) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Used to find nearby stations only. Set your delivery address at checkout.',
                            style: _t(
                              12.5,
                              w: FontWeight.w500,
                              c: textGray,
                              h: 1.4,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onChange,
                style: FilledButton.styleFrom(
                  backgroundColor: primaryBlue,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.edit_location_alt_rounded),
                label: Text(
                  hasLocation
                      ? 'Change browsing location'
                      : 'Set browsing location',
                  style: _t(14.5, w: FontWeight.w700, c: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// ACTIVE ORDER BANNER
// ============================================================

class _ActiveOrderBanner extends StatelessWidget {
  const _ActiveOrderBanner({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => _Reveal(
    child: Semantics(
      button: true,
      label: 'Order in progress: $label. Double tap to track.',
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: _hairline),
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: lightBlue,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.local_shipping_rounded,
                    color: primaryBlue,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: const BoxDecoration(
                              color: success,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 7),
                          Text(
                            'Order in progress',
                            style: _t(13.5, w: FontWeight.w800),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _t(12.5, w: FontWeight.w500, c: textGray),
                      ),
                    ],
                  ),
                ),
                Text(
                  'Track',
                  style: _t(13, w: FontWeight.w800, c: primaryBlue),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: primaryBlue,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

// ============================================================
// PROMO BANNER
// One card that cross-fades in place, so nothing slides across the
// screen. Swipe to change, tap to act. The thin bar shows the timing.
// ============================================================

class _PromoData {
  const _PromoData({
    required this.title,
    required this.subtitle,
    required this.cta,
    required this.colors,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final String cta;
  final List<Color> colors;
  final IconData icon;
}

/// Brand messages that are always true. Replace with backend-driven
/// campaigns later.
const _promos = <_PromoData>[
  _PromoData(
    title: 'Fresh water,\nin minutes',
    subtitle: 'Refill or get a new gallon from stations near you.',
    cta: 'Find a station',
    colors: [Color(0xFF1B7CF0), Color(0xFF0A98C6)],
    icon: Icons.water_drop_rounded,
  ),
  _PromoData(
    title: 'Verified stations\nonly',
    subtitle: 'Every station is reviewed by our team before it goes live.',
    cta: 'Browse stations',
    colors: [Color(0xFF0A2A5C), Color(0xFF1B5FC4)],
    icon: Icons.verified_user_rounded,
  ),
  _PromoData(
    title: 'Pay when it\narrives',
    subtitle: 'Cash on delivery is ready at checkout. No card needed.',
    cta: 'Order now',
    colors: [Color(0xFF0E8F83), Color(0xFF1BB6A0)],
    icon: Icons.payments_rounded,
  ),
];

class _PromoBanner extends StatefulWidget {
  const _PromoBanner({required this.height, required this.onTap});

  final double height;
  final VoidCallback onTap;

  @override
  State<_PromoBanner> createState() => _PromoBannerState();
}

class _PromoBannerState extends State<_PromoBanner>
    with SingleTickerProviderStateMixin {
  static const _interval = Duration(seconds: 6);

  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: _interval,
  );
  int _index = 0;
  bool _holding = false;

  @override
  void initState() {
    super.initState();
    _progress.addStatusListener((status) {
      if (status == AnimationStatus.completed) _go(1);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduceMotion(context)) {
      _progress.stop();
    } else if (!_holding && !_progress.isAnimating) {
      _progress.forward();
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void _go(int delta) {
    if (!mounted) return;
    setState(() => _index = (_index + delta + _promos.length) % _promos.length);
    _progress.reset();
    if (!_holding && !_reduceMotion(context)) _progress.forward();
  }

  void _hold() {
    _holding = true;
    _progress.stop();
  }

  void _release() {
    _holding = false;
    if (!_reduceMotion(context)) _progress.forward();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final reduceMotion = _reduceMotion(context);
    return MediaQuery(
      data: media.copyWith(
        textScaler: media.textScaler.clamp(maxScaleFactor: 1.15),
      ),
      child: Listener(
        onPointerDown: (_) => _hold(),
        onPointerUp: (_) => _release(),
        onPointerCancel: (_) => _release(),
        child: GestureDetector(
          onHorizontalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            if (velocity < -200) {
              _go(1);
            } else if (velocity > 200) {
              _go(-1);
            }
          },
          child: SizedBox(
            height: widget.height,
            child: Stack(
              children: [
                // Soft shadow lives outside the fade so it never flickers.
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(_cardRadius + 2),
                      boxShadow: [
                        BoxShadow(
                          color: _headerStart.withValues(alpha: .22),
                          blurRadius: 26,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(_cardRadius + 2),
                    child: AnimatedSwitcher(
                      duration: reduceMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 650),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) {
                        final fade = FadeTransition(
                          opacity: animation,
                          child: child,
                        );
                        if (reduceMotion) return fade;
                        return SlideTransition(
                          position:
                              Tween<Offset>(
                                begin: const Offset(0, .08),
                                end: Offset.zero,
                              ).animate(
                                CurvedAnimation(
                                  parent: animation,
                                  curve: Curves.easeOutCubic,
                                ),
                              ),
                          child: fade,
                        );
                      },
                      child: _PromoSlide(
                        key: ValueKey(_index),
                        data: _promos[_index],
                        onTap: widget.onTap,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 20,
                  bottom: 20,
                  child: ExcludeSemantics(
                    child: AnimatedBuilder(
                      animation: _progress,
                      builder: (context, _) => Row(
                        children: [
                          for (var i = 0; i < _promos.length; i++) ...[
                            if (i > 0) const SizedBox(width: 4),
                            _ProgressSegment(
                              fill: i < _index
                                  ? 1
                                  : i == _index
                                  ? _progress.value
                                  : 0,
                            ),
                          ],
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
    );
  }
}

class _ProgressSegment extends StatelessWidget {
  const _ProgressSegment({required this.fill});

  final double fill;

  @override
  Widget build(BuildContext context) => Container(
    width: 20,
    height: 3,
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .3),
      borderRadius: BorderRadius.circular(2),
    ),
    child: Align(
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: fill.clamp(0.0, 1.0),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(2),
          ),
          child: const SizedBox(height: 3),
        ),
      ),
    ),
  );
}

class _PromoSlide extends StatelessWidget {
  const _PromoSlide({super.key, required this.data, required this.onTap});

  final _PromoData data;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: data.colors,
      ),
    ),
    child: Stack(
      children: [
        Positioned(
          right: -40,
          top: -56,
          child: _SoftCircle(size: 190, alpha: .09),
        ),
        Positioned(
          right: 46,
          bottom: -84,
          child: _SoftCircle(size: 170, alpha: .06),
        ),
        Positioned(
          right: 22,
          top: 0,
          bottom: 0,
          child: Center(
            child: Icon(
              data.icon,
              size: 92,
              color: Colors.white.withValues(alpha: .22),
            ),
          ),
        ),
        Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 120, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    data.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: _t(
                      21,
                      w: FontWeight.w800,
                      c: Colors.white,
                      h: 1.15,
                      ls: -.4,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    data.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: _t(
                      12.5,
                      w: FontWeight.w500,
                      c: Colors.white.withValues(alpha: .88),
                      h: 1.4,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          data.cta,
                          style: _t(
                            12.5,
                            w: FontWeight.w800,
                            c: data.colors.first,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.arrow_forward_rounded,
                          size: 15,
                          color: data.colors.first,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _SoftCircle extends StatelessWidget {
  const _SoftCircle({required this.size, required this.alpha});

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

// ============================================================
// SECTION HEADER + FILTERS
// ============================================================

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({super.key, required this.title, this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(_pagePadding, 14, _pagePadding, 12),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: _t(20, w: FontWeight.w800, ls: -.3)),
        ),
        if (trailing != null)
          Text(
            trailing!,
            style: _t(12, w: FontWeight.w600, c: textGray),
          ),
      ],
    ),
  );
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.sort,
    required this.openNowOnly,
    required this.onSort,
    required this.onToggleOpen,
  });

  final _StationSort sort;
  final bool openNowOnly;
  final ValueChanged<_StationSort> onSort;
  final VoidCallback onToggleOpen;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 52,
    child: ListView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(
        horizontal: _pagePadding,
        vertical: 7,
      ),
      children: [
        _FilterChipButton(
          label: 'Open now',
          icon: Icons.schedule_rounded,
          selected: openNowOnly,
          onTap: onToggleOpen,
        ),
        const SizedBox(width: 8),
        for (final option in _StationSort.values) ...[
          _FilterChipButton(
            label: option.label,
            icon: option.icon,
            selected: sort == option,
            onTap: () => onSort(option),
          ),
          const SizedBox(width: 8),
        ],
      ],
    ),
  );
}

class _FilterChipButton extends StatelessWidget {
  const _FilterChipButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: label,
    child: AnimatedContainer(
      duration: _fast,
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: selected ? textDark : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: selected ? textDark : borderColor),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: selected ? Colors.white : textGray),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: _t(
                    12.5,
                    w: FontWeight.w700,
                    c: selected ? Colors.white : textDark,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

// ============================================================
// STATION CARD
// ============================================================

class _StationCard extends StatefulWidget {
  const _StationCard({required this.station, required this.onTap});

  final NearbyStation station;
  final VoidCallback onTap;

  @override
  State<_StationCard> createState() => _StationCardState();
}

class _StationCardState extends State<_StationCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final station = widget.station;
    final closed = !station.isOpen;
    final area = [
      if (station.barangay?.trim().isNotEmpty == true) station.barangay!,
      if (station.city?.trim().isNotEmpty == true) station.city!,
      if (station.province?.trim().isNotEmpty == true) station.province!,
    ].join(', ');
    final imageUrl = station.logoPath?.trim().isNotEmpty == true
        ? SupabaseService.client.storage
              .from('station-assets')
              .getPublicUrl(station.logoPath!)
        : null;
    final hasRating = station.ratingCount > 0 && station.ratingAverage != null;

    Widget media = Stack(
      fit: StackFit.expand,
      children: [
        const _StationImagePlaceholder(),
        if (imageUrl != null)
          Image.network(
            imageUrl,
            fit: BoxFit.cover,
            frameBuilder: (context, child, frame, loadedSynchronously) =>
                loadedSynchronously
                ? child
                : AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: const Duration(milliseconds: 350),
                    curve: Curves.easeOut,
                    child: child,
                  ),
            errorBuilder: (context, error, stackTrace) =>
                const SizedBox.shrink(),
          ),
      ],
    );
    if (closed) {
      media = ColorFiltered(
        colorFilter: ColorFilter.mode(
          Colors.grey.withValues(alpha: .7),
          BlendMode.saturation,
        ),
        child: media,
      );
    }

    return Semantics(
      button: true,
      label:
          '${station.name}, ${closed ? 'closed' : 'open now'}, '
          '${formatDistance(station.distanceKm)} away',
      child: AnimatedScale(
        scale: _pressed ? .98 : 1,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(_cardRadius),
            border: Border.all(color: _hairline),
            boxShadow: [
              BoxShadow(
                color: _navy.withValues(alpha: .06),
                blurRadius: 22,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(_cardRadius),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.onTap,
              onHighlightChanged: (value) => setState(() => _pressed = value),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 150,
                    width: double.infinity,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        media,
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.black.withValues(alpha: .16),
                                  Colors.transparent,
                                  Colors.black.withValues(alpha: .20),
                                ],
                                stops: const [0, .45, 1],
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 12,
                          top: 12,
                          child: _FrostedPill(
                            icon: null,
                            dotColor: closed ? textGray : success,
                            label: closed ? 'Closed' : 'Open now',
                          ),
                        ),
                        Positioned(
                          right: 12,
                          top: 12,
                          child: _FrostedPill(
                            icon: Icons.near_me_rounded,
                            label: formatDistance(station.distanceKm),
                          ),
                        ),
                        Positioned(
                          left: 12,
                          bottom: 12,
                          child: hasRating
                              ? _FrostedPill(
                                  icon: Icons.star_rounded,
                                  iconColor: warning,
                                  label:
                                      '${station.ratingAverage!.toStringAsFixed(1)} (${station.ratingCount})',
                                )
                              : const _FrostedPill(
                                  icon: Icons.auto_awesome_rounded,
                                  iconColor: primaryBlue,
                                  label: 'New',
                                ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                station.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: _t(17, w: FontWeight.w800, ls: -.3),
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Icon(
                              Icons.verified_rounded,
                              size: 17,
                              color: primaryBlue,
                            ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        Row(
                          children: [
                            const Icon(
                              Icons.place_outlined,
                              size: 14,
                              color: textGray,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                area.isEmpty ? 'Nearby water station' : area,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: _t(
                                  12.5,
                                  w: FontWeight.w500,
                                  c: textGray,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        const Divider(height: 1, color: _hairline),
                        const SizedBox(height: 12),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Starting from',
                                  style: _t(
                                    10.5,
                                    w: FontWeight.w600,
                                    c: textGray,
                                  ),
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  '₱${station.startingPrice.toStringAsFixed(0)}',
                                  style: _t(
                                    19,
                                    w: FontWeight.w800,
                                    c: primaryBlue,
                                    ls: -.3,
                                  ),
                                ),
                              ],
                            ),
                            const Spacer(),
                            if (station.estimatedDeliveryMinutes != null) ...[
                              Row(
                                children: [
                                  const Icon(
                                    Icons.timer_outlined,
                                    size: 15,
                                    color: textGray,
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    '${station.estimatedDeliveryMinutes} min',
                                    style: _t(12.5, w: FontWeight.w700),
                                  ),
                                ],
                              ),
                              const SizedBox(width: 14),
                            ],
                            Container(
                              width: 36,
                              height: 36,
                              decoration: const BoxDecoration(
                                color: lightBlue,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.arrow_forward_rounded,
                                size: 18,
                                color: primaryBlue,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Frosted white badge that stays readable over any photo.
class _FrostedPill extends StatelessWidget {
  const _FrostedPill({
    required this.label,
    this.icon,
    this.iconColor = primaryBlue,
    this.dotColor,
  });

  final String label;
  final IconData? icon;
  final Color iconColor;
  final Color? dotColor;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(20),
    child: BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .9),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (dotColor != null) ...[
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
            ] else if (icon != null) ...[
              Icon(icon, size: 13, color: iconColor),
              const SizedBox(width: 4),
            ],
            Text(label, style: _t(11.5, w: FontWeight.w800)),
          ],
        ),
      ),
    ),
  );
}

class _StationImagePlaceholder extends StatelessWidget {
  const _StationImagePlaceholder();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [lightBlue, paleBlue],
      ),
    ),
    child: Stack(
      alignment: Alignment.center,
      children: [
        Positioned(
          right: -14,
          bottom: -22,
          child: Icon(
            Icons.water_drop_rounded,
            size: 110,
            color: primaryBlue.withValues(alpha: .08),
          ),
        ),
        const Icon(Icons.storefront_rounded, color: primaryBlue, size: 38),
      ],
    ),
  );
}

// ============================================================
// LOADING / EMPTY STATES
// ============================================================

class _SlideGradient extends GradientTransform {
  const _SlideGradient(this.percent);

  final double percent;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * percent, 0, 0);
}

/// Sweeps a soft highlight across opaque placeholder shapes.
class _Shimmer extends StatefulWidget {
  const _Shimmer({required this.child});

  final Widget child;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1700),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduceMotion(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: widget.child,
    builder: (context, child) => ShaderMask(
      blendMode: BlendMode.srcATop,
      shaderCallback: (bounds) => LinearGradient(
        begin: const Alignment(-1, -.3),
        end: const Alignment(1, .3),
        colors: const [Color(0xFFE6EEF7), Color(0xFFF6FAFE), Color(0xFFE6EEF7)],
        stops: const [.1, .3, .5],
        transform: _SlideGradient(_controller.value * 2 - 1),
      ).createShader(bounds),
      child: child,
    ),
  );
}

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();

  Widget _bar(double width, double height) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
    ),
  );

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading stations',
    child: Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border.all(color: _hairline),
      ),
      child: _Shimmer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(height: 150, color: Colors.white),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _bar(190, 16),
                  const SizedBox(height: 10),
                  _bar(120, 12),
                  const SizedBox(height: 22),
                  Row(children: [_bar(80, 28), const Spacer(), _bar(36, 36)]),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _StateIcon extends StatelessWidget {
  const _StateIcon({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 64,
    height: 64,
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      shape: BoxShape.circle,
    ),
    child: Icon(icon, color: color, size: 30),
  );
}

class _MarketplaceStateCard extends StatelessWidget {
  const _MarketplaceStateCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => _Reveal(
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(26),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border.all(color: _hairline),
      ),
      child: child,
    ),
  );
}

// ============================================================
// FOOTER
// ============================================================

class _HomeFooter extends StatelessWidget {
  const _HomeFooter();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(_pagePadding, 4, _pagePadding, 44),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Why customers choose AquaDirect',
          style: _t(16, w: FontWeight.w800, ls: -.2),
        ),
        const SizedBox(height: 12),
        const IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _BenefitTile(
                  icon: Icons.verified_rounded,
                  color: primaryBlue,
                  title: 'Verified stations',
                  subtitle: 'Reviewed by our team',
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: _BenefitTile(
                  icon: Icons.receipt_long_rounded,
                  color: _aqua,
                  title: 'Clear pricing',
                  subtitle: 'Water, deposit and fees upfront',
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: _BenefitTile(
                  icon: Icons.payments_rounded,
                  color: _mint,
                  title: 'Pay on delivery',
                  subtitle: 'Cash on delivery by default',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 32),
        Center(
          child: Column(
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: 'Aqua',
                      style: GoogleFonts.plusJakartaSans(
                        color: _navy,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -.4,
                      ),
                    ),
                    TextSpan(
                      text: 'Direct',
                      style: GoogleFonts.manrope(
                        color: primaryBlue,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Fresh water, delivered.',
                style: _t(12, w: FontWeight.w500, c: textGray),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _BenefitTile extends StatelessWidget {
  const _BenefitTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: _hairline),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: color.withValues(alpha: .12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: 18),
        ),
        const SizedBox(height: 10),
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: _t(12.5, w: FontWeight.w800, h: 1.25),
        ),
        const SizedBox(height: 3),
        Text(
          subtitle,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: _t(11, w: FontWeight.w500, c: textGray, h: 1.35),
        ),
      ],
    ),
  );
}

// ============================================================
// LEGACY PRODUCT DETAILS (unchanged)
// ============================================================

class ProductDetailsScreen extends StatefulWidget {
  final String brand;
  final String price;
  final Widget Function() buildMainWrapper;

  const ProductDetailsScreen({
    super.key,
    required this.brand,
    required this.price,
    required this.buildMainWrapper,
  });

  @override
  State<ProductDetailsScreen> createState() => _ProductDetailsScreenState();
}

class _ProductDetailsScreenState extends State<ProductDetailsScreen> {
  int quantity = 1;

  @override
  Widget build(BuildContext context) {
    final priceValue = double.tryParse(widget.price.replaceAll('₱', '')) ?? 35;
    final total = priceValue * quantity;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Product Details',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        backgroundColor: paleBlue,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 30),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 260,
              width: double.infinity,
              decoration: BoxDecoration(
                color: lightBlue,
                borderRadius: BorderRadius.circular(25),
              ),
              child: const Icon(
                Icons.local_drink_rounded,
                size: 140,
                color: primaryBlue,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              widget.brand,
              style: const TextStyle(
                color: primaryBlue,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 5),
            const Text(
              '5-Gallon Water Refill',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: textDark,
              ),
            ),
            const SizedBox(height: 7),
            const Text(
              'Purified drinking water for everyday use.',
              style: TextStyle(color: textGray, fontSize: 13),
            ),
            const SizedBox(height: 15),
            Text(
              widget.price,
              style: const TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.w900,
                color: textDark,
              ),
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                const Text(
                  'Quantity',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: textDark,
                  ),
                ),
                const Spacer(),
                QuantityControl(
                  quantity: quantity,
                  onMinus: () {
                    if (quantity > 1) {
                      setState(() => quantity--);
                    }
                  },
                  onPlus: () => setState(() => quantity++),
                ),
              ],
            ),
            const SizedBox(height: 22),
            AppCard(
              padding: const EdgeInsets.all(17),
              child: Row(
                children: [
                  const Text('Subtotal', style: TextStyle(color: textGray)),
                  const Spacer(),
                  Text(
                    '₱${total.toStringAsFixed(0)}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: textDark,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          CartScreen(buildMainWrapper: widget.buildMainWrapper),
                    ),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryBlue,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
                  'Add to Cart',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// CART
// ============================================================

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/foundation.dart' show ValueListenable;
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
//import 'cart_checkout_screen_qr.dart' as qr_checkout;

// ============================================================
// DESIGN TOKENS
// ============================================================

const _pageBackground = Color(0xFFF5F8FC);
// Same blue as the profile screen's header.
const _headerStart = Color(0xFF2860E8);
const _headerDark = Color(0xFF1743B5);
const _navy = Color(0xFF0A2A5C);
const _aqua = Color(0xFF1FB5C9);
const _mint = Color(0xFF16A37F);
const _hairline = Color(0xFFE6EEF7);
const _skeleton = Color(0xFFE6EEF7);

const _pagePadding = 20.0;
const _cardRadius = 22.0;

/// On tablets and landscape the content stays this wide and centred, so
/// cards never stretch across the whole screen.
const _maxContentWidth = 680.0;

/// Short, quiet motion in the style of iOS: ease-out curves, no loops.
/// Everything respects the system "remove animations" setting.
const _fast = Duration(milliseconds: 200);
const _medium = Duration(milliseconds: 280);

bool _reduceMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context);

/// Side gutter for a given screen width: 20 on phones, growing on wide
/// screens so the content column stays centred.
double _gutterFor(double width) =>
    math.max(_pagePadding, (width - _maxContentWidth) / 2);

/// Cached text styles. `GoogleFonts.manrope` is comparatively expensive, so
/// each distinct style is created once and reused on every rebuild.
final _styleCache =
    <(double, FontWeight, Color, double?, double?), TextStyle>{};

TextStyle _t(
  double size, {
  FontWeight w = FontWeight.w600,
  Color c = textDark,
  double? h,
  double? ls,
}) => _styleCache.putIfAbsent(
  (size, w, c, h, ls),
  () => GoogleFonts.manrope(
    fontSize: size,
    fontWeight: w,
    color: c,
    height: h,
    letterSpacing: ls,
  ),
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
  /// Scroll distance after which the compact top bar appears.
  static const _compactFrom = 150.0;

  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  final _scrollController = ScrollController();
  final _stationsKey = GlobalKey();

  /// Flips once when the header scrolls away. Only the status bar style and
  /// the compact bar listen to it, so scrolling never rebuilds the page.
  final _compact = ValueNotifier<bool>(false);

  /// Stations that already played their entrance animation.
  final _revealed = <String>{};

  Timer? _searchDebounce;
  String _query = '';

  late DeliveryLocation? _browsingLocation = widget.initialBrowsingLocation;
  List<NearbyStation> _stations = const [];

  /// Filtered and sorted result, recomputed only when an input changes.
  List<NearbyStation> _visible = const [];

  bool _loadingStations = false;
  bool _openNowOnly = false;
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
    _searchDebounce?.cancel();
    _searchController
      ..removeListener(_searchChanged)
      ..dispose();
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _compact.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Typing is debounced: the list is filtered once the customer pauses,
  /// instead of rebuilding the whole page on every keystroke.
  void _searchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 240), () {
      if (!mounted) return;
      final query = _searchController.text.trim().toLowerCase();
      if (query == _query) return;
      setState(() {
        _query = query;
        _recompute();
      });
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final compact = _scrollController.offset > _compactFrom;
    if (compact != _compact.value) _compact.value = compact;
  }

  /// Filters and sorts once per change, not once per build.
  void _recompute() {
    final list = _stations.where((station) {
      if (_openNowOnly && !station.isOpen) return false;
      if (_query.isEmpty) return true;
      return station.name.toLowerCase().contains(_query) ||
          (station.barangay?.toLowerCase().contains(_query) ?? false) ||
          (station.city?.toLowerCase().contains(_query) ?? false) ||
          (station.province?.toLowerCase().contains(_query) ?? false);
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
    _visible = list;
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
        _visible = const [];
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
        _recompute();
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
        builder: (_) => /*qr_checkout.*/
            CartScreen(buildMainWrapper: widget.buildMainWrapper),
      ),
    );
    if (mounted) widget.onCartChanged?.call();
  }

  void _clearFilters() {
    _searchDebounce?.cancel();
    _searchController.clear();
    setState(() {
      _query = '';
      _openNowOnly = false;
      _recompute();
    });
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

  Future<void> _showStationDetails(NearbyStation station) async {
    await Navigator.of(context).push<void>(
      CupertinoPageRoute(
        builder: (_) => StationScreen(
          station: station,
          initialBrowsingLocation: _browsingLocation,
          onCartChanged: widget.onCartChanged,
          buildMainWrapper: widget.buildMainWrapper,
        ),
      ),
    );
    if (mounted) await _loadNearbyStations();
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

  // ---------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    // Aspect-specific lookups only: the keyboard opening must not rebuild
    // the whole page.
    final width = MediaQuery.sizeOf(context).width;
    final gutter = _gutterFor(width);
    final topInset = MediaQuery.paddingOf(context).top;

    final stations = _visible;
    final searching = _query.isNotEmpty;
    final showList =
        _hasCoordinates &&
        !_loadingStations &&
        _loadError == null &&
        stations.isNotEmpty;
    final listPadding = EdgeInsets.fromLTRB(gutter, 4, gutter, 28);

    final page = Scaffold(
      backgroundColor: _pageBackground,
      // The list does not resize with the keyboard; a spacer at the end of
      // the list makes room instead, so opening the keyboard stays smooth.
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          RefreshIndicator(
            color: primaryBlue,
            edgeOffset: topInset + 70,
            onRefresh: () => _loadNearbyStations(),
            child: CustomScrollView(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              cacheExtent: 600,
              slivers: [
                SliverToBoxAdapter(
                  child: RepaintBoundary(
                    child: _HeaderWithPromo(
                      showPromo: !searching,
                      gutter: gutter,
                      promoHeight: width < 340 ? 176.0 : 156.0,
                      locationLabel: _locationLabel,
                      onChangeLocation: _showLocationOptions,
                      cartItemCount: widget.cartItemCount,
                      onCart: _openCart,
                      searchController: _searchController,
                      searchFocus: _searchFocus,
                      onPromoTap: _scrollToStations,
                    ),
                  ),
                ),
                if (widget.activeOrderLabel != null)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(gutter, 4, gutter, 0),
                      child: _ActiveOrderBanner(
                        label: widget.activeOrderLabel!,
                        onTap: widget.onTrackOrder,
                      ),
                    ),
                  ),
                SliverToBoxAdapter(
                  child: _SectionHeader(
                    key: _stationsKey,
                    gutter: gutter,
                    title: 'Nearby stations',
                    trailing: showList
                        ? '${stations.length} found · ${_searchRadiusKm.round()} km'
                        : null,
                  ),
                ),
                SliverToBoxAdapter(
                  child: _FilterRow(
                    gutter: gutter,
                    sort: _sort,
                    openNowOnly: _openNowOnly,
                    onSort: (value) {
                      HapticFeedback.selectionClick();
                      setState(() {
                        _sort = value;
                        _recompute();
                      });
                    },
                    onToggleOpen: () {
                      HapticFeedback.selectionClick();
                      setState(() {
                        _openNowOnly = !_openNowOnly;
                        _recompute();
                      });
                    },
                  ),
                ),
                if (showList)
                  SliverPadding(
                    padding: listPadding,
                    sliver: SliverList.separated(
                      itemCount: stations.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 16),
                      itemBuilder: (context, index) {
                        final station = stations[index];
                        final key = '${station.name}#${station.distanceKm}';
                        final card = _StationCard(
                          key: ValueKey(key),
                          station: station,
                          onTap: () => _showStationDetails(station),
                        );
                        // Only the first few cards animate in, once. Cards
                        // that scroll into view later appear instantly, which
                        // keeps scrolling smooth.
                        if (index < 4 && _revealed.add(key)) {
                          return _Reveal(
                            delay: Duration(milliseconds: 60 * index),
                            child: card,
                          );
                        }
                        return card;
                      },
                    ),
                  )
                else if (_hasCoordinates && _loadingStations)
                  SliverPadding(
                    padding: listPadding,
                    sliver: SliverList.separated(
                      itemCount: 3,
                      separatorBuilder: (_, _) => const SizedBox(height: 16),
                      itemBuilder: (_, _) => const _SkeletonCard(),
                    ),
                  )
                else
                  SliverPadding(
                    padding: listPadding,
                    sliver: SliverToBoxAdapter(child: _buildStateView()),
                  ),
                if (showList && !searching)
                  SliverToBoxAdapter(
                    child: RepaintBoundary(child: _HomeFooter(gutter: gutter)),
                  ),
                const SliverToBoxAdapter(child: _KeyboardSpacer()),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _CompactBar(
              compact: _compact,
              gutter: gutter,
              locationLabel: _locationLabel,
              onLocation: _showLocationOptions,
              onSearch: _focusSearch,
              cartItemCount: widget.cartItemCount,
              onCart: _openCart,
            ),
          ),
        ],
      ),
    );

    // Clamp very large system text so layouts never overflow.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: ValueListenableBuilder<bool>(
        valueListenable: _compact,
        child: page,
        builder: (context, compact, child) =>
            AnnotatedRegion<SystemUiOverlayStyle>(
              value: compact
                  ? SystemUiOverlayStyle.dark
                  : SystemUiOverlayStyle.light,
              child: child!,
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
              textAlign: TextAlign.center,
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

/// Reserves space for the keyboard at the end of the list. Only this tiny
/// widget listens to the keyboard height.
class _KeyboardSpacer extends StatelessWidget {
  const _KeyboardSpacer();

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: MediaQuery.viewInsetsOf(context).bottom);
}

// ============================================================
// MOTION PRIMITIVES
// ============================================================

/// Fades and lifts its child in once.
class _Reveal extends StatefulWidget {
  const _Reveal({required this.child, this.delay = Duration.zero});

  final Widget child;
  final Duration delay;

  @override
  State<_Reveal> createState() => _RevealState();
}

class _RevealState extends State<_Reveal> with SingleTickerProviderStateMixin {
  static const _duration = Duration(milliseconds: 420);

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
    _controller.forward();
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
/// customer is searching, the banner is removed.
class _HeaderWithPromo extends StatelessWidget {
  const _HeaderWithPromo({
    required this.showPromo,
    required this.gutter,
    required this.promoHeight,
    required this.locationLabel,
    required this.onChangeLocation,
    required this.cartItemCount,
    required this.onCart,
    required this.searchController,
    required this.searchFocus,
    required this.onPromoTap,
  });

  static const _overlap = 46.0;
  static const _gap = 20.0;

  final bool showPromo;
  final double gutter;
  final double promoHeight;
  final String? locationLabel;
  final VoidCallback onChangeLocation;
  final int cartItemCount;
  final VoidCallback onCart;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final VoidCallback onPromoTap;

  @override
  Widget build(BuildContext context) {
    final header = _HomeHeader(
      gutter: gutter,
      locationLabel: locationLabel,
      onChangeLocation: onChangeLocation,
      cartItemCount: cartItemCount,
      onCart: onCart,
      searchController: searchController,
      searchFocus: searchFocus,
      bottomPadding: showPromo ? _overlap + 22 : 24,
    );
    if (!showPromo) return header;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Column(
          children: [
            header,
            SizedBox(height: promoHeight - _overlap + _gap),
          ],
        ),
        Positioned(
          left: gutter,
          right: gutter,
          bottom: _gap,
          child: _PromoBanner(height: promoHeight, onTap: onPromoTap),
        ),
      ],
    );
  }
}

/// Static: nothing in the header reacts to scrolling.
class _HomeHeader extends StatelessWidget {
  const _HomeHeader({
    required this.gutter,
    required this.locationLabel,
    required this.onChangeLocation,
    required this.cartItemCount,
    required this.onCart,
    required this.searchController,
    required this.searchFocus,
    required this.bottomPadding,
  });

  final double gutter;
  final String? locationLabel;
  final VoidCallback onChangeLocation;
  final int cartItemCount;
  final VoidCallback onCart;
  final TextEditingController searchController;
  final FocusNode searchFocus;
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
            // Soft ripples, the same as the profile header. Nothing here moves.
            Positioned(
              right: -60,
              top: -40 + top * .4,
              child: const _SoftCircle(size: 220, alpha: .07),
            ),
            Positioned(
              right: 10,
              top: 30 + top * .4,
              child: const _SoftCircle(size: 110, alpha: .08),
            ),
            Positioned(
              left: -50,
              bottom: 10,
              child: const _SoftCircle(size: 150, alpha: .05),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                gutter,
                top + 12,
                gutter,
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
                  Text(
                    _greeting(),
                    style: _t(13.5, c: Colors.white.withValues(alpha: .78)),
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
          color: _headerStart.withValues(alpha: .2),
          blurRadius: 18,
          offset: const Offset(0, 8),
        ),
      ],
    ),
    // Only the field listens to what is typed, so the clear button appears
    // instantly without rebuilding the rest of the page.
    child: ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => TextField(
        controller: controller,
        focusNode: focusNode,
        textInputAction: TextInputAction.search,
        onTapOutside: (_) => focusNode.unfocus(),
        style: _t(14.5),
        decoration: InputDecoration(
          hintText: 'Search stations or area',
          hintStyle: _t(14.5, w: FontWeight.w500, c: textGray),
          prefixIcon: const Icon(Icons.search_rounded, color: primaryBlue),
          suffixIcon: value.text.isEmpty
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
    ),
  );
}

// ============================================================
// COMPACT BAR
// Appears once when the header has scrolled away and leaves once when it
// returns. No per-frame work and no blur, so scrolling stays smooth.
// ============================================================

class _CompactBar extends StatelessWidget {
  const _CompactBar({
    required this.compact,
    required this.gutter,
    required this.locationLabel,
    required this.onLocation,
    required this.onSearch,
    required this.cartItemCount,
    required this.onCart,
  });

  final ValueListenable<bool> compact;
  final double gutter;
  final String? locationLabel;
  final VoidCallback onLocation;
  final VoidCallback onSearch;
  final int cartItemCount;
  final VoidCallback onCart;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return ValueListenableBuilder<bool>(
      valueListenable: compact,
      builder: (context, visible, _) => IgnorePointer(
        ignoring: !visible,
        child: AnimatedSlide(
          offset: visible ? Offset.zero : const Offset(0, -1),
          duration: _medium,
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: _fast,
            child: RepaintBoundary(
              child: Container(
                padding: EdgeInsets.fromLTRB(
                  math.max(16, gutter - 4),
                  top + 8,
                  math.max(16, gutter - 4),
                  10,
                ),
                decoration: const BoxDecoration(
                  color: Color(0xF7FFFFFF),
                  border: Border(bottom: BorderSide(color: _hairline)),
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
                            padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
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
// One card that cross-fades in place. No swipe gesture, no sliding and no
// per-frame animation: it changes every few seconds and repaints only then.
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

class _PromoBannerState extends State<_PromoBanner> {
  Timer? _timer;
  int _index = 0;
  bool _holding = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _timer?.cancel();
    if (_reduceMotion(context)) return;
    _timer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted || _holding) return;
      setState(() => _index = (_index + 1) % _promos.length);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = _reduceMotion(context);
    final radius = BorderRadius.circular(_cardRadius + 2);
    return Listener(
      onPointerDown: (_) => _holding = true,
      onPointerUp: (_) => _holding = false,
      onPointerCancel: (_) => _holding = false,
      child: SizedBox(
        height: widget.height,
        child: RepaintBoundary(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: [
                BoxShadow(
                  color: _headerStart.withValues(alpha: .2),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  AnimatedSwitcher(
                    duration: reduceMotion ? Duration.zero : _medium * 1.6,
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, animation) =>
                        FadeTransition(opacity: animation, child: child),
                    child: _PromoSlide(
                      key: ValueKey(_index),
                      data: _promos[_index],
                      onTap: widget.onTap,
                    ),
                  ),
                  Positioned(
                    right: 20,
                    bottom: 20,
                    child: ExcludeSemantics(
                      child: Row(
                        children: [
                          for (var i = 0; i < _promos.length; i++)
                            AnimatedContainer(
                              duration: _fast,
                              margin: EdgeInsets.only(left: i == 0 ? 0 : 4),
                              width: i == _index ? 18 : 6,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(
                                  alpha: i == _index ? 1 : .4,
                                ),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                        ],
                      ),
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

class _PromoSlide extends StatelessWidget {
  const _PromoSlide({super.key, required this.data, required this.onTap});

  final _PromoData data;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // Narrow phones get a smaller icon and more room for the text.
      final narrow = constraints.maxWidth < 300;
      return DecoratedBox(
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
                  size: narrow ? 68 : 92,
                  color: Colors.white.withValues(alpha: .22),
                ),
              ),
            ),
            Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: onTap,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(22, 18, narrow ? 80 : 120, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        data.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: _t(
                          narrow ? 19 : 21,
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
    },
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
  const _SectionHeader({
    super.key,
    required this.gutter,
    required this.title,
    this.trailing,
  });

  final double gutter;
  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(gutter, 14, gutter, 12),
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
    required this.gutter,
    required this.sort,
    required this.openNowOnly,
    required this.onSort,
    required this.onToggleOpen,
  });

  final double gutter;
  final _StationSort sort;
  final bool openNowOnly;
  final ValueChanged<_StationSort> onSort;
  final VoidCallback onToggleOpen;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 52,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(horizontal: gutter, vertical: 7),
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
// No blur filters: every badge is a plain translucent pill, which keeps
// each card cheap to paint while scrolling.
// ============================================================

class _StationCard extends StatefulWidget {
  const _StationCard({super.key, required this.station, required this.onTap});

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

    return Semantics(
      button: true,
      label:
          '${station.name}, ${closed ? 'closed' : 'open now'}, '
          '${formatDistance(station.distanceKm)} away'
          '${hasRating ? ', rated ${station.ratingAverage!.toStringAsFixed(1)} '
                    'from ${station.ratingCount} ${station.ratingCount == 1 ? 'rating' : 'ratings'}' : ', no ratings yet'}',
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
                blurRadius: 16,
                offset: const Offset(0, 6),
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
                  // The photo scales with the card width: 140 to 200 px tall.
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final height = (constraints.maxWidth * .42).clamp(
                        140.0,
                        200.0,
                      );
                      return SizedBox(
                        height: height,
                        width: double.infinity,
                        child: _StationPhoto(
                          imageUrl: imageUrl,
                          cacheWidth:
                              (constraints.maxWidth *
                                      MediaQuery.devicePixelRatioOf(context))
                                  .round(),
                          closed: closed,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Positioned(
                                left: 12,
                                top: 12,
                                child: _Pill(
                                  dotColor: closed ? textGray : success,
                                  label: closed ? 'Closed' : 'Open now',
                                ),
                              ),
                              Positioned(
                                right: 12,
                                top: 12,
                                child: _Pill(
                                  icon: Icons.near_me_rounded,
                                  label: formatDistance(station.distanceKm),
                                ),
                              ),
                              Positioned(
                                left: 12,
                                bottom: 12,
                                child: hasRating
                                    ? _Pill(
                                        icon: Icons.star_rounded,
                                        iconColor: warning,
                                        label:
                                            '${station.ratingAverage!.toStringAsFixed(1)} · '
                                            '${station.ratingCount} ${station.ratingCount == 1 ? 'rating' : 'ratings'}',
                                      )
                                    : const _Pill(
                                        icon: Icons.auto_awesome_rounded,
                                        label: 'New',
                                      ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
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

/// Photo with a placeholder underneath, a soft top and bottom shade, and the
/// card badges on top. Images are decoded at display size to save memory.
class _StationPhoto extends StatelessWidget {
  const _StationPhoto({
    required this.imageUrl,
    required this.cacheWidth,
    required this.closed,
    required this.child,
  });

  final String? imageUrl;
  final int cacheWidth;
  final bool closed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    Widget media = Stack(
      fit: StackFit.expand,
      children: [
        const _StationImagePlaceholder(),
        if (imageUrl != null)
          Image.network(
            imageUrl!,
            fit: BoxFit.cover,
            cacheWidth: cacheWidth,
            gaplessPlayback: true,
            frameBuilder: (context, image, frame, loadedSynchronously) =>
                loadedSynchronously
                ? image
                : AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOut,
                    child: image,
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
    return Stack(
      fit: StackFit.expand,
      children: [
        media,
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x29000000), Color(0x00000000), Color(0x33000000)],
              stops: [0, .45, 1],
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// Plain translucent white badge, readable over any photo, no blur.
class _Pill extends StatelessWidget {
  const _Pill({
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
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xF2FFFFFF),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dotColor != null) ...[
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
        ] else if (icon != null) ...[
          Icon(icon, size: 13, color: iconColor),
          const SizedBox(width: 4),
        ],
        Text(label, style: _t(11.5, w: FontWeight.w800)),
      ],
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

/// A gentle opacity pulse. Much cheaper than a moving shimmer gradient.
class _Pulse extends StatefulWidget {
  const _Pulse({required this.child});

  final Widget child;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final Animation<double> _opacity = Tween<double>(
    begin: .55,
    end: 1,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduceMotion(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _opacity, child: widget.child);
}

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();

  Widget _bar(double width, double height) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: _skeleton,
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
      child: _Pulse(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(height: 150, color: _skeleton),
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
  const _HomeFooter({required this.gutter});

  final double gutter;

  static const _benefits = <(IconData, Color, String, String)>[
    (
      Icons.verified_rounded,
      primaryBlue,
      'Verified stations',
      'Reviewed by our team',
    ),
    (
      Icons.receipt_long_rounded,
      _aqua,
      'Clear pricing',
      'Water, deposit and fees upfront',
    ),
    (
      Icons.payments_rounded,
      _mint,
      'Pay on delivery',
      'Cash on delivery by default',
    ),
  ];

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(gutter, 4, gutter, 44),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Why customers choose AquaDirect',
          style: _t(16, w: FontWeight.w800, ls: -.2),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 600) {
              final tileWidth = math.min(constraints.maxWidth * .78, 260.0);
              return _BenefitCarousel(tileWidth: tileWidth);
            }
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < _benefits.length; i++) ...[
                    if (i > 0) const SizedBox(width: 10),
                    Expanded(
                      child: _BenefitTile(
                        icon: _benefits[i].$1,
                        color: _benefits[i].$2,
                        title: _benefits[i].$3,
                        subtitle: _benefits[i].$4,
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
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

/// The three benefit cards on narrow screens. They slide left one card at a
/// time, rest for a moment, and loop for ever.
///
/// There is no controller. A timer only decides which card is in front, and
/// AnimatedSlide does the movement. The row holds the cards twice: after the
/// last slide the view shows the second copy, which looks exactly like the
/// start, so it jumps back without animation and the loop has no visible seam.
///
/// Touching the cards pauses the loop. With "remove animations" turned on in
/// the system settings, the cards stay still in a swipeable row.
class _BenefitCarousel extends StatefulWidget {
  const _BenefitCarousel({required this.tileWidth});

  final double tileWidth;

  @override
  State<_BenefitCarousel> createState() => _BenefitCarouselState();
}

class _BenefitCarouselState extends State<_BenefitCarousel> {
  static const _benefits = _HomeFooter._benefits;
  static const _gap = 10.0;

  /// One slide every 3.4 s: 0.7 s of movement, then a rest.
  static const _every = Duration(milliseconds: 3400);
  static const _slideTime = Duration(milliseconds: 700);

  Timer? _timer;
  int _index = 0;
  bool _animate = true;
  bool _holding = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _timer?.cancel();
    if (_reduceMotion(context)) return;
    _timer = Timer.periodic(_every, (_) => _advance());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _advance() {
    if (!mounted || _holding) return;
    if (_index < _benefits.length) {
      setState(() => _index++);
      return;
    }
    // Now showing the second copy. Jump back unseen, then slide on.
    setState(() {
      _animate = false;
      _index = 0;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _animate = true;
        _index = 1;
      });
    });
  }

  Widget _tile(int i) {
    final data = _benefits[i % _benefits.length];
    return SizedBox(
      width: widget.tileWidth,
      child: ExcludeSemantics(
        // The second copy is only there for the loop.
        excluding: i >= _benefits.length,
        child: _BenefitTile(
          icon: data.$1,
          color: data.$2,
          title: data.$3,
          subtitle: data.$4,
        ),
      ),
    );
  }

  Widget _row(int count) => IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < count; i++) ...[
          if (i > 0) const SizedBox(width: _gap),
          _tile(i),
        ],
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final count = _benefits.length;
    if (_reduceMotion(context)) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: _row(count),
      );
    }

    final tile = widget.tileWidth;
    final total = count * 2;
    final rowWidth = total * tile + (total - 1) * _gap;
    return Listener(
      onPointerDown: (_) => _holding = true,
      onPointerUp: (_) => _holding = false,
      onPointerCancel: (_) => _holding = false,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: AnimatedSlide(
          // The offset is a fraction of the row's own width.
          offset: Offset(-(_index * (tile + _gap)) / rowWidth, 0),
          duration: _animate ? _slideTime : Duration.zero,
          curve: Curves.easeInOutCubic,
          child: _row(total),
        ),
      ),
    );
  }
}

/// One benefit card, laid out as before: the icon on the left, then the title
/// and the description. A blue wave sits in the upper-right corner.
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
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: _hairline),
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(17),
      child: Stack(
        children: [
          const Positioned(right: 0, top: 0, child: _WaveCorner()),
          Padding(
            padding: const EdgeInsets.all(12),
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
          ),
        ],
      ),
    ),
  );
}

/// The blue wave in a card's upper-right corner: a pale wave behind and a
/// smaller gradient wave in front, both with a flowing edge instead of a
/// straight cut. The card's rounded corner clips it.
class _WaveCorner extends StatelessWidget {
  const _WaveCorner();

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 76,
    height: 60,
    child: Stack(
      fit: StackFit.expand,
      children: [
        ClipPath(
          clipper: _WaveClipper(reach: 1, phase: .4, amplitude: 6),
          child: ColoredBox(color: Color(0x292860E8)),
        ),
        ClipPath(
          clipper: _WaveClipper(reach: .78, phase: 0, amplitude: 5),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [_headerStart, _headerDark],
                stops: [0, .75],
              ),
            ),
            child: SizedBox.expand(),
          ),
        ),
      ],
    ),
  );
}

/// Fills the upper-right corner up to a wavy diagonal edge. [reach] is how
/// much of the box the shape covers, [phase] shifts the wave, and [amplitude]
/// is how far the edge swings, in logical pixels.
class _WaveClipper extends CustomClipper<Path> {
  const _WaveClipper({
    required this.reach,
    required this.phase,
    required this.amplitude,
  });

  final double reach;
  final double phase;
  final double amplitude;

  @override
  Path getClip(Size size) {
    final left = size.width * (1 - reach);
    final run = size.width - left;
    final drop = size.height * reach;
    final length = math.sqrt(run * run + drop * drop);
    // Unit vector across the diagonal, pointing to the lower left.
    final nx = -drop / length;
    final ny = run / length;

    final path = Path()..moveTo(left, 0);
    const steps = 40;
    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      // Waves fading out at both ends so the edge meets the card side cleanly.
      final wave =
          amplitude *
          math.sin(t * math.pi * 3 + phase * math.pi) *
          math.sin(t * math.pi);
      path.lineTo(left + run * t + nx * wave, drop * t + ny * wave);
    }
    return path
      ..lineTo(size.width, 0)
      ..close();
  }

  @override
  bool shouldReclip(covariant _WaveClipper oldClipper) =>
      oldClipper.reach != reach ||
      oldClipper.phase != phase ||
      oldClipper.amplitude != amplitude;
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
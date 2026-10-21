import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_colors.dart';
import '../config/supabase_config.dart';
import '../models/nearby_station.dart';
import '../models/station_delivery_info.dart';
import '../models/station_marketplace_product.dart';
import '../models/station_social_links.dart';
import '../services/location_service.dart';
import '../services/nearby_empty_states.dart';
import '../services/supabase_service.dart';
import 'cart_checkout_screen.dart';
//import 'cart_checkout_screen_qr.dart' as qr_checkout;
import 'location_flow_screen.dart';

const _stationCanvas = Color(0xFFF5F8FC);
const _stationInk = Color(0xFF14233B);
const _danger = Color(0xFFD92D20);

/// Same low-stock threshold the seller portal uses.
const _lowStockThreshold = 5;

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

enum _StockLevel { out, low, ok, untracked }

_StockLevel _stockLevel(StationMarketplaceProduct p) {
  final stock = p.stockQuantity;
  if (stock == null) return _StockLevel.untracked;
  if (stock <= 0) return _StockLevel.out;
  if (stock <= _lowStockThreshold) return _StockLevel.low;
  return _StockLevel.ok;
}

/// Customer-facing station directory and station storefront.
///
/// Pass [station] to open its storefront; leave it null to browse nearby
/// stations.
class StationScreen extends StatelessWidget {
  const StationScreen({
    super.key,
    this.station,
    this.initialBrowsingLocation,
    this.onBrowsingLocationChanged,
    this.onCartChanged,
    required this.buildMainWrapper,
  });

  final NearbyStation? station;
  final DeliveryLocation? initialBrowsingLocation;
  final ValueChanged<DeliveryLocation>? onBrowsingLocationChanged;
  final VoidCallback? onCartChanged;
  final Widget Function() buildMainWrapper;

  @override
  Widget build(BuildContext context) {
    final selectedStation = station;
    if (selectedStation != null) {
      return _StationStorefront(
        station: selectedStation,
        deliveryLocation: initialBrowsingLocation,
        onCartChanged: onCartChanged,
        buildMainWrapper: buildMainWrapper,
      );
    }
    return _StationDirectory(
      initialBrowsingLocation: initialBrowsingLocation,
      onBrowsingLocationChanged: onBrowsingLocationChanged,
      onCartChanged: onCartChanged,
      buildMainWrapper: buildMainWrapper,
    );
  }
}

// ===========================================================================
// Directory
// ===========================================================================

class _StationDirectory extends StatefulWidget {
  const _StationDirectory({
    this.initialBrowsingLocation,
    this.onBrowsingLocationChanged,
    this.onCartChanged,
    required this.buildMainWrapper,
  });

  final DeliveryLocation? initialBrowsingLocation;
  final ValueChanged<DeliveryLocation>? onBrowsingLocationChanged;
  final VoidCallback? onCartChanged;
  final Widget Function() buildMainWrapper;

  @override
  State<_StationDirectory> createState() => _StationDirectoryState();
}

class _StationDirectoryState extends State<_StationDirectory> {
  final _searchController = TextEditingController();
  late DeliveryLocation? _location = widget.initialBrowsingLocation;
  List<NearbyStation> _stations = const [];
  bool _loading = false;
  bool _openNowOnly = false;
  String? _error;
  double _radiusKm = NearbyConfig.defaultRadiusKm;
  _StationSort _sort = _StationSort.nearest;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    if (_location == null) {
      _loadSavedBrowsingLocation();
    } else {
      _loadStations();
    }
  }

  @override
  void didUpdateWidget(covariant _StationDirectory oldWidget) {
    super.didUpdateWidget(oldWidget);
    final updatedLocation = widget.initialBrowsingLocation;
    if (updatedLocation != null &&
        (updatedLocation.latitude != _location?.latitude ||
            updatedLocation.longitude != _location?.longitude)) {
      _location = updatedLocation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadStations(radiusKm: NearbyConfig.defaultRadiusKm);
      });
    }
  }

  Future<void> _loadSavedBrowsingLocation() async {
    try {
      final savedLocation = await SupabaseService.getCustomerBrowsingLocation();
      if (!mounted) return;
      final location =
          _location ?? widget.initialBrowsingLocation ?? savedLocation;
      if (location == null) return;
      if (_location != location) setState(() => _location = location);
      widget.onBrowsingLocationChanged?.call(location);
      await _loadStations();
    } on Exception catch (exception) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load your location: $exception')),
      );
    }
  }

  @override
  void dispose() {
    _requestId++;
    _searchController
      ..removeListener(_onSearchChanged)
      ..dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadStations({double? radiusKm}) async {
    final latitude = _location?.latitude;
    final longitude = _location?.longitude;
    if (latitude == null || longitude == null) {
      setState(() {
        _stations = const [];
        _loading = false;
        _error = null;
        if (radiusKm != null) _radiusKm = radiusKm;
      });
      return;
    }

    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
      if (radiusKm != null) _radiusKm = radiusKm;
    });
    try {
      final result = await SupabaseService.getNearbyStations(
        latitude: latitude,
        longitude: longitude,
        radiusKm: radiusKm ?? _radiusKm,
        pageSize: 100,
      );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _stations = result;
        _loading = false;
      });
    } on Exception catch (exception) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _loading = false;
        _error = exception.toString();
      });
    }
  }

  Future<void> _changeLocation() async {
    final selectedLocation = await Navigator.of(context).push<DeliveryLocation>(
      MaterialPageRoute(
        builder: (flowContext) => LocationFlowScreen(
          browsingOnly: true,
          onLocationSelected: (location) =>
              Navigator.of(flowContext).pop(location),
          onSkip: () => Navigator.of(flowContext).pop(),
        ),
      ),
    );
    if (!mounted || selectedLocation == null) return;
    setState(() => _location = selectedLocation);
    widget.onBrowsingLocationChanged?.call(selectedLocation);
    try {
      await SupabaseService.saveCustomerBrowsingLocation(selectedLocation);
    } on Exception catch (exception) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                'Could not save your browsing location: $exception',
              ),
            ),
          );
      }
    }
    await _loadStations(radiusKm: NearbyConfig.defaultRadiusKm);
  }

  List<NearbyStation> get _visibleStations {
    final query = _searchController.text.trim().toLowerCase();
    final results = _stations.where((station) {
      if (_openNowOnly && !station.isOpen) return false;
      if (query.isEmpty) return true;
      return station.name.toLowerCase().contains(query) ||
          (station.barangay?.toLowerCase().contains(query) ?? false) ||
          (station.city?.toLowerCase().contains(query) ?? false) ||
          (station.province?.toLowerCase().contains(query) ?? false) ||
          (station.description?.toLowerCase().contains(query) ?? false);
    }).toList();

    switch (_sort) {
      case _StationSort.nearest:
        results.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
      case _StationSort.topRated:
        results.sort((a, b) {
          final byRating = (b.ratingAverage ?? 0).compareTo(
            a.ratingAverage ?? 0,
          );
          return byRating != 0
              ? byRating
              : a.distanceKm.compareTo(b.distanceKm);
        });
      case _StationSort.lowestPrice:
        results.sort((a, b) {
          final byPrice = a.startingPrice.compareTo(b.startingPrice);
          return byPrice != 0 ? byPrice : a.distanceKm.compareTo(b.distanceKm);
        });
    }
    return results;
  }

  Future<void> _openStation(NearbyStation station) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => StationScreen(
          station: station,
          initialBrowsingLocation: _location,
          onCartChanged: widget.onCartChanged,
          buildMainWrapper: widget.buildMainWrapper,
        ),
      ),
    );
    if (mounted) await _loadStations();
  }

  @override
  Widget build(BuildContext context) {
    final locationLabel = _location?.address?.trim();
    final results = _visibleStations;

    return Scaffold(
      backgroundColor: _stationCanvas,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _loadStations(),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'DISCOVER LOCAL WATER',
                        style: TextStyle(
                          color: primaryBlue,
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 5),
                      const Text(
                        'Water stations',
                        style: TextStyle(
                          color: _stationInk,
                          fontSize: 27,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -.7,
                        ),
                      ),
                      const SizedBox(height: 16),
                      _DeliveryLocationTile(
                        label: locationLabel?.isNotEmpty == true
                            ? locationLabel!
                            : _location?.latitude != null
                            ? 'Current map location'
                            : 'Choose a browsing location',
                        onTap: _changeLocation,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _searchController,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: 'Search station or area',
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            color: textGray,
                          ),
                          suffixIcon: _searchController.text.isEmpty
                              ? null
                              : IconButton(
                                  onPressed: _searchController.clear,
                                  tooltip: 'Clear search',
                                  icon: const Icon(Icons.close_rounded),
                                ),
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 15,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildFilterRow(),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 12),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    _loading
                        ? 'Finding stations…'
                        : '${results.length} nearby ${results.length == 1 ? 'station' : 'stations'}',
                    style: const TextStyle(
                      color: _stationInk,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                sliver: SliverToBoxAdapter(child: _buildResults(results)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One scrollable row: open-now filter, radius and sort together.
  Widget _buildFilterRow() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        _FilterChip(
          label: 'Open now',
          icon: Icons.circle,
          selected: _openNowOnly,
          onTap: () => setState(() => _openNowOnly = !_openNowOnly),
        ),
        const SizedBox(width: 8),
        if (_location?.latitude != null) ...[
          PopupMenuButton<double>(
            tooltip: 'Search radius',
            initialValue: _radiusKm,
            onSelected: (value) => _loadStations(radiusKm: value),
            itemBuilder: (context) => const [
              PopupMenuItem(value: 10, child: Text('Within 10 km')),
              PopupMenuItem(value: 25, child: Text('Within 25 km')),
            ],
            child: _MenuChip(
              icon: Icons.radar_rounded,
              label: 'Within ${_radiusKm.round()} km',
            ),
          ),
          const SizedBox(width: 8),
        ],
        PopupMenuButton<_StationSort>(
          tooltip: 'Sort stations',
          initialValue: _sort,
          onSelected: (value) => setState(() => _sort = value),
          itemBuilder: (context) => [
            for (final sort in _StationSort.values)
              PopupMenuItem(
                value: sort,
                child: Row(
                  children: [
                    Icon(sort.icon, size: 18),
                    const SizedBox(width: 10),
                    Text(sort.label),
                  ],
                ),
              ),
          ],
          child: _MenuChip(icon: _sort.icon, label: _sort.label),
        ),
      ],
    ),
  );

  Widget _buildResults(List<NearbyStation> results) {
    if (_location?.latitude == null || _location?.longitude == null) {
      return _EmptyPanel(
        icon: Icons.location_searching_rounded,
        title: 'Set a browsing location',
        message:
            'Use your current position to find nearby stations. You can add a delivery address later at checkout.',
        actionLabel: 'Set my location',
        onAction: _changeLocation,
      );
    }
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 60),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return _EmptyPanel(
        icon: Icons.cloud_off_rounded,
        title: 'Could not load stations',
        message: _error!,
        actionLabel: 'Try again',
        onAction: () => _loadStations(),
      );
    }
    if (_stations.isEmpty) {
      return NoStationsNearby(
        radiusKm: _radiusKm,
        onChangeLocation: _changeLocation,
        onExpandSearch: _radiusKm < NearbyConfig.expandedRadiusKm
            ? () => _loadStations(radiusKm: NearbyConfig.expandedRadiusKm)
            : null,
      );
    }
    if (results.isEmpty) {
      return _EmptyPanel(
        icon: Icons.manage_search_rounded,
        title: _openNowOnly ? 'No open stations match' : 'No matching stations',
        message: 'Try a different search term or clear the open-now filter.',
        actionLabel: 'Clear filters',
        onAction: () {
          _searchController.clear();
          setState(() => _openNowOnly = false);
        },
      );
    }

    return Column(
      children: [
        for (final station in results)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: _DirectoryStationCard(
              station: station,
              onTap: () => _openStation(station),
            ),
          ),
      ],
    );
  }
}

// ===========================================================================
// Storefront
// ===========================================================================

class _StationStorefront extends StatefulWidget {
  const _StationStorefront({
    required this.station,
    this.deliveryLocation,
    this.onCartChanged,
    required this.buildMainWrapper,
  });

  final NearbyStation station;
  final DeliveryLocation? deliveryLocation;
  final VoidCallback? onCartChanged;
  final Widget Function() buildMainWrapper;

  @override
  State<_StationStorefront> createState() => _StationStorefrontState();
}

class _StationStorefrontState extends State<_StationStorefront> {
  late Future<List<StationMarketplaceProduct>> _products = _fetchProducts();
  StationDeliveryInfo? _info;
  String? _contactPhone;
  String? _contactError;
  bool _loadingContact = true;
  double? _ratingAverage;
  late int _ratingCount;
  StationSocialLinks? _socialLinks;
  String? _socialLinksError;
  bool _loadingSocialLinks = true;
  OverlayEntry? _noticeEntry;
  Timer? _noticeTimer;
  Timer? _noticeRemoveTimer;

  @override
  void initState() {
    super.initState();
    _ratingAverage = widget.station.ratingAverage;
    _ratingCount = widget.station.ratingCount;
    _loadDeliveryInfo();
    _loadContactPhone();
    _loadSocialLinks();
  }

  Future<List<StationMarketplaceProduct>> _fetchProducts() =>
      SupabaseService.getStationProducts(widget.station.id);

  /// Delivery fee, minimum order, radius and hours. Optional: if it fails the
  /// storefront simply hides those details.
  Future<void> _loadDeliveryInfo() async {
    try {
      final info = await SupabaseService.getStationDeliveryInfo(
        widget.station.id,
      );
      if (mounted) setState(() => _info = info);
    } on Exception {
      // Non-critical; keep the storefront usable.
    }
  }

  Future<void> _loadContactPhone() async {
    if (mounted) {
      setState(() {
        _loadingContact = true;
        _contactError = null;
      });
    }
    try {
      final phone = await SupabaseService.getPublicStationPhone(
        widget.station.id,
      );
      if (!mounted) return;
      setState(() {
        _contactPhone = phone;
        _contactError = null;
        _loadingContact = false;
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        final details = error.toString();
        final missingRpc =
            details.contains('get_public_station_phone') ||
            details.contains('PGRST202') ||
            details.contains('42883');
        _contactError = missingRpc
            ? 'Contact lookup is not set up in Supabase. Apply '
                  '20261016110000_public_station_contact_phone.sql, then retry.'
            : 'Could not load the contact number. $details';
        _loadingContact = false;
      });
    }
  }

  Future<void> _callStation() async {
    final phone = _contactPhone;
    if (phone == null) return;
    final launched = await launchUrl(Uri(scheme: 'tel', path: phone));
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the phone dialer.')),
      );
    }
  }

  Future<void> _loadSocialLinks() async {
    if (mounted) {
      setState(() {
        _loadingSocialLinks = true;
        _socialLinksError = null;
      });
    }
    try {
      final links = await SupabaseService.getPublicStationSocialLinks(
        widget.station.id,
      );
      if (!mounted) return;
      setState(() {
        _socialLinks = links;
        _socialLinksError = null;
        _loadingSocialLinks = false;
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _socialLinksError = error.toString();
        _loadingSocialLinks = false;
      });
    }
  }

  Future<void> _openSocialLink(String value) async {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const FormatException('The station social link is invalid.');
    }
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open the station social page.'),
        ),
      );
    }
  }

  /// Replaces the future so "Reload" and pull-to-refresh really refetch.
  Future<void> _reload() async {
    final next = _fetchProducts();
    setState(() => _products = next);
    unawaited(_loadDeliveryInfo());
    try {
      await next;
    } on Exception {
      // The FutureBuilder shows the error state.
    }
  }

  Map<String, List<StationMarketplaceProduct>> _groupByWater(
    List<StationMarketplaceProduct> items,
  ) {
    final map = <String, List<StationMarketplaceProduct>>{};
    for (final product in items) {
      (map[product.waterType] ??= []).add(product);
    }
    for (final list in map.values) {
      list.sort(
        (a, b) => (b.containerVolumeLiters ?? 0).compareTo(
          a.containerVolumeLiters ?? 0,
        ),
      );
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final station = widget.station;
    final area = [
      if (station.barangay?.trim().isNotEmpty == true) station.barangay!,
      if (station.city?.trim().isNotEmpty == true) station.city!,
      if (station.province?.trim().isNotEmpty == true) station.province!,
    ].join(', ');
    final imageUrl = _publicImageUrl(station.logoPath);
    final hoursLabel = _info?.hoursLabel(
      DateTime.now(),
      isOpen: station.isOpen,
    );

    return Scaffold(
      backgroundColor: _stationCanvas,
      body: RefreshIndicator(
        onRefresh: _reload,
        edgeOffset: 90,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar(
              expandedHeight: 230,
              pinned: true,
              backgroundColor: primaryBlue,
              foregroundColor: Colors.white,
              title: Text(
                station.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              flexibleSpace: FlexibleSpaceBar(
                background: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (imageUrl == null)
                      const _StationPhotoPlaceholder()
                    else
                      Image.network(
                        imageUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) =>
                            const _StationPhotoPlaceholder(),
                      ),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black26,
                            Colors.transparent,
                            Color(0xAA061D3B),
                          ],
                          stops: [0, .38, 1],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 20,
                      right: 20,
                      bottom: 22,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              station.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 24,
                                height: 1.05,
                                fontWeight: FontWeight.w900,
                                shadows: [
                                  Shadow(color: Colors.black26, blurRadius: 10),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          _StatusPill(
                            label: station.isOpen ? 'OPEN NOW' : 'CLOSED',
                            isOpen: station.isOpen,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(18, 17, 18, 30),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  if (!station.isOpen) ...[
                    _StationBanner(
                      icon: Icons.schedule_rounded,
                      tone: _BannerTone.neutral,
                      text: hoursLabel != null
                          ? 'Closed right now. $hoursLabel.'
                          : 'This station is closed right now. You can still browse its prices.',
                    ),
                    const SizedBox(height: 12),
                  ],
                  _StorefrontSummary(
                    station: station,
                    info: _info,
                    ratingAverage: _ratingAverage,
                    ratingCount: _ratingCount,
                    area: area,
                  ),
                  const SizedBox(height: 12),
                  _StationRatingCard(
                    stationId: station.id,
                    onRatingSaved: (summary) {
                      if (!mounted || summary == null) return;
                      setState(() {
                        _ratingAverage = summary.average;
                        _ratingCount = summary.count;
                      });
                    },
                  ),
                  const SizedBox(height: 18),
                  _StationContactCard(
                    phone: _contactPhone,
                    error: _contactError,
                    loading: _loadingContact,
                    onCall: _callStation,
                    onRetry: _loadContactPhone,
                  ),
                  const SizedBox(height: 18),
                  _StationSocialLinksCard(
                    links: _socialLinks,
                    error: _socialLinksError,
                    loading: _loadingSocialLinks,
                    onRetry: _loadSocialLinks,
                    onOpen: _openSocialLink,
                  ),
                  if (_socialLinks != null || _socialLinksError != null) ...[
                    const SizedBox(height: 18),
                  ],
                  const _SectionHeading(
                    title: 'About this station',
                    subtitle: 'A little more about your local water provider',
                  ),
                  const SizedBox(height: 9),
                  _SurfaceCard(
                    child: Text(
                      station.description?.trim().isNotEmpty == true
                          ? station.description!
                          : 'This local station serves customers in your delivery area.',
                      style: const TextStyle(
                        color: textDark,
                        fontSize: 13,
                        height: 1.55,
                      ),
                    ),
                  ),
                  const SizedBox(height: 21),
                  Row(
                    children: [
                      const Expanded(
                        child: _SectionHeading(
                          title: 'Water & gallon prices',
                          subtitle: 'Choose your water type, size, and option',
                        ),
                      ),
                      FutureBuilder<List<StationMarketplaceProduct>>(
                        future: _products,
                        builder: (context, snapshot) {
                          final data = snapshot.data;
                          if (data == null) return const SizedBox.shrink();
                          final types = _groupByWater(data).length;
                          return _CountPill(
                            label: '$types ${types == 1 ? 'type' : 'types'}',
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 11),
                  FutureBuilder<List<StationMarketplaceProduct>>(
                    future: _products,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const _LoadingProducts();
                      }
                      if (snapshot.hasError) {
                        return _EmptyPanel(
                          icon: Icons.wifi_off_rounded,
                          title: 'Products unavailable',
                          message:
                              'We couldn’t load this station’s catalog. Please try again.',
                          actionLabel: 'Reload',
                          onAction: _reload,
                        );
                      }
                      final products = snapshot.data ?? const [];
                      if (products.isEmpty) {
                        return const _EmptyPanel(
                          icon: Icons.inventory_2_outlined,
                          title: 'No active products yet',
                          message:
                              'This station has not listed any products for customers yet.',
                        );
                      }
                      final groups = _groupByWater(products);
                      return Column(
                        children: [
                          for (final entry in groups.entries)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: _WaterTypeCard(
                                waterType: entry.key,
                                products: entry.value,
                                onSelect: _showProduct,
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  if (widget.deliveryLocation?.address?.trim().isNotEmpty ==
                      true) ...[
                    const SizedBox(height: 8),
                    _DeliveryHint(
                      address: widget.deliveryLocation!.address!.trim(),
                      distanceKm: station.distanceKm,
                      isOpen: station.isOpen,
                    ),
                  ],
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _noticeTimer?.cancel();
    _noticeRemoveTimer?.cancel();
    _noticeEntry?.remove();
    _noticeEntry = null;
    super.dispose();
  }

  void _showCartNotice({required String waterType, required int quantity}) {
    _showTopNotice(
      onTap: _openQrCheckout,
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.check_rounded,
              color: Colors.white,
              size: 23,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Added to your cart',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '×$quantity $waterType',
                  style: const TextStyle(
                    color: Color(0xFFD9E9F9),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 3),
                const Text(
                  'Tap to continue to QR checkout',
                  style: TextStyle(
                    color: Color(0xFFB9D5F0),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const Icon(
            Icons.shopping_cart_rounded,
            color: Colors.white,
            size: 21,
          ),
        ],
      ),
    );
  }

  void _showClosedStationNotice() {
    _showTopNotice(
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.schedule_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'This station is closed',
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showAddToCartError(String message) {
    _showTopNotice(
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.error_outline_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Could not add to cart',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  message,
                  style: const TextStyle(
                    color: Color(0xFFD9E9F9),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openQrCheckout() async {
    _noticeTimer?.cancel();
    _noticeRemoveTimer?.cancel();
    _noticeEntry?.remove();
    _noticeEntry = null;

    try {
      final cart = await SupabaseService.getActiveCart();
      if (!mounted) return;
      if (cart == null || cart.items.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Your cart is empty.')));
        return;
      }
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) =>
              /*qr_checkout.*/ CartScreen(
                buildMainWrapper: widget.buildMainWrapper,
              ),
        ),
      );
      widget.onCartChanged?.call();
    } on Exception catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('Could not open QR checkout: $error')),
        );
    }
  }

  void _showTopNotice({required Widget child, VoidCallback? onTap}) {
    _noticeTimer?.cancel();
    _noticeRemoveTimer?.cancel();
    _noticeEntry?.remove();
    _noticeEntry = null;

    final overlay = Overlay.of(context, rootOverlay: true);
    var isVisible = false;
    late final OverlayEntry entry;

    entry = OverlayEntry(
      builder: (overlayContext) {
        final topInset = MediaQuery.of(overlayContext).padding.top;
        return Positioned(
          top: topInset + 8,
          left: 16,
          right: 16,
          child: SafeArea(
            bottom: false,
            child: AnimatedSlide(
              offset: isVisible ? Offset.zero : const Offset(0, -1.5),
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: isVisible ? 1 : 0,
                duration: const Duration(milliseconds: 250),
                child: Material(
                  color: Colors.transparent,
                  child: Ink(
                    decoration: BoxDecoration(
                      color: const Color(0xFF123A63),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(.16),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: InkWell(
                      onTap: onTap,
                      borderRadius: BorderRadius.circular(16),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        child: child,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    _noticeEntry = entry;
    overlay.insert(entry);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _noticeEntry != entry) return;
      isVisible = true;
      entry.markNeedsBuild();
      _noticeTimer = Timer(const Duration(milliseconds: 300), () {
        _noticeTimer = Timer(const Duration(seconds: 3), () {
          if (!mounted || _noticeEntry != entry) return;
          isVisible = false;
          entry.markNeedsBuild();
          _noticeRemoveTimer = Timer(const Duration(milliseconds: 300), () {
            if (_noticeEntry == entry) {
              entry.remove();
              _noticeEntry = null;
            }
          });
        });
      });
    });
  }

  void _showProduct(StationMarketplaceProduct product, String option) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      builder: (context) => _ProductQuickView(
        product: product,
        station: widget.station,
        info: _info,
        containerOption: option,
        onCartChanged: widget.onCartChanged,
        onStationClosed: _showClosedStationNotice,
        onAddError: _showAddToCartError,
        onItemAdded: (waterType, quantity) =>
            _showCartNotice(waterType: waterType, quantity: quantity),
      ),
    );
  }
}

class _StationRatingCard extends StatefulWidget {
  const _StationRatingCard({
    required this.stationId,
    required this.onRatingSaved,
  });

  final String stationId;
  final ValueChanged<({double? average, int count})?> onRatingSaved;

  @override
  State<_StationRatingCard> createState() => _StationRatingCardState();
}

class _StationRatingCardState extends State<_StationRatingCard> {
  ({String orderId, int? rating})? _target;
  int? _selectedRating;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadTarget();
  }

  Future<void> _loadTarget() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final target = await SupabaseService.getStationRatingTarget(
        widget.stationId,
      );
      if (!mounted) return;
      setState(() {
        _target = target;
        _selectedRating = target?.rating;
        _loading = false;
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _submitRating() async {
    final target = _target;
    final rating = _selectedRating;
    if (target == null || rating == null || _saving) return;

    setState(() => _saving = true);
    try {
      await SupabaseService.saveStationRating(
        orderId: target.orderId,
        stationId: widget.stationId,
        rating: rating,
      );
      if (!mounted) return;
      setState(() {
        _target = (orderId: target.orderId, rating: rating);
        _saving = false;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Your station rating was saved.')),
        );
      try {
        final summary = await SupabaseService.getPublicStationRatingSummary(
          widget.stationId,
        );
        if (mounted) widget.onRatingSaved(summary);
      } on Exception catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                'Your rating was saved, but the station total could not refresh: $error',
              ),
            ),
          );
      }
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('Could not save your rating: $error')),
        );
    }
  }

  @override
  Widget build(BuildContext context) => _SurfaceCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Rate this station',
          style: TextStyle(
            color: _stationInk,
            fontSize: 15,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 5),
        if (_loading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(8),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (_error != null)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Your rating option could not be loaded: $_error',
                style: const TextStyle(
                  color: _danger,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              TextButton(
                onPressed: _loadTarget,
                child: const Text('Try again'),
              ),
            ],
          )
        else if (_target == null)
          const Text(
            'Complete a delivery from this station to rate it.',
            style: TextStyle(color: textGray, fontSize: 12, height: 1.4),
          )
        else ...[
          Text(
            _target!.rating == null
                ? 'How was your latest delivery?'
                : 'Your rating for your latest delivery',
            style: const TextStyle(color: textGray, fontSize: 12),
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              for (var value = 1; value <= 5; value++)
                IconButton(
                  tooltip: '$value ${value == 1 ? 'star' : 'stars'}',
                  visualDensity: VisualDensity.compact,
                  onPressed: _saving
                      ? null
                      : () => setState(() => _selectedRating = value),
                  icon: Icon(
                    value <= (_selectedRating ?? 0)
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                    color: warning,
                    size: 29,
                  ),
                ),
              if (_selectedRating != null)
                Text(
                  '$_selectedRating/5',
                  style: const TextStyle(
                    color: _stationInk,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 5),
          FilledButton(
            onPressed: _selectedRating == null || _saving
                ? null
                : _submitRating,
            style: FilledButton.styleFrom(backgroundColor: primaryBlue),
            child: _saving
                ? const SizedBox(
                    width: 17,
                    height: 17,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(
                    _target!.rating == null ? 'Submit rating' : 'Update rating',
                  ),
          ),
        ],
      ],
    ),
  );
}

class _StorefrontSummary extends StatelessWidget {
  const _StorefrontSummary({
    required this.station,
    required this.info,
    required this.ratingAverage,
    required this.ratingCount,
    required this.area,
  });

  final NearbyStation station;
  final StationDeliveryInfo? info;
  final double? ratingAverage;
  final int ratingCount;
  final String area;

  @override
  Widget build(BuildContext context) {
    final fee = info?.deliveryFee;
    final minimum = info?.minimumOrderAmount;
    final radius = info?.serviceRadiusKm;
    final hours = info?.hoursLabel(DateTime.now(), isOpen: station.isOpen);
    final hasDeliveryInfo =
        fee != null || minimum != null || radius != null || hours != null;
    final hasRating = ratingCount > 0 && ratingAverage != null;

    return _SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  area.isEmpty ? 'Nearby water station' : area,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: textGray,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (ratingCount == 0)
                const _NewStationPill()
              else if (hasRating)
                Row(
                  children: [
                    const Icon(Icons.star_rounded, color: warning, size: 17),
                    const SizedBox(width: 3),
                    Text(
                      '${ratingAverage!.toStringAsFixed(1)} ($ratingCount)',
                      style: const TextStyle(
                        color: _stationInk,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _Metric(
                  icon: Icons.near_me_rounded,
                  value: formatDistance(station.distanceKm),
                  label: 'From you',
                ),
              ),
              const _MetricDivider(),
              Expanded(
                child: _Metric(
                  icon: Icons.local_drink_rounded,
                  value: '₱${station.startingPrice.toStringAsFixed(0)}',
                  label: 'Refill from',
                ),
              ),
              if (station.estimatedDeliveryMinutes != null) ...[
                const _MetricDivider(),
                Expanded(
                  child: _Metric(
                    icon: Icons.schedule_rounded,
                    value: '${station.estimatedDeliveryMinutes} min',
                    label: 'Est. delivery',
                  ),
                ),
              ],
            ],
          ),
          if (hasDeliveryInfo) ...[
            const SizedBox(height: 14),
            const Divider(height: 1, color: borderColor),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (fee != null)
                  _InfoChip(
                    icon: Icons.local_shipping_outlined,
                    text: fee == 0
                        ? 'Base delivery free'
                        : 'Base fee ₱${fee.toStringAsFixed(0)}',
                  ),
                if (minimum != null)
                  _InfoChip(
                    icon: Icons.shopping_basket_outlined,
                    text: minimum > 0
                        ? 'Min. order ₱${minimum.toStringAsFixed(0)}'
                        : 'No minimum order',
                  ),
                if (radius != null)
                  _InfoChip(
                    icon: Icons.radar_rounded,
                    text:
                        'Delivers within ${radius.toStringAsFixed(radius % 1 == 0 ? 0 : 1)} km',
                  ),
                if (hours != null)
                  _InfoChip(icon: Icons.access_time_rounded, text: hours),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StationContactCard extends StatelessWidget {
  const _StationContactCard({
    required this.phone,
    required this.error,
    required this.loading,
    required this.onCall,
    required this.onRetry,
  });

  final String? phone;
  final String? error;
  final bool loading;
  final VoidCallback onCall;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => _SurfaceCard(
    child: Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: lightBlue,
            borderRadius: BorderRadius.circular(13),
          ),
          child: const Icon(
            Icons.support_agent_rounded,
            color: primaryBlue,
            size: 22,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Contact station',
                style: TextStyle(
                  color: _stationInk,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                error != null
                    ? error!
                    : phone ??
                          (loading
                              ? 'Loading station contact…'
                              : 'Contact number unavailable'),
                style: TextStyle(
                  color: error != null ? _danger : textGray,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        if (error != null)
          TextButton(onPressed: onRetry, child: const Text('Retry'))
        else if (phone != null)
          IconButton(
            onPressed: onCall,
            tooltip: 'Call station',
            style: IconButton.styleFrom(
              foregroundColor: primaryBlue,
              backgroundColor: lightBlue,
            ),
            icon: const Icon(Icons.call_rounded),
          )
        else if (loading)
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    ),
  );
}

class _StationSocialLinksCard extends StatelessWidget {
  const _StationSocialLinksCard({
    required this.links,
    required this.error,
    required this.loading,
    required this.onRetry,
    required this.onOpen,
  });

  final StationSocialLinks? links;
  final String? error;
  final bool loading;
  final VoidCallback onRetry;
  final Future<void> Function(String url) onOpen;

  @override
  Widget build(BuildContext context) {
    final facebookUrl = links?.facebookUrl;
    final instagramUrl = links?.instagramUrl;
    if (!loading &&
        error == null &&
        facebookUrl == null &&
        instagramUrl == null) {
      return const SizedBox.shrink();
    }

    return _SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Follow this station',
            style: TextStyle(
              color: _stationInk,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (loading) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ] else if (error != null) ...[
            const SizedBox(height: 5),
            const Text(
              'Could not load station socials.',
              style: TextStyle(color: textGray, fontSize: 12),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: onRetry, child: const Text('Retry')),
            ),
          ] else ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (facebookUrl != null)
                  OutlinedButton.icon(
                    onPressed: () => onOpen(facebookUrl),
                    icon: const Icon(Icons.facebook_rounded, size: 18),
                    label: const Text('Facebook'),
                  ),
                if (instagramUrl != null)
                  OutlinedButton.icon(
                    onPressed: () => onOpen(instagramUrl),
                    icon: const Icon(Icons.camera_alt_rounded, size: 18),
                    label: const Text('Instagram'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ===========================================================================
// Catalog: water type -> gallon sizes, mirroring the seller portal
// ===========================================================================

class _WaterTypeCard extends StatelessWidget {
  const _WaterTypeCard({
    required this.waterType,
    required this.products,
    required this.onSelect,
  });

  final String waterType;
  final List<StationMarketplaceProduct> products;
  final void Function(StationMarketplaceProduct product, String option)
  onSelect;

  @override
  Widget build(BuildContext context) => _SurfaceCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: const BoxDecoration(
                color: lightBlue,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.water_drop_rounded,
                color: primaryBlue,
                size: 18,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                waterType,
                style: const TextStyle(
                  color: _stationInk,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < products.length; i++) ...[
          if (i > 0) const Divider(height: 22, color: borderColor),
          _SizeRow(
            product: products[i],
            onSelect: (option) => onSelect(products[i], option),
          ),
        ],
      ],
    ),
  );
}

class _SizeRow extends StatelessWidget {
  const _SizeRow({required this.product, required this.onSelect});

  final StationMarketplaceProduct product;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final level = _stockLevel(product);
    final out = level == _StockLevel.out;
    final canRefill = product.refillAvailable;
    final canBuyNew = product.newContainerAvailable;

    return Opacity(
      opacity: out ? .65 : 1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  _gallonSizeLabel(product),
                  style: const TextStyle(
                    color: _stationInk,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.2,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _StockBadge(level: level, quantity: product.stockQuantity),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (canRefill)
                Expanded(
                  child: _PriceButton(
                    label: 'Refill',
                    price: _productOptionPrice(product, 'refill_existing'),
                    onTap: out ? null : () => onSelect('refill_existing'),
                  ),
                ),
              if (canRefill && canBuyNew) const SizedBox(width: 10),
              if (canBuyNew)
                Expanded(
                  child: _PriceButton(
                    label: 'New gallon',
                    price: _productOptionPrice(product, 'new_gallon'),
                    onTap: out ? null : () => onSelect('new_gallon'),
                  ),
                ),
            ],
          ),
          if (!canBuyNew && canRefill) ...[
            const SizedBox(height: 7),
            const Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 13, color: textGray),
                SizedBox(width: 5),
                Text(
                  'New gallon not available for this size',
                  style: TextStyle(color: textGray, fontSize: 11),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _PriceButton extends StatelessWidget {
  const _PriceButton({required this.label, required this.price, this.onTap});

  final String label;
  final double price;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      label: '$label, ${price.toStringAsFixed(2)} pesos',
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 72),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          alignment: Alignment.centerLeft,
          side: BorderSide(
            color: enabled ? const Color(0xFF8FA8C3) : borderColor,
          ),
          backgroundColor: enabled
              ? const Color(0xFFEAF0F7)
              : const Color(0xFFF5F7FA),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(13),
          ),
          tapTargetSize: MaterialTapTargetSize.padded,
          visualDensity: VisualDensity.standard,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _stationInk,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '₱${price.toStringAsFixed(0)}',
                      style: const TextStyle(
                        color: Color(0xFF102A43),
                        fontSize: 21,
                        height: 1.1,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 3),
            Icon(
              Icons.chevron_right_rounded,
              size: 17,
              color: enabled ? _stationInk : textGray,
            ),
          ],
        ),
      ),
    );
  }
}

class _StockBadge extends StatelessWidget {
  const _StockBadge({required this.level, this.quantity});

  final _StockLevel level;
  final int? quantity;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (level) {
      _StockLevel.out => ('Out of stock', _danger),
      _StockLevel.low => ('Only $quantity left', warning),
      _ => ('', Colors.transparent),
    };
    if (text.isEmpty) return const SizedBox.shrink();
    return Text(
      text,
      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800),
    );
  }
}

double _productOptionPrice(StationMarketplaceProduct product, String option) =>
    option == 'refill_existing'
    ? product.refillPrice
    : product.refillPrice +
          (product.newContainerPrice ?? 0) +
          product.depositAmount;

String _gallonSizeLabel(StationMarketplaceProduct product) {
  final liters = product.containerVolumeLiters;
  if (liters != null && (liters - 18.9).abs() < 0.2) {
    return 'Regular (18.9 L)';
  }
  if (liters != null && (liters - 11.3).abs() < 0.2) {
    return 'Slim (11.3 L)';
  }
  return liters == null
      ? product.containerType
      : '${product.containerType} (${liters.toStringAsFixed(1)} L)';
}

// ===========================================================================
// Product quick view
// ===========================================================================

class _ProductQuickView extends StatefulWidget {
  const _ProductQuickView({
    required this.product,
    required this.station,
    required this.info,
    required this.containerOption,
    required this.onStationClosed,
    required this.onAddError,
    this.onCartChanged,
    this.onItemAdded,
  });

  final StationMarketplaceProduct product;
  final NearbyStation station;
  final StationDeliveryInfo? info;
  final String containerOption;
  final VoidCallback onStationClosed;
  final ValueChanged<String> onAddError;
  final VoidCallback? onCartChanged;
  final void Function(String waterType, int quantity)? onItemAdded;

  @override
  State<_ProductQuickView> createState() => _ProductQuickViewState();
}

class _ProductQuickViewState extends State<_ProductQuickView> {
  int _quantity = 1;
  bool _adding = false;

  bool get _isRefill => widget.containerOption == 'refill_existing';

  int get _maxQuantity {
    final product = widget.product;
    final stock = product.stockQuantity;
    if (stock == null || stock > product.maxOrderQuantity) {
      return product.maxOrderQuantity;
    }
    return stock;
  }

  /// Explains why the stepper stops, so a disabled "+" is never a mystery.
  String get _quantityHint {
    final product = widget.product;
    final stock = product.stockQuantity;
    if (stock != null && stock == 0) return 'Out of stock';
    if (stock != null && stock < product.maxOrderQuantity) {
      return 'Only $stock in stock';
    }
    return 'Max ${product.maxOrderQuantity} per order';
  }

  double get _unitPrice =>
      _productOptionPrice(widget.product, widget.containerOption);

  double get _total => _unitPrice * _quantity;

  @override
  Widget build(BuildContext context) {
    final product = widget.product;
    final station = widget.station;
    final deliveryFee = widget.info?.deliveryFee;
    final radius = widget.info?.serviceRadiusKm;
    final outsideRadius = radius != null && station.distanceKm > radius;
    final minimum = widget.info?.minimumOrderAmount;
    final belowMinimum = minimum != null && minimum > 0 && _total < minimum;
    final maxHeight = MediaQuery.sizeOf(context).height * .92;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ProductGallery(
                paths: [for (final image in product.images) image.storagePath],
              ),
              const SizedBox(height: 17),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      product.waterType,
                      style: const TextStyle(
                        color: _stationInk,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  _CountPill(label: _isRefill ? 'Refill' : 'New gallon'),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                _gallonSizeLabel(product),
                style: const TextStyle(
                  color: textGray,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (product.description?.trim().isNotEmpty == true) ...[
                const SizedBox(height: 13),
                Text(
                  product.description!,
                  style: const TextStyle(
                    color: textDark,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              if (_isRefill)
                _RefillNotice(product: product)
              else
                _PriceBreakdown(product: product),
              if (!station.isOpen) ...[
                const SizedBox(height: 12),
                const _StationBanner(
                  icon: Icons.schedule_rounded,
                  tone: _BannerTone.neutral,
                  text:
                      'This station is closed now. Your order may be '
                      'handled when it opens.',
                ),
              ],
              if (outsideRadius) ...[
                const SizedBox(height: 12),
                _StationBanner(
                  icon: Icons.warning_amber_rounded,
                  tone: _BannerTone.warning,
                  text:
                      'You look to be ${formatDistance(station.distanceKm)} away, '
                      'outside this station’s ${radius.toStringAsFixed(radius % 1 == 0 ? 0 : 1)} km delivery range. '
                      'Check your delivery address at checkout.',
                ),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Quantity',
                        style: TextStyle(
                          color: _stationInk,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _quantityHint,
                        style: TextStyle(
                          color: () {
                            final stock = product.stockQuantity;
                            return stock == 0 ||
                                    (stock != null &&
                                        stock <= _lowStockThreshold)
                                ? _danger
                                : textGray;
                          }(),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Decrease quantity',
                        onPressed: _quantity > 1
                            ? () => setState(() => _quantity--)
                            : null,
                        icon: const Icon(Icons.remove_circle_outline_rounded),
                      ),
                      SizedBox(
                        width: 28,
                        child: Text(
                          '$_quantity',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: _stationInk,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Increase quantity',
                        onPressed: _quantity < _maxQuantity
                            ? () => setState(() => _quantity++)
                            : null,
                        icon: const Icon(Icons.add_circle_outline_rounded),
                      ),
                    ],
                  ),
                ],
              ),
              if (belowMinimum) ...[
                const SizedBox(height: 6),
                Text(
                  'Add ₱${(minimum - _total).toStringAsFixed(0)} more to reach '
                  'this station’s ₱${minimum.toStringAsFixed(0)} minimum order.',
                  style: const TextStyle(
                    color: warning,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed: _adding || _maxQuantity == 0
                      ? null
                      : station.isOpen
                      ? _addToCart
                      : widget.onStationClosed,
                  style: FilledButton.styleFrom(
                    backgroundColor: primaryBlue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),
                  icon: _adding
                      ? const SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.add_shopping_cart_rounded, size: 18),
                  label: Text(
                    _maxQuantity == 0
                        ? 'Out of stock'
                        : _adding
                        ? 'Adding to cart…'
                        : !station.isOpen
                        ? 'Station closed'
                        : 'Add to cart · ₱${_total.toStringAsFixed(2)}',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  deliveryFee == null
                      ? 'Delivery fee will be confirmed when you place your order.'
                      : 'Base delivery fee: ${deliveryFee == 0 ? 'Free' : '₱${deliveryFee.toStringAsFixed(2)}'} · may vary by delivery area.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: textGray,
                    fontSize: 11,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _addToCart() async {
    if (!widget.station.isOpen) {
      widget.onStationClosed();
      return;
    }
    setState(() => _adding = true);
    try {
      await SupabaseService.addToCart(
        stationId: widget.station.id,
        productId: widget.product.id,
        containerOption: widget.containerOption,
        quantity: _quantity,
      );
      if (!mounted) return;
      widget.onCartChanged?.call();
      final waterType =
          '${widget.product.waterType} · ${_isRefill ? 'Refill' : 'New gallon'}';
      final quantity = _quantity;
      final onItemAdded = widget.onItemAdded;
      Navigator.of(context).pop();
      onItemAdded?.call(waterType, quantity);
    } on Exception catch (error) {
      if (!mounted) return;
      final details = error.toString();
      final message =
          details.contains('Your cart already has items from another station')
          ? 'Your cart has items from another station. Clear it before shopping here.'
          : 'Could not add this item: ${details.replaceFirst(RegExp(r'^Exception: ?'), '')}';
      widget.onAddError(message);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }
}

/// Swipeable gallery for up to 5 seller photos, with dot indicators.
class _ProductGallery extends StatefulWidget {
  const _ProductGallery({required this.paths});

  final List<String> paths;

  @override
  State<_ProductGallery> createState() => _ProductGalleryState();
}

class _ProductGalleryState extends State<_ProductGallery> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final urls = widget.paths
        .map(_publicImageUrl)
        .whereType<String>()
        .toList(growable: false);
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        width: double.infinity,
        height: 190,
        child: urls.isEmpty
            ? const _ProductPhotoPlaceholder()
            : Stack(
                fit: StackFit.expand,
                children: [
                  PageView.builder(
                    itemCount: urls.length,
                    onPageChanged: (value) => setState(() => _page = value),
                    itemBuilder: (context, index) => Image.network(
                      urls[index],
                      fit: BoxFit.cover,
                      loadingBuilder: (context, child, progress) =>
                          progress == null
                          ? child
                          : const ColoredBox(color: lightBlue),
                      errorBuilder: (context, error, stackTrace) =>
                          const _ProductPhotoPlaceholder(),
                    ),
                  ),
                  if (urls.length > 1)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 10,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (var i = 0; i < urls.length; i++)
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              margin: const EdgeInsets.symmetric(horizontal: 3),
                              width: i == _page ? 18 : 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: i == _page
                                    ? Colors.white
                                    : Colors.white54,
                                borderRadius: BorderRadius.circular(8),
                              ),
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

/// Same formula the seller sees as "Customer total".
class _PriceBreakdown extends StatelessWidget {
  const _PriceBreakdown({required this.product});

  final StationMarketplaceProduct product;

  @override
  Widget build(BuildContext context) {
    Widget line(String label, double value, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: bold ? _stationInk : textGray,
                fontSize: bold ? 14 : 13,
                fontWeight: bold ? FontWeight.w900 : FontWeight.w600,
              ),
            ),
          ),
          Text(
            '₱${value.toStringAsFixed(2)}',
            style: TextStyle(
              color: _stationInk,
              fontSize: bold ? 17 : 13,
              fontWeight: bold ? FontWeight.w900 : FontWeight.w700,
            ),
          ),
        ],
      ),
    );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF0F7),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFB8C7D8)),
      ),
      child: Column(
        children: [
          line('Water refill', product.refillPrice),
          line('New gallon container', product.newContainerPrice ?? 0),
          if (product.depositAmount > 0)
            line('Refundable deposit', product.depositAmount),
          const Divider(height: 14, color: borderColor),
          line(
            'Per gallon',
            _productOptionPrice(product, 'new_gallon'),
            bold: true,
          ),
        ],
      ),
    );
  }
}

/// Real return policy from the seller instead of a generic pickup message.
class _RefillNotice extends StatelessWidget {
  const _RefillNotice({required this.product});

  final StationMarketplaceProduct product;

  @override
  Widget build(BuildContext context) {
    final instructions = product.returnPolicy?.trim();
    final text = instructions != null && instructions.isNotEmpty
        ? instructions
        : product.requiresEmptyContainer
        ? 'Have your empty gallon ready to hand to the rider on delivery.'
        : 'Your empty gallon is optional for this refill.';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF0F7),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFB8C7D8)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, color: _stationInk, size: 20),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Refill: ₱${product.refillPrice.toStringAsFixed(2)} per gallon',
                  style: const TextStyle(
                    color: _stationInk,
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  text,
                  style: const TextStyle(
                    color: _stationInk,
                    fontSize: 13,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// Shared widgets
// ===========================================================================

class _DirectoryStationCard extends StatelessWidget {
  const _DirectoryStationCard({required this.station, required this.onTap});

  final NearbyStation station;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final imageUrl = _publicImageUrl(station.logoPath);
    final area = [
      if (station.barangay?.trim().isNotEmpty == true) station.barangay!,
      if (station.city?.trim().isNotEmpty == true) station.city!,
      if (station.province?.trim().isNotEmpty == true) station.province!,
    ].join(', ');
    final hasRating = station.ratingCount > 0 && station.ratingAverage != null;

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: borderColor),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF193B69).withValues(alpha: .035),
                blurRadius: 16,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  width: 92,
                  height: 112,
                  child: imageUrl == null
                      ? const _StationPhotoPlaceholder()
                      : Image.network(
                          imageUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              const _StationPhotoPlaceholder(),
                        ),
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            station.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _stationInk,
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        const SizedBox(width: 5),
                        if (station.ratingCount == 0)
                          const _NewStationPill()
                        else if (hasRating) ...[
                          const Icon(
                            Icons.star_rounded,
                            color: warning,
                            size: 15,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            station.ratingAverage!.toStringAsFixed(1),
                            style: const TextStyle(
                              color: _stationInk,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (area.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        area,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: textGray, fontSize: 11),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      station.description?.trim().isNotEmpty == true
                          ? station.description!
                          : 'A nearby water station serving your area.',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: textGray,
                        fontSize: 11,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _StatusDot(isOpen: station.isOpen),
                        const SizedBox(width: 5),
                        Text(
                          station.isOpen ? 'Open' : 'Closed',
                          style: TextStyle(
                            color: station.isOpen ? success : textGray,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(
                          Icons.near_me_rounded,
                          size: 12,
                          color: textGray,
                        ),
                        const SizedBox(width: 3),
                        Expanded(
                          child: Text(
                            formatDistance(station.distanceKm),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: textGray,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      'Refill from ₱${station.startingPrice.toStringAsFixed(0)}',
                      style: const TextStyle(
                        color: primaryBlue,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (hasRating) ...[
                      const SizedBox(height: 3),
                      Text(
                        '${station.ratingCount} ${station.ratingCount == 1 ? 'rating' : 'ratings'}',
                        style: const TextStyle(
                          color: textGray,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              const Icon(
                Icons.chevron_right_rounded,
                color: textGray,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeliveryHint extends StatelessWidget {
  const _DeliveryHint({
    required this.address,
    required this.distanceKm,
    required this.isOpen,
  });

  final String address;
  final double distanceKm;
  final bool isOpen;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(17),
      border: Border.all(color: borderColor),
    ),
    child: Row(
      children: [
        const Icon(Icons.local_shipping_outlined, color: primaryBlue, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Your delivery location',
                style: TextStyle(
                  color: _stationInk,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                address,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: textGray, fontSize: 11),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          isOpen ? formatDistance(distanceKm) : 'Closed',
          style: TextStyle(
            color: isOpen ? primaryBlue : textGray,
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );
}

class _DeliveryLocationTile extends StatelessWidget {
  const _DeliveryLocationTile({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(16),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: const BoxDecoration(
                color: lightBlue,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.location_on_rounded,
                color: primaryBlue,
                size: 19,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'DELIVER TO',
                    style: TextStyle(
                      color: textGray,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: .8,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _stationInk,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            const Icon(
              Icons.keyboard_arrow_down_rounded,
              color: textGray,
              size: 20,
            ),
          ],
        ),
      ),
    ),
  );
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? lightBlue : Colors.white,
    borderRadius: BorderRadius.circular(14),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? primaryBlue : borderColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 9, color: selected ? success : textGray),
              const SizedBox(width: 7),
            ],
            Text(
              label,
              style: TextStyle(
                color: selected ? primaryBlue : textGray,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Visual shell for the popup-menu triggers (radius, sort).
class _MenuChip extends StatelessWidget {
  const _MenuChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    height: 42,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: borderColor),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: primaryBlue),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            color: _stationInk,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(width: 3),
        const Icon(Icons.expand_more_rounded, size: 17, color: textGray),
      ],
    ),
  );
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: _stationCanvas,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: primaryBlue),
        const SizedBox(width: 6),
        Text(
          text,
          style: const TextStyle(
            color: _stationInk,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

enum _BannerTone { neutral, warning }

class _StationBanner extends StatelessWidget {
  const _StationBanner({
    required this.icon,
    required this.text,
    required this.tone,
  });

  final IconData icon;
  final String text;
  final _BannerTone tone;

  @override
  Widget build(BuildContext context) {
    final isWarning = tone == _BannerTone.warning;
    final background = isWarning
        ? const Color(0xFFFFF4E5)
        : const Color(0xFFEEF1F6);
    final foreground = isWarning ? const Color(0xFF9A5B00) : _stationInk;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: foreground),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: foreground,
                fontSize: 12,
                height: 1.4,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.isOpen});

  final String label;
  final bool isOpen;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
    decoration: BoxDecoration(
      color: isOpen ? success : const Color(0xFF667085),
      borderRadius: BorderRadius.circular(30),
    ),
    child: Text(
      label,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 10,
        fontWeight: FontWeight.w900,
        letterSpacing: .5,
      ),
    ),
  );
}

class _NewStationPill extends StatelessWidget {
  const _NewStationPill();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      color: const Color(0xFFEAF2FF),
      borderRadius: BorderRadius.circular(20),
    ),
    child: const Text(
      'NEW',
      style: TextStyle(
        color: primaryBlue,
        fontSize: 10,
        fontWeight: FontWeight.w900,
        letterSpacing: .5,
      ),
    ),
  );
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.isOpen});

  final bool isOpen;

  @override
  Widget build(BuildContext context) => Container(
    width: 7,
    height: 7,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: isOpen ? success : textGray,
    ),
  );
}

class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.value, required this.label});

  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Icon(icon, color: primaryBlue, size: 17),
      const SizedBox(height: 5),
      Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: _stationInk,
          fontSize: 12,
          fontWeight: FontWeight.w900,
        ),
      ),
      const SizedBox(height: 2),
      Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: textGray, fontSize: 11),
      ),
    ],
  );
}

class _MetricDivider extends StatelessWidget {
  const _MetricDivider();

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 38,
    color: borderColor,
    margin: const EdgeInsets.symmetric(horizontal: 8),
  );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: const TextStyle(
          color: _stationInk,
          fontSize: 17,
          fontWeight: FontWeight.w900,
        ),
      ),
      const SizedBox(height: 3),
      Text(subtitle, style: const TextStyle(color: textGray, fontSize: 12)),
    ],
  );
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: lightBlue,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: const TextStyle(
        color: primaryBlue,
        fontSize: 11,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

class _SurfaceCard extends StatelessWidget {
  const _SurfaceCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: borderColor),
    ),
    child: child,
  );
}

class _LoadingProducts extends StatelessWidget {
  const _LoadingProducts();

  @override
  Widget build(BuildContext context) => Column(
    children: List.generate(
      2,
      (index) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _skeleton(width: 130, height: 16),
              const SizedBox(height: 16),
              _skeleton(width: 90, height: 12),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: _skeleton(height: 52)),
                  const SizedBox(width: 8),
                  Expanded(child: _skeleton(height: 52)),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );

  static Widget _skeleton({double? width, required double height}) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: _stationCanvas,
      borderRadius: BorderRadius.circular(10),
    ),
  );
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(20, 25, 20, 20),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: borderColor),
    ),
    child: Column(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: const BoxDecoration(
            color: lightBlue,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: primaryBlue, size: 25),
        ),
        const SizedBox(height: 12),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: _stationInk,
            fontSize: 15,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: textGray, fontSize: 12, height: 1.45),
        ),
        if (actionLabel != null && onAction != null) ...[
          const SizedBox(height: 15),
          SizedBox(
            height: 44,
            child: ElevatedButton(
              onPressed: onAction,
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryBlue,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(13),
                ),
              ),
              child: Text(
                actionLabel!,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

class _StationPhotoPlaceholder extends StatelessWidget {
  const _StationPhotoPlaceholder();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: lightBlue,
    child: Center(
      child: Icon(Icons.storefront_rounded, color: primaryBlue, size: 40),
    ),
  );
}

class _ProductPhotoPlaceholder extends StatelessWidget {
  const _ProductPhotoPlaceholder();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: lightBlue,
    child: Center(
      child: Icon(Icons.water_drop_rounded, color: primaryBlue, size: 34),
    ),
  );
}

String? _publicImageUrl(String? storagePath) {
  final path = storagePath?.trim();
  if (!SupabaseConfig.isInitialized || path == null || path.isEmpty) {
    return null;
  }
  return SupabaseService.client.storage
      .from('station-assets')
      .getPublicUrl(path);
}

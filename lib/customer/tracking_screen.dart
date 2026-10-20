import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:latlong2/latlong.dart';

import '../config/app_colors.dart';
import '../models/customer_cart.dart';
import '../services/supabase_service.dart';

class TrackScreen extends StatefulWidget {
  const TrackScreen({super.key});

  @override
  State<TrackScreen> createState() => _TrackScreenState();
}

class _TrackScreenState extends State<TrackScreen> {
  List<CustomerDeliveryTracking> _tracking = const [];
  String? _selectedOrderId;
  String? _error;
  bool _loading = true;
  bool _refreshing = false;
  int _loadSequence = 0;
  Timer? _refreshTimer;
  RealtimeChannel? _ordersChannel;
  RealtimeChannel? _deliveriesChannel;

  @override
  void initState() {
    super.initState();
    _loadTracking();
    final customerId = SupabaseService.client.auth.currentUser?.id;
    if (customerId != null) {
      _ordersChannel = SupabaseService.client
          .channel('customer-tracking-orders-$customerId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'orders',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'customer_id',
              value: customerId,
            ),
            callback: (_) => _loadTracking(showLoading: false),
          )
          .subscribe();
      _deliveriesChannel = SupabaseService.client
          .channel('customer-tracking-deliveries-$customerId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'deliveries',
            callback: (_) => _loadTracking(showLoading: false),
          )
          .subscribe();
    }
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _loadTracking(showLoading: false),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    final channel = _ordersChannel;
    if (channel != null) {
      unawaited(SupabaseService.client.removeChannel(channel));
    }
    final deliveriesChannel = _deliveriesChannel;
    if (deliveriesChannel != null) {
      unawaited(SupabaseService.client.removeChannel(deliveriesChannel));
    }
    super.dispose();
  }

  Future<void> _loadTracking({
    bool showLoading = true,
    bool showRefreshing = false,
  }) async {
    final sequence = ++_loadSequence;
    if (showLoading && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else if (showRefreshing && mounted) {
      setState(() {
        _refreshing = true;
        _error = null;
      });
    }
    try {
      final tracking = await SupabaseService.getCustomerOrderTracking();
      if (!mounted || sequence != _loadSequence) return;
      setState(() {
        _tracking = tracking;
        _selectedOrderId =
            tracking.any((item) => item.order.id == _selectedOrderId)
            ? _selectedOrderId
            : tracking.firstOrNull?.order.id;
        _loading = false;
        _refreshing = false;
        _error = null;
      });
    } on Exception catch (error) {
      if (!mounted || sequence != _loadSequence) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        _error = error.toString();
      });
    } finally {
      if (mounted && sequence == _loadSequence && _refreshing) {
        setState(() => _refreshing = false);
      }
    }
  }

  Future<void> _refreshTracking() =>
      _loadTracking(showLoading: false, showRefreshing: true);

  CustomerDeliveryTracking? get _selectedTracking {
    for (final item in _tracking) {
      if (item.order.id == _selectedOrderId) return item;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _tracking.isEmpty) {
      return const SafeArea(
        child: Center(child: CircularProgressIndicator(color: primaryBlue)),
      );
    }
    if (_error != null && _tracking.isEmpty) {
      return SafeArea(
        child: _TrackingError(message: _error!, onRetry: _refreshTracking),
      );
    }

    final selected = _selectedTracking;
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _refreshTracking,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 24, 18, 17),
                child: Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Order Tracking',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              color: textDark,
                            ),
                          ),
                          SizedBox(height: 5),
                          Text(
                            'Follow delivery progress and recent cancellations.',
                            style: TextStyle(color: textGray, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Refresh tracking',
                      onPressed: _refreshing ? null : _refreshTracking,
                      icon: _refreshing
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ),
              ),
            ),
            if (_error != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Text(
                    'Could not refresh tracking: $_error',
                    style: const TextStyle(color: danger, fontSize: 12),
                  ),
                ),
              ),
            if (_tracking.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: _TrackingEmptyState(),
              )
            else ...[
              if (_tracking.length > 1)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                    child: DropdownButtonFormField<String>(
                      initialValue: _selectedOrderId,
                      decoration: const InputDecoration(
                        labelText: 'Choose an order',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final item in _tracking)
                          DropdownMenuItem(
                            value: item.order.id,
                            child: Text(
                              '${item.order.formattedNumber} · ${item.order.statusLabel}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) =>
                          setState(() => _selectedOrderId = value),
                    ),
                  ),
                ),
              if (selected != null) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: _TrackingSummary(tracking: selected),
                  ),
                ),
                if (selected.order.status != 'cancelled')
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                      child: _TrackingMap(tracking: selected),
                    ),
                  ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: _TrackingTimeline(tracking: selected),
                  ),
                ),
                if (selected.order.status != 'cancelled')
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                      child: _DeliveryDetails(tracking: selected),
                    ),
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _TrackingSummary extends StatelessWidget {
  const _TrackingSummary({required this.tracking});

  final CustomerDeliveryTracking tracking;

  @override
  Widget build(BuildContext context) {
    final order = tracking.order;
    final eta = tracking.estimatedDeliveryAt;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF2860E8), Color(0xFF1743B5)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.local_shipping_rounded,
            color: Colors.white,
            size: 30,
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  order.formattedNumber,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  order.statusLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (eta != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Estimated delivery ${_formatDateTime(eta)}',
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
          Text(
            '₱${order.total.toStringAsFixed(2)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackingMap extends StatelessWidget {
  const _TrackingMap({required this.tracking});

  final CustomerDeliveryTracking tracking;

  @override
  Widget build(BuildContext context) {
    final destination = _coordinates(tracking.order.addressSnapshot);
    final rider = tracking.hasRiderLocation
        ? LatLng(tracking.riderLatitude!, tracking.riderLongitude!)
        : null;
    if (destination == null && rider == null) {
      return Container(
        height: 180,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Text(
          'Map location is not available for this order yet.',
          textAlign: TextAlign.center,
          style: TextStyle(color: textGray),
        ),
      );
    }

    final center = rider != null && destination != null
        ? LatLng(
            (rider.latitude + destination.latitude) / 2,
            (rider.longitude + destination.longitude) / 2,
          )
        : rider ?? destination!;
    final points = [?rider, ?destination];
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: SizedBox(
        height: 270,
        child: FlutterMap(
          options: MapOptions(
            initialCenter: center,
            initialZoom: points.length > 1 ? 12 : 14,
            minZoom: 4,
            maxZoom: 18,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.aquadirect.customer',
            ),
            MarkerLayer(
              markers: [
                if (destination != null)
                  Marker(
                    point: destination,
                    width: 46,
                    height: 46,
                    child: const _MapMarker(
                      icon: Icons.home_rounded,
                      color: darkBlue,
                    ),
                  ),
                if (rider != null)
                  Marker(
                    point: rider,
                    width: 46,
                    height: 46,
                    child: const _MapMarker(
                      icon: Icons.local_shipping_rounded,
                      color: primaryBlue,
                    ),
                  ),
              ],
            ),
            const RichAttributionWidget(
              attributions: [
                TextSourceAttribution('OpenStreetMap contributors'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

LatLng? _coordinates(Map<String, dynamic> snapshot) {
  final latitude = snapshot['latitude'];
  final longitude = snapshot['longitude'];
  if (latitude is! num || longitude is! num) return null;
  if (!latitude.toDouble().isFinite || !longitude.toDouble().isFinite) {
    return null;
  }
  if (latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) {
    return null;
  }
  return LatLng(latitude.toDouble(), longitude.toDouble());
}

class _MapMarker extends StatelessWidget {
  const _MapMarker({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      shape: BoxShape.circle,
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: .2),
          blurRadius: 10,
          offset: const Offset(0, 3),
        ),
      ],
    ),
    child: Icon(icon, color: color, size: 27),
  );
}

class _TrackingTimeline extends StatelessWidget {
  const _TrackingTimeline({required this.tracking});

  final CustomerDeliveryTracking tracking;

  static const _steps = [
    ('Pending', 'Your order has been received'),
    ('Confirmed', 'The station has accepted your order'),
    ('Preparing', 'Your water is being prepared'),
    ('Ready', 'Your order is ready for delivery'),
    ('Out for delivery', 'The rider is on the way to your address'),
    ('Delivered', 'Your order has been delivered'),
  ];

  @override
  Widget build(BuildContext context) {
    if (tracking.order.status == 'cancelled') {
      return _TrackingCard(
        title: 'Delivery status',
        child: const _TimelineStep(
          title: 'Cancelled',
          detail: 'This order was cancelled.',
          isComplete: false,
          isCurrent: true,
        ),
      );
    }
    final current = switch (tracking.order.status) {
      'pending' => 0,
      'confirmed' => 1,
      'preparing' => 2,
      'ready' || 'rider_assigned' => 3,
      'out_for_delivery' => 4,
      'delivered' => 5,
      _ => 0,
    };
    return _TrackingCard(
      title: 'Delivery status',
      child: Column(
        children: [
          for (var index = 0; index < _steps.length; index++) ...[
            _TimelineStep(
              title: _steps[index].$1,
              detail: _steps[index].$2,
              isComplete: index < current,
              isCurrent: index == current,
            ),
            if (index < _steps.length - 1)
              Container(
                height: 18,
                width: 2,
                margin: const EdgeInsets.only(left: 15),
                color: index < current ? primaryBlue : const Color(0xFFE0E6EF),
              ),
          ],
        ],
      ),
    );
  }
}

class _TimelineStep extends StatelessWidget {
  const _TimelineStep({
    required this.title,
    required this.detail,
    required this.isComplete,
    required this.isCurrent,
  });

  final String title;
  final String detail;
  final bool isComplete;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final active = isComplete || isCurrent;
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? primaryBlue : const Color(0xFFF0F2F6),
          ),
          child: Icon(
            isComplete ? Icons.check_rounded : Icons.circle,
            size: isComplete ? 18 : 10,
            color: active ? Colors.white : const Color(0xFFAEB5C0),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: isCurrent ? primaryBlue : textDark,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                detail,
                style: const TextStyle(color: textGray, fontSize: 11),
              ),
            ],
          ),
        ),
        if (isCurrent)
          const Text(
            'CURRENT',
            style: TextStyle(
              color: primaryBlue,
              fontSize: 9,
              fontWeight: FontWeight.w800,
            ),
          ),
      ],
    );
  }
}

class _DeliveryDetails extends StatelessWidget {
  const _DeliveryDetails({required this.tracking});

  final CustomerDeliveryTracking tracking;

  @override
  Widget build(BuildContext context) {
    final order = tracking.order;
    final riderName = tracking.riderName?.trim();
    final riderPhone = tracking.riderPhone?.trim();
    final riderNumber = tracking.riderNumber;
    final riderLabel = [
      if (riderNumber != null) 'Rider ${riderNumber.toString().padLeft(2, '0')}',
      if (riderName?.isNotEmpty == true) riderName,
    ].join(' · ');
    return _TrackingCard(
      title: 'Delivery information',
      child: Column(
        children: [
          _InfoRow(
            icon: Icons.water_drop_outlined,
            title: 'Items',
            value: order.itemSummary,
          ),
          const SizedBox(height: 13),
          _InfoRow(
            icon: Icons.payments_outlined,
            title: 'Payment',
            value:
                '${order.paymentMethodLabel} · ${_paymentStatusLabel(order.paymentStatus)}',
          ),
          const SizedBox(height: 13),
          _InfoRow(
            icon: Icons.location_on_outlined,
            title: 'Delivery address',
            value: order.deliveryAddress,
          ),
          if (riderName?.isNotEmpty == true) ...[
            const SizedBox(height: 13),
            _InfoRow(
              icon: Icons.person_outline_rounded,
              title: 'Rider',
              value: riderLabel,
            ),
          ],
          if (riderPhone?.isNotEmpty == true) ...[
            const SizedBox(height: 13),
            _InfoRow(
              icon: Icons.phone_outlined,
              title: 'Rider phone',
              value: riderPhone!,
            ),
          ],
          if (tracking.hasRiderLocation) ...[
            const SizedBox(height: 13),
            _InfoRow(
              icon: Icons.my_location_rounded,
              title: 'Last location update',
              value: tracking.locationRecordedAt == null
                  ? 'Time unavailable'
                  : _formatDateTime(tracking.locationRecordedAt!),
            ),
          ] else if (order.status == 'out_for_delivery') ...[
            const SizedBox(height: 13),
            const Text(
              'The rider has not shared a location update yet.',
              style: TextStyle(color: textGray, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

String _paymentStatusLabel(String status) => switch (status) {
  'paid' => 'Paid',
  'failed' => 'Failed',
  'cancelled' => 'Cancelled',
  'refunded' => 'Refunded',
  'partially_refunded' => 'Partially refunded',
  'processing' => 'Processing',
  _ => 'Awaiting payment',
};

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.month}/${local.day} at $hour:$minute '
      '${local.hour < 12 ? 'AM' : 'PM'}';
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 19, color: primaryBlue),
      const SizedBox(width: 11),
      SizedBox(
        width: 91,
        child: Text(
          title,
          style: const TextStyle(color: textGray, fontSize: 11),
        ),
      ),
      Expanded(
        child: Text(
          value,
          textAlign: TextAlign.end,
          style: const TextStyle(
            color: textDark,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ],
  );
}

class _TrackingCard extends StatelessWidget {
  const _TrackingCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(19),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(21),
      boxShadow: [
        BoxShadow(
          color: darkBlue.withValues(alpha: .045),
          blurRadius: 14,
          offset: const Offset(0, 5),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: textDark,
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 17),
        child,
      ],
    ),
  );
}

class _TrackingEmptyState extends StatelessWidget {
  const _TrackingEmptyState();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(30),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: const BoxDecoration(
              color: lightBlue,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.local_shipping_outlined,
              color: primaryBlue,
              size: 42,
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'No active or recently cancelled orders',
            style: TextStyle(
              color: textDark,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 7),
          const Text(
            'When you place an order, its progress or cancellation status will appear here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: textGray, fontSize: 12, height: 1.5),
          ),
        ],
      ),
    ),
  );
}

class _TrackingError extends StatelessWidget {
  const _TrackingError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_rounded, size: 42, color: textGray),
          const SizedBox(height: 12),
          const Text(
            'Could not load order tracking',
            style: TextStyle(color: textDark, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: textGray, fontSize: 12),
          ),
          const SizedBox(height: 14),
          FilledButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}

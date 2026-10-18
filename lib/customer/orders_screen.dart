import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_colors.dart';
import '../models/customer_cart.dart';
import '../services/supabase_service.dart';

enum _OrderFilter { all, inProgress, delivered, cancelled }

const _amber = Color(0xFFB45309);
const _cardBorder = Color(0xFFE9EDF4);

bool _isCancelled(String status) => status == 'cancelled' || status == 'failed';

Color _orderStatusColor(String status) => switch (status) {
  'delivered' => success,
  'cancelled' || 'failed' => danger,
  _ => primaryBlue,
};

IconData _orderStatusIcon(String status) => switch (status) {
  'delivered' => Icons.check_circle_rounded,
  'cancelled' => Icons.cancel_rounded,
  'failed' => Icons.error_rounded,
  'out_for_delivery' || 'rider_assigned' => Icons.local_shipping_rounded,
  'preparing' => Icons.inventory_2_rounded,
  _ => Icons.schedule_rounded,
};

/// Customer-friendly payment text instead of raw enum values such as
/// `awaiting_payment` or `partially_refunded`.
({String label, Color color, IconData icon}) _paymentInfo(String status) {
  switch (status) {
    case 'paid':
      return (label: 'Paid', color: success, icon: Icons.verified_rounded);
    case 'failed':
      return (
        label: 'Payment failed',
        color: danger,
        icon: Icons.error_outline_rounded,
      );
    case 'cancelled':
      return (
        label: 'Payment cancelled',
        color: danger,
        icon: Icons.cancel_outlined,
      );
    case 'refunded':
      return (
        label: 'Refunded',
        color: textGray,
        icon: Icons.undo_rounded,
      );
    case 'partially_refunded':
      return (
        label: 'Partially refunded',
        color: textGray,
        icon: Icons.undo_rounded,
      );
    case 'unpaid':
    case 'pending':
    case 'awaiting_payment':
    case 'processing':
      return (
        label: 'Awaiting payment',
        color: _amber,
        icon: Icons.hourglass_top_rounded,
      );
    default:
      final text = status.replaceAll('_', ' ');
      return (
        label: text.isEmpty
            ? 'Unknown'
            : '${text[0].toUpperCase()}${text.substring(1)}',
        color: textGray,
        icon: Icons.payments_outlined,
      );
  }
}

bool _awaitingPayment(CustomerOrder order) =>
    order.paymentMethod == 'paymongo' &&
    !const {'paid', 'partially_refunded', 'refunded'}.contains(
      order.paymentStatus,
    ) &&
    !_isCancelled(order.status);

class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  _OrderFilter _filter = _OrderFilter.all;
  final _searchController = TextEditingController();
  List<CustomerOrder> _orders = const [];
  bool _loading = true;
  String? _error;
  RealtimeChannel? _ordersChannel;
  Timer? _reloadDebounce;
  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    _loadOrders();
    final customerId = SupabaseService.client.auth.currentUser?.id;
    if (customerId != null) {
      _ordersChannel = SupabaseService.client
          .channel('customer-orders-$customerId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'orders',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'customer_id',
              value: customerId,
            ),
            // Several row changes often arrive together; reload once.
            callback: (_) {
              _reloadDebounce?.cancel();
              _reloadDebounce = Timer(
                const Duration(milliseconds: 350),
                () => unawaited(_loadOrders(silent: true)),
              );
            },
          )
          .subscribe();
    }
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    _searchController.dispose();
    final channel = _ordersChannel;
    if (channel != null) {
      unawaited(SupabaseService.client.removeChannel(channel));
    }
    super.dispose();
  }

  List<CustomerOrder> _computeVisible() {
    final byStatus = switch (_filter) {
      _OrderFilter.all => _orders,
      _OrderFilter.inProgress =>
        _orders.where((o) => o.isInProgress).toList(),
      _OrderFilter.delivered =>
        _orders.where((o) => o.status == 'delivered').toList(),
      _OrderFilter.cancelled =>
        _orders.where((o) => _isCancelled(o.status)).toList(),
    };
    final query = _searchController.text
        .trim()
        .toLowerCase()
        .replaceFirst('#', '');
    if (query.isEmpty) return byStatus;
    return byStatus
        .where(
          (o) =>
              o.formattedNumber.toLowerCase().contains(query) ||
              o.stationName.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  /// [silent] reloads (realtime) never flash a spinner or an error screen.
  Future<void> _loadOrders({bool silent = false}) async {
    if (!mounted) return;
    final seq = ++_loadSeq;
    if (!silent && _orders.isEmpty) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final orders = await SupabaseService.getCustomerOrders();
      // Ignore a slower, older response that finished after a newer one.
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _orders = orders;
        _loading = false;
        _error = null;
      });
    } on Exception catch (error) {
      if (!mounted || seq != _loadSeq) return;
      final hadOrders = _orders.isNotEmpty;
      setState(() {
        _loading = false;
        if (!hadOrders) _error = error.toString();
      });
      if (hadOrders && !silent) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('Couldn’t refresh. Showing your last orders.'),
            ),
          );
      }
    }
  }

  void _selectFilter(_OrderFilter filter) {
    HapticFeedback.selectionClick();
    setState(() => _filter = filter);
  }

  void _openOrder(CustomerOrder order) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => _OrderDetailsScreen(order: order)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _orders.isEmpty) {
      return const SafeArea(child: _OrdersSkeleton());
    }
    if (_error != null && _orders.isEmpty) {
      return SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off_rounded, color: textGray, size: 40),
                const SizedBox(height: 12),
                const Text(
                  'Couldn’t load your orders',
                  style: TextStyle(
                    color: textDark,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Check your connection and try again.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: textGray, fontSize: 12),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: _loadOrders,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final visible = _computeVisible();
    final activeCount = _orders.where((o) => o.isInProgress).length;
    final deliveredCount = _orders.where((o) => o.status == 'delivered').length;
    final cancelledCount = _orders.where((o) => _isCancelled(o.status)).length;
    final hasQuery = _searchController.text.trim().isNotEmpty;

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _loadOrders,
        child: CustomScrollView(
          // Always scrollable so pull-to-refresh also works on empty states.
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'My orders',
                      style: TextStyle(
                        color: textDark,
                        fontSize: 29,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -.6,
                      ),
                    ),
                    const SizedBox(height: 5),
                    const Text(
                      'Your water deliveries, all in one place.',
                      style: TextStyle(color: textGray, fontSize: 13),
                    ),
                    const SizedBox(height: 22),
                    _OrdersOverview(
                      activeCount: activeCount,
                      completedCount: deliveredCount,
                      onActiveTap: () => _selectFilter(_OrderFilter.inProgress),
                      onCompletedTap: () => _selectFilter(_OrderFilter.delivered),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 13),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Order history',
                        style: TextStyle(
                          color: textDark,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Text(
                      '${visible.length} ${visible.length == 1 ? 'order' : 'orders'}',
                      style: const TextStyle(
                        color: textGray,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                child: TextField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  textInputAction: TextInputAction.search,
                  style: const TextStyle(fontSize: 14, color: textDark),
                  decoration: InputDecoration(
                    hintText: 'Search order number or station',
                    hintStyle: const TextStyle(color: textGray, fontSize: 13),
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _searchController.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            onPressed: () {
                              _searchController.clear();
                              setState(() {});
                            },
                            icon: const Icon(Icons.close_rounded),
                          ),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: borderColor),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: borderColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(
                        color: primaryBlue,
                        width: 1.4,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 43,
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  scrollDirection: Axis.horizontal,
                  children: [
                    _FilterPill(
                      label: 'All',
                      count: _orders.length,
                      selected: _filter == _OrderFilter.all,
                      onTap: () => _selectFilter(_OrderFilter.all),
                    ),
                    _FilterPill(
                      label: 'In progress',
                      count: activeCount,
                      selected: _filter == _OrderFilter.inProgress,
                      onTap: () => _selectFilter(_OrderFilter.inProgress),
                    ),
                    _FilterPill(
                      label: 'Delivered',
                      count: deliveredCount,
                      selected: _filter == _OrderFilter.delivered,
                      onTap: () => _selectFilter(_OrderFilter.delivered),
                    ),
                    if (cancelledCount > 0 || _filter == _OrderFilter.cancelled)
                      _FilterPill(
                        label: 'Cancelled',
                        count: cancelledCount,
                        selected: _filter == _OrderFilter.cancelled,
                        onTap: () => _selectFilter(_OrderFilter.cancelled),
                      ),
                  ],
                ),
              ),
            ),
            if (visible.isEmpty && _orders.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: _OrdersEmptyState(
                  title: 'No orders yet',
                  detail: 'Your orders will appear here after you place one.',
                ),
              )
            else if (visible.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _OrdersEmptyState(
                  title: 'No matching orders',
                  detail: hasQuery
                      ? 'Nothing matches “${_searchController.text.trim()}”. Check the number or station name.'
                      : 'Try another filter to see your order history.',
                  actionLabel: hasQuery || _filter != _OrderFilter.all
                      ? 'Clear filters'
                      : null,
                  onAction: () {
                    _searchController.clear();
                    setState(() => _filter = _OrderFilter.all);
                  },
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                sliver: SliverList.separated(
                  itemCount: visible.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 13),
                  itemBuilder: (context, index) {
                    final order = visible[index];
                    return _OrderCard(
                      key: ValueKey(order.id),
                      order: order,
                      onTap: () => _openOrder(order),
                      onDelete: order.status == 'cancelled'
                          ? () => _dismissCancelledOrder(order)
                          : null,
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _dismissCancelledOrder(CustomerOrder order) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove cancelled order?'),
        content: const Text(
          'This will remove the order from your history. The station and '
          'payment records will be kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep order'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await SupabaseService.dismissCancelledCustomerOrder(order.id);
      if (!mounted) return;
      setState(() {
        _orders = _orders.where((item) => item.id != order.id).toList();
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Cancelled order removed from history.')),
        );
    } on Exception catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('Could not remove the order: $error')),
        );
    }
  }
}

/// Pulsing placeholders that match the real layout, so the screen doesn't
/// jump when data arrives.
class _OrdersSkeleton extends StatefulWidget {
  const _OrdersSkeleton();

  @override
  State<_OrdersSkeleton> createState() => _OrdersSkeletonState();
}

class _OrdersSkeletonState extends State<_OrdersSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _box(double height, {double? width, double radius = 14}) => Container(
    height: height,
    width: width,
    decoration: BoxDecoration(
      color: const Color(0xFFE3E8F0),
      borderRadius: BorderRadius.circular(radius),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: .45, end: 1.0).animate(_controller),
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
        children: [
          _box(30, width: 150),
          const SizedBox(height: 10),
          _box(14, width: 230),
          const SizedBox(height: 22),
          _box(81, radius: 23),
          const SizedBox(height: 28),
          for (var i = 0; i < 3; i++) ...[
            _box(150, radius: 21),
            const SizedBox(height: 13),
          ],
        ],
      ),
    );
  }
}

class _OrdersOverview extends StatelessWidget {
  const _OrdersOverview({
    required this.activeCount,
    required this.completedCount,
    required this.onActiveTap,
    required this.onCompletedTap,
  });

  final int activeCount;
  final int completedCount;
  final VoidCallback onActiveTap;
  final VoidCallback onCompletedTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF2860E8), Color(0xFF1743B5)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(23),
        boxShadow: [
          BoxShadow(
            color: primaryBlue.withValues(alpha: .20),
            blurRadius: 20,
            offset: const Offset(0, 9),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: _OverviewMetric(
              label: 'IN PROGRESS',
              value: '$activeCount',
              icon: Icons.local_shipping_rounded,
              onTap: onActiveTap,
            ),
          ),
          Container(
            width: 1,
            height: 43,
            color: Colors.white.withValues(alpha: .24),
          ),
          Expanded(
            child: _OverviewMetric(
              label: 'DELIVERED',
              value: '$completedCount',
              icon: Icons.task_alt_rounded,
              onTap: onCompletedTap,
            ),
          ),
        ],
      ),
    );
  }
}

class _OverviewMetric extends StatelessWidget {
  const _OverviewMetric({
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final String value;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$label: $value. Tap to filter.',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: Colors.white, size: 19),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: .8),
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: .6,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      value,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 23,
                        height: 1,
                        fontWeight: FontWeight.w900,
                      ),
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
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(count > 0 ? '$label · $count' : label),
        selected: selected,
        onSelected: (_) => onTap(),
        showCheckmark: false,
        labelStyle: TextStyle(
          color: selected ? Colors.white : textGray,
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
        ),
        backgroundColor: Colors.white,
        selectedColor: primaryBlue,
        side: BorderSide(color: selected ? primaryBlue : borderColor),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({
    super.key,
    required this.order,
    required this.onTap,
    this.onDelete,
  });

  final CustomerOrder order;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final statusColor = _orderStatusColor(order.status);
    final awaiting = _awaitingPayment(order);

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(21),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(21),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(21),
            border: Border.all(color: _cardBorder),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF17345F).withValues(alpha: .035),
                blurRadius: 15,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 45,
                    height: 45,
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: .09),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Icon(
                      _orderStatusIcon(order.status),
                      color: statusColor,
                      size: 23,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          order.formattedNumber,
                          style: const TextStyle(
                            color: textDark,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          order.stationName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: textDark,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          order.formattedDate,
                          style: const TextStyle(color: textGray, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _StatusPill(
                    label: order.statusLabel,
                    color: statusColor,
                    icon: _orderStatusIcon(order.status),
                  ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Divider(height: 1, color: Color(0xFFEEF1F5)),
              ),
              Row(
                children: [
                  const Icon(
                    Icons.inventory_2_outlined,
                    color: textGray,
                    size: 17,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      order.itemSummary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: textDark,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '₱${order.total.toStringAsFixed(2)}',
                        style: const TextStyle(
                          color: textDark,
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        order.deliveryFee == 0
                            ? 'Delivery free'
                            : 'Delivery ₱${order.deliveryFee.toStringAsFixed(2)}',
                        style: const TextStyle(
                          color: textGray,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (awaiting) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: _amber.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.hourglass_top_rounded, size: 15, color: _amber),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Payment not confirmed yet. Open to check.',
                          style: TextStyle(
                            color: _amber,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    order.isInProgress
                        ? Icons.near_me_outlined
                        : Icons.receipt_long_outlined,
                    color: primaryBlue,
                    size: 16,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      order.isInProgress
                          ? 'Follow your delivery'
                          : 'View order summary',
                      style: const TextStyle(
                        color: primaryBlue,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (onDelete != null)
                    InkWell(
                      onTap: onDelete,
                      borderRadius: BorderRadius.circular(10),
                      child: const Padding(
                        padding: EdgeInsets.all(6),
                        child: Tooltip(
                          message: 'Remove from history',
                          child: Icon(
                            Icons.delete_outline_rounded,
                            color: textGray,
                            size: 20,
                          ),
                        ),
                      ),
                    )
                  else
                    const Icon(
                      Icons.arrow_forward_rounded,
                      color: primaryBlue,
                      size: 17,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.label,
    required this.color,
    required this.icon,
  });

  final String label;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _OrdersEmptyState extends StatelessWidget {
  const _OrdersEmptyState({
    required this.title,
    required this.detail,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String detail;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: lightBlue,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.receipt_long_outlined,
                color: primaryBlue,
                size: 32,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: textDark,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(color: textGray, fontSize: 12.5),
            ),
            if (actionLabel != null) ...[
              const SizedBox(height: 14),
              OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

class _OrderDetailsScreen extends StatefulWidget {
  const _OrderDetailsScreen({required this.order});

  final CustomerOrder order;

  @override
  State<_OrderDetailsScreen> createState() => _OrderDetailsScreenState();
}

class _OrderDetailsScreenState extends State<_OrderDetailsScreen> {
  late CustomerOrder _order = widget.order;
  RealtimeChannel? _orderChannel;
  bool _checkingPayment = false;

  bool get _canCheckPayment =>
      _order.paymentMethod == 'paymongo' &&
      !const {'paid', 'partially_refunded', 'refunded'}.contains(
        _order.paymentStatus,
      );

  @override
  void initState() {
    super.initState();
    _orderChannel = SupabaseService.client
        .channel('customer-order-${widget.order.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'orders',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: widget.order.id,
          ),
          callback: (_) => unawaited(_refreshOrder()),
        )
        .subscribe();
  }

  @override
  void dispose() {
    final channel = _orderChannel;
    if (channel != null) {
      unawaited(SupabaseService.client.removeChannel(channel));
    }
    super.dispose();
  }

  Future<void> _refreshOrder() async {
    try {
      final orders = await SupabaseService.getCustomerOrders();
      if (!mounted) return;
      final updated = orders.where((order) => order.id == widget.order.id);
      if (updated.isNotEmpty) setState(() => _order = updated.first);
    } on Exception {
      // Keep showing the last known order; realtime will retry on next change.
    }
  }

  Future<void> _copyOrderNumber() async {
    await Clipboard.setData(ClipboardData(text: _order.formattedNumber));
    if (!mounted) return;
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Order number copied.'),
          duration: Duration(seconds: 2),
        ),
      );
  }

  Future<void> _checkPayment() async {
    if (_checkingPayment) return;
    if (_isCancelled(_order.status)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Check payment for a cancelled order?'),
          content: const Text(
            'This will check PayMongo directly. If payment was captured after '
            'cancellation, an automatic refund action may be queued. The order '
            'will remain cancelled and will not be reopened.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Check payment'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    setState(() => _checkingPayment = true);
    try {
      final result = await SupabaseService.reconcileOrderPayment(_order.id);
      await _refreshOrder();
      if (!mounted) return;

      final message = result.latePaymentRefundRequired
          ? 'PayMongo reports a late payment. A refund action was queued; '
                'this order remains cancelled.'
          : result.pending
          ? 'PayMongo has not confirmed this payment yet. Try again shortly.'
          : result.status == 'paid' && _order.status != 'cancelled'
          ? 'Payment confirmed. The order status has been refreshed.'
          : result.status == 'paid'
          ? 'PayMongo reports payment captured, but this order remains '
                'cancelled. Check its refund status before taking action.'
          : 'Payment check complete. Current status: '
                '${_paymentInfo(_order.paymentStatus).label}.';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    } on Exception catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('Could not check payment: $error')),
        );
    } finally {
      if (mounted) setState(() => _checkingPayment = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = _order;
    final payment = _paymentInfo(order.paymentStatus);

    return Scaffold(
      backgroundColor: paleBlue,
      appBar: AppBar(
        backgroundColor: paleBlue,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          tooltip: 'Back',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back_rounded, color: textDark),
        ),
        title: const Text(
          'Order details',
          style: TextStyle(
            color: textDark,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _refreshOrder,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
          children: [
            _DetailHeader(order: order, onCopy: _copyOrderNumber),
            const SizedBox(height: 18),
            _DetailsSection(
              title: 'Delivery progress',
              child: _DeliveryProgress(status: order.status),
            ),
            const SizedBox(height: 14),
            _DetailsSection(
              title: 'Items',
              child: _OrderLineItem(order: order),
            ),
            const SizedBox(height: 14),
            _DetailsSection(
              title: 'Delivery address',
              child: _InfoLine(
                icon: Icons.location_on_outlined,
                title: 'Delivery location',
                value: order.deliveryAddress,
              ),
            ),
            const SizedBox(height: 14),
            _DetailsSection(
              title: 'Payment',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _InfoLine(
                          icon: Icons.payments_outlined,
                          title: order.paymentMethodLabel,
                          value: 'How you chose to pay',
                        ),
                      ),
                      const SizedBox(width: 8),
                      _StatusPill(
                        label: payment.label,
                        color: payment.color,
                        icon: payment.icon,
                      ),
                    ],
                  ),
                  if (_canCheckPayment) ...[
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _checkingPayment ? null : _checkPayment,
                        icon: _checkingPayment
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh_rounded),
                        label: Text(
                          _checkingPayment
                              ? 'Checking with PayMongo...'
                              : 'Check payment',
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailHeader extends StatelessWidget {
  const _DetailHeader({required this.order, required this.onCopy});

  final CustomerOrder order;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(19),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'ORDER NUMBER',
                  style: TextStyle(
                    color: textGray,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .8,
                  ),
                ),
              ),
              _StatusPill(
                label: order.statusLabel,
                color: _orderStatusColor(order.status),
                icon: _orderStatusIcon(order.status),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  order.formattedNumber,
                  style: const TextStyle(
                    color: textDark,
                    fontSize: 21,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Copy order number',
                visualDensity: VisualDensity.compact,
                onPressed: onCopy,
                icon: const Icon(
                  Icons.copy_rounded,
                  size: 19,
                  color: textGray,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${order.stationName} · ${order.formattedDate}',
            style: const TextStyle(color: textGray, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _DetailsSection extends StatelessWidget {
  const _DetailsSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(21),
        border: Border.all(color: _cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: textDark,
              fontSize: 14.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 15),
          child,
        ],
      ),
    );
  }
}

class _DeliveryProgress extends StatelessWidget {
  const _DeliveryProgress({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    const steps = [
      ('Order placed', 'We received your order', Icons.receipt_long_rounded),
      ('Confirmed', 'The station accepted it', Icons.check_circle_rounded),
      ('Preparing', 'Your water is being prepared', Icons.inventory_2_rounded),
      ('Ready', 'Packed and ready to go', Icons.water_drop_rounded),
      (
        'Out for delivery',
        'On the way to you',
        Icons.local_shipping_rounded,
      ),
      ('Delivered', 'Enjoy your fresh water', Icons.home_rounded),
    ];

    final currentStep = switch (status) {
      'pending' => 0,
      'confirmed' => 1,
      'preparing' => 2,
      'ready' => 3,
      'rider_assigned' || 'out_for_delivery' => 4,
      'delivered' => 5,
      _ => -1,
    };

    if (currentStep < 0) {
      final cancelled = status == 'cancelled';
      return Row(
        children: [
          Icon(
            cancelled ? Icons.cancel_rounded : Icons.error_rounded,
            color: danger,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              cancelled
                  ? 'This order was cancelled.'
                  : 'This order could not be completed.',
              style: const TextStyle(
                color: textDark,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      );
    }

    final delivered = status == 'delivered';
    return Column(
      children: [
        for (var index = 0; index < steps.length; index++)
          _ProgressStep(
            title: steps[index].$1,
            subtitle: steps[index].$2,
            icon: steps[index].$3,
            complete: index <= currentStep,
            active: !delivered && index == currentStep,
            isLast: index == steps.length - 1,
          ),
      ],
    );
  }
}

class _ProgressStep extends StatelessWidget {
  const _ProgressStep({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.complete,
    required this.active,
    required this.isLast,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool complete;
  final bool active;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final color = complete ? primaryBlue : const Color(0xFFB8C1CF);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 34,
            child: Column(
              children: [
                Container(
                  width: 29,
                  height: 29,
                  decoration: BoxDecoration(
                    color: active ? primaryBlue : color.withValues(alpha: .10),
                    shape: BoxShape.circle,
                    boxShadow: active
                        ? [
                            BoxShadow(
                              color: primaryBlue.withValues(alpha: .25),
                              blurRadius: 0,
                              spreadRadius: 4,
                            ),
                          ]
                        : null,
                  ),
                  child: Icon(
                    active || !complete ? icon : Icons.check_rounded,
                    size: 15,
                    color: active ? Colors.white : color,
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      color: complete
                          ? primaryBlue.withValues(alpha: .22)
                          : const Color(0xFFE8ECF2),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: 2, bottom: isLast ? 0 : 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: complete ? textDark : textGray,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: const TextStyle(color: textGray, fontSize: 11),
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

class _OrderLineItem extends StatelessWidget {
  const _OrderLineItem({required this.order});

  final CustomerOrder order;

  @override
  Widget build(BuildContext context) {
    final subtotal = order.total - order.deliveryFee;
    return Column(
      children: [
        for (var index = 0; index < order.items.length; index++) ...[
          if (index > 0) const SizedBox(height: 13),
          _OrderItemRow(item: order.items[index]),
        ],
        if (order.items.isEmpty)
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Item details are unavailable.',
              style: TextStyle(color: textGray, fontSize: 12),
            ),
          ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 14),
          child: Divider(height: 1, color: borderColor),
        ),
        _AmountRow(label: 'Subtotal', value: '₱${subtotal.toStringAsFixed(2)}'),
        const SizedBox(height: 8),
        _AmountRow(
          label: 'Delivery fee',
          value: order.deliveryFee == 0
              ? 'Free'
              : '₱${order.deliveryFee.toStringAsFixed(2)}',
        ),
        const SizedBox(height: 12),
        _AmountRow(
          label: 'Total',
          value: '₱${order.total.toStringAsFixed(2)}',
          emphasized: true,
        ),
      ],
    );
  }
}

class _AmountRow extends StatelessWidget {
  const _AmountRow({
    required this.label,
    required this.value,
    this.emphasized = false,
  });

  final String label;
  final String value;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: emphasized ? textDark : textGray,
              fontSize: emphasized ? 14 : 12.5,
              fontWeight: emphasized ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: textDark,
            fontSize: emphasized ? 17 : 12.5,
            fontWeight: emphasized ? FontWeight.w900 : FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _OrderItemRow extends StatelessWidget {
  const _OrderItemRow({required this.item});

  final CustomerOrderItem item;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: lightBlue,
          borderRadius: BorderRadius.circular(13),
        ),
        child: const Icon(
          Icons.water_drop_rounded,
          color: primaryBlue,
          size: 21,
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.productName,
              style: const TextStyle(
                color: textDark,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '${item.optionLabel} · Qty ${item.quantity}',
              style: const TextStyle(color: textGray, fontSize: 11),
            ),
          ],
        ),
      ),
      const SizedBox(width: 8),
      Text(
        '₱${item.lineTotal.toStringAsFixed(2)}',
        style: const TextStyle(
          color: textDark,
          fontSize: 12.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    ],
  );
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 39,
          height: 39,
          decoration: BoxDecoration(
            color: lightBlue,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(icon, color: primaryBlue, size: 19),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: textDark,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: const TextStyle(
                  color: textGray,
                  fontSize: 11.5,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
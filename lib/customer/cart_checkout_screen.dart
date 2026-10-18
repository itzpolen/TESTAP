import 'package:flutter/material.dart';
import 'dart:async';

import 'package:url_launcher/url_launcher.dart';

import '../config/app_colors.dart';
import '../models/customer_cart.dart';
import '../models/station_delivery_info.dart';
import '../services/location_service.dart';
import '../services/ph_address_service.dart';
import '../services/supabase_service.dart';
import 'location_flow_screen.dart';

const _checkoutInk = Color(0xFF17243A);
const _checkoutMuted = Color(0xFF78869A);
const _checkoutLine = Color(0xFFE8EDF4);

enum _PhoneCountry { philippines, unitedStates }

extension on _PhoneCountry {
  String get dialCode => switch (this) {
    _PhoneCountry.philippines => '+63',
    _PhoneCountry.unitedStates => '+1',
  };

  String get flag => switch (this) {
    _PhoneCountry.philippines => '🇵🇭',
    _PhoneCountry.unitedStates => '🇺🇸',
  };

  String get inputHint => switch (this) {
    _PhoneCountry.philippines => '9XX XXX XXXX',
    _PhoneCountry.unitedStates => '(555) 123-4567',
  };
}

String _money(double amount) => '₱${amount.toStringAsFixed(2)}';

String? _optionalValue(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

enum _CheckoutNoticeType { info, success, error }

void _showCheckoutNotice(
  OverlayState overlay, {
  required String title,
  required String message,
  required _CheckoutNoticeType type,
  Duration duration = const Duration(seconds: 3),
}) {
  final (color, background, icon) = switch (type) {
    _CheckoutNoticeType.info => (
      const Color(0xFF1769AA),
      const Color(0xFFEAF4FF),
      Icons.info_outline_rounded,
    ),
    _CheckoutNoticeType.success => (
      const Color(0xFF16804A),
      const Color(0xFFEAF8F0),
      Icons.check_circle_rounded,
    ),
    _CheckoutNoticeType.error => (
      const Color(0xFFB42318),
      const Color(0xFFFFF0EF),
      Icons.error_rounded,
    ),
  };

  var isVisible = false;
  late final OverlayEntry entry;

  entry = OverlayEntry(
    builder: (context) {
      final topInset = MediaQuery.of(context).padding.top;
      return Positioned(
        top: topInset + 8,
        left: 16,
        right: 16,
        child: SafeArea(
          bottom: false,
          child: AnimatedSlide(
            offset: isVisible ? Offset.zero : const Offset(0, -1.4),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: isVisible ? 1 : 0,
              duration: const Duration(milliseconds: 250),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: background),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF102A43).withValues(alpha: .14),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: background,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(icon, color: color, size: 21),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              style: TextStyle(
                                color: color,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              message,
                              style: const TextStyle(
                                color: Color(0xFF344054),
                                fontSize: 12,
                                height: 1.35,
                                fontWeight: FontWeight.w500,
                              ),
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
        ),
      );
    },
  );

  overlay.insert(entry);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!entry.mounted) return;
    isVisible = true;
    entry.markNeedsBuild();
    Timer(const Duration(milliseconds: 300), () {
      Timer(duration, () {
        isVisible = false;
        entry.markNeedsBuild();
        Timer(const Duration(milliseconds: 300), () {
          entry.remove();
        });
      });
    });
  });
}

/// Order rules the seller configured (delivery fee, minimum order, hours),
/// applied to the current cart. The server still re-validates everything when
/// the order is placed; this only lets the customer see it up front.
class _OrderTerms {
  const _OrderTerms(this.cart, this.info);

  final CustomerCart cart;
  final StationDeliveryInfo? info;

  double get itemsTotal => cart.itemTotal;

  double? get deliveryFee => info?.deliveryFee;

  double? get minimum {
    final value = info?.minimumOrderAmount;
    return value != null && value > 0 ? value : null;
  }

  double get shortfall {
    final min = minimum;
    if (min == null) return 0;
    final missing = min - itemsTotal;
    return missing > 0 ? missing : 0;
  }

  bool get belowMinimum => shortfall > 0;

  double get estimatedTotal => itemsTotal + (deliveryFee ?? 0);

  /// Non-null only when the seller's hours say the station is closed now.
  String? get closedNote => info?.hoursLabel(DateTime.now(), isOpen: false);

  String? get openNote => info?.hoursLabel(DateTime.now(), isOpen: true);

  int get itemCount =>
      cart.items.fold<int>(0, (sum, item) => sum + item.quantity);
}

// ===========================================================================
// Cart
// ===========================================================================

class CartScreen extends StatefulWidget {
  final Widget Function() buildMainWrapper;

  const CartScreen({super.key, required this.buildMainWrapper});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  CustomerCart? _cart;
  StationDeliveryInfo? _info;
  String? _infoStationId;
  bool _loading = true;
  String? _error;
  final Set<String> _busyItems = {};
  OverlayEntry? _removalNoticeEntry;
  Timer? _removalNoticeTimer;
  Timer? _removalNoticeRemoveTimer;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _removalNoticeTimer?.cancel();
    _removalNoticeRemoveTimer?.cancel();
    _removalNoticeEntry?.remove();
    _removalNoticeEntry = null;
    super.dispose();
  }

  /// [silent] keeps the current list on screen (no full-screen spinner), which
  /// is what quantity changes and undo use.
  Future<void> _refresh({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final cart = await SupabaseService.getActiveCart();
      if (!mounted) return;
      setState(() {
        _cart = cart;
        _loading = false;
        _error = null;
      });
      if (cart != null &&
          cart.items.isNotEmpty &&
          _infoStationId != cart.stationId) {
        _loadInfo(cart.stationId);
      }
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (_cart == null || !silent) _error = error.toString();
      });
      if (silent) _snack('Could not refresh your cart: $error');
    }
  }

  Future<void> _loadInfo(String stationId) async {
    _infoStationId = stationId;
    try {
      final info = await SupabaseService.getStationDeliveryInfo(stationId);
      if (mounted) setState(() => _info = info);
    } on Exception {
      // Optional details; the cart still works without them.
    }
  }

  void _snack(String message, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  void _showRemovalNotice(CustomerCart cart, CustomerCartItem item) {
    _removalNoticeTimer?.cancel();
    _removalNoticeRemoveTimer?.cancel();
    _removalNoticeEntry?.remove();

    final overlay = Overlay.of(context, rootOverlay: true);
    var isVisible = false;
    late final OverlayEntry entry;

    void dismiss() {
      if (_removalNoticeEntry != entry) return;
      isVisible = false;
      entry.markNeedsBuild();
      _removalNoticeRemoveTimer = Timer(const Duration(milliseconds: 300), () {
        if (_removalNoticeEntry != entry) return;
        entry.remove();
        _removalNoticeEntry = null;
      });
    }

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
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 13,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF123A63),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: .16),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: .14),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.remove_shopping_cart_outlined,
                            color: Colors.white,
                            size: 21,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'Removed from your cart',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                item.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFFD9E9F9),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () {
                            dismiss();
                            unawaited(_undo(cart, item));
                          },
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            minimumSize: const Size(0, 38),
                            backgroundColor: Colors.white.withValues(
                              alpha: .14,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: const Text(
                            'Undo',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
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

    _removalNoticeEntry = entry;
    overlay.insert(entry);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _removalNoticeEntry != entry) return;
      isVisible = true;
      entry.markNeedsBuild();
      _removalNoticeTimer = Timer(const Duration(seconds: 3), dismiss);
    });
  }

  void _applyLocalItems(CustomerCart cart, List<CustomerCartItem> items) {
    setState(
      () => _cart = CustomerCart(
        id: cart.id,
        stationId: cart.stationId,
        stationName: cart.stationName,
        items: List.unmodifiable(items),
      ),
    );
  }

  Future<void> _changeQuantity(CustomerCartItem item, int quantity) async {
    if (quantity <= 0) {
      await _removeItem(item);
      return;
    }
    if (_busyItems.contains(item.id)) return;
    setState(() => _busyItems.add(item.id));
    try {
      await SupabaseService.updateCartItemQuantity(
        itemId: item.id,
        quantity: quantity,
      );
      await _refresh(silent: true);
    } on Exception catch (error) {
      if (mounted) _snack('Could not update the cart: $error');
    } finally {
      if (mounted) setState(() => _busyItems.remove(item.id));
    }
  }

  Future<void> _removeItem(CustomerCartItem item) async {
    final cart = _cart;
    if (cart == null) return;
    // Remove it from the list right away so swipe-to-dismiss stays smooth.
    _applyLocalItems(
      cart,
      cart.items.where((entry) => entry.id != item.id).toList(),
    );
    try {
      await SupabaseService.updateCartItemQuantity(
        itemId: item.id,
        quantity: 0,
      );
    } on Exception catch (error) {
      if (!mounted) return;
      _snack('Could not remove ${item.name}: $error');
      await _refresh(silent: true);
      return;
    }
    if (!mounted) return;
    _showRemovalNotice(cart, item);
    await _refresh(silent: true);
  }

  Future<void> _undo(CustomerCart cart, CustomerCartItem item) async {
    try {
      await SupabaseService.addToCart(
        stationId: cart.stationId,
        productId: item.productId,
        containerOption: item.containerOption,
        quantity: item.quantity,
      );
    } on Exception catch (error) {
      if (mounted) _snack('Could not restore ${item.name}: $error');
    }
    if (mounted) await _refresh(silent: true);
  }

  Future<void> _goToCheckout(CustomerCart cart) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CheckoutScreen(
          buildMainWrapper: widget.buildMainWrapper,
          cart: cart,
          deliveryInfo: _info,
        ),
      ),
    );
    if (mounted) await _refresh(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    final cart = _cart;
    final hasItems = cart != null && cart.items.isNotEmpty;
    final terms = hasItems ? _OrderTerms(cart, _info) : null;

    return Scaffold(
      backgroundColor: paleBlue,
      appBar: AppBar(
        backgroundColor: paleBlue,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          terms == null ? 'Your cart' : 'Your cart · ${terms.itemCount}',
          style: const TextStyle(
            color: _checkoutInk,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
        leading: IconButton(
          tooltip: 'Back',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded, color: _checkoutInk),
        ),
      ),
      bottomNavigationBar: terms == null
          ? null
          : _CartBottomBar(
              terms: terms,
              onCheckout: () => _goToCheckout(terms.cart),
            ),
      body: _buildBody(cart, terms),
    );
  }

  Widget _buildBody(CustomerCart? cart, _OrderTerms? terms) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: primaryBlue));
    }
    if (_error != null && cart == null) {
      return _CartMessage(
        icon: Icons.cloud_off_rounded,
        title: 'Couldn’t load your cart',
        detail: _error!,
        actionLabel: 'Try again',
        onAction: _refresh,
      );
    }
    if (cart == null || cart.items.isEmpty || terms == null) {
      return _CartMessage(
        icon: Icons.shopping_bag_outlined,
        title: 'Your cart is empty',
        detail: 'Choose a station and add water products to get started.',
        actionLabel: 'Browse stations',
        onAction: () => Navigator.of(context).maybePop(),
      );
    }

    final fee = terms.deliveryFee;
    return RefreshIndicator(
      onRefresh: () => _refresh(silent: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(20, 5, 20, 24),
        children: [
          _CartStationHeader(terms: terms),
          if (terms.closedNote != null) ...[
            const SizedBox(height: 12),
            _InlineBanner(
              icon: Icons.schedule_rounded,
              tone: _BannerTone.neutral,
              text:
                  'This station is closed now. ${terms.closedNote}. You can still place your order.',
            ),
          ],
          if (terms.minimum != null) ...[
            const SizedBox(height: 12),
            _MinimumOrderCard(terms: terms),
          ],
          const SizedBox(height: 14),
          for (final item in cart.items) ...[
            Dismissible(
              key: ValueKey(item.id),
              direction: DismissDirection.endToStart,
              onDismissed: (_) => _removeItem(item),
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 22),
                decoration: BoxDecoration(
                  color: danger,
                  borderRadius: BorderRadius.circular(19),
                ),
                child: const Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.white,
                ),
              ),
              child: _CartProductTile(
                item: item,
                busy: _busyItems.contains(item.id),
                onDecrease: () => _changeQuantity(item, item.quantity - 1),
                onIncrease: () => _changeQuantity(item, item.quantity + 1),
                onRemove: () => _removeItem(item),
              ),
            ),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 6),
          _CostSummary(
            rows: [
              ('Water', _money(cart.subtotal)),
              if (cart.containerTotal > 0)
                ('New gallon containers', _money(cart.containerTotal)),
              if (cart.depositTotal > 0)
                ('Refundable deposit', _money(cart.depositTotal)),
              (
                'Delivery fee',
                fee == null
                    ? 'Set at checkout'
                    : fee == 0
                    ? 'Free'
                    : _money(fee),
              ),
            ],
            totalLabel: fee == null ? 'Items total' : 'Estimated total',
            total: _money(
              fee == null ? terms.itemsTotal : terms.estimatedTotal,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'The delivery fee shown is the station’s base rate and may vary by delivery area. The final fee is confirmed when you place the order.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _checkoutMuted, fontSize: 11, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _CartBottomBar extends StatelessWidget {
  const _CartBottomBar({required this.terms, required this.onCheckout});

  final _OrderTerms terms;
  final VoidCallback onCheckout;

  @override
  Widget build(BuildContext context) {
    final fee = terms.deliveryFee;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: _checkoutInk.withValues(alpha: .08),
            blurRadius: 18,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    fee == null ? 'ITEMS TOTAL' : 'ESTIMATED TOTAL',
                    style: const TextStyle(
                      color: _checkoutMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: .7,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _money(
                      fee == null ? terms.itemsTotal : terms.estimatedTotal,
                    ),
                    style: const TextStyle(
                      color: _checkoutInk,
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  if (terms.belowMinimum)
                    Text(
                      'Add ${_money(terms.shortfall)} to order',
                      style: const TextStyle(
                        color: warning,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  if (fee != null)
                    const Text(
                      'Base delivery fee may vary by area',
                      style: TextStyle(color: _checkoutMuted, fontSize: 10),
                    ),
                ],
              ),
            ),
            FilledButton.icon(
              onPressed: terms.belowMinimum ? null : onCheckout,
              style: FilledButton.styleFrom(
                backgroundColor: primaryBlue,
                foregroundColor: Colors.white,
                minimumSize: const Size(168, 50),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
              icon: const Icon(Icons.lock_outline_rounded, size: 17),
              label: const Text(
                'Checkout',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CartStationHeader extends StatelessWidget {
  const _CartStationHeader({required this.terms});

  final _OrderTerms terms;

  @override
  Widget build(BuildContext context) {
    final fee = terms.deliveryFee;
    final minimum = terms.minimum;
    final status = terms.closedNote ?? terms.openNote;
    final closed = terms.closedNote != null;

    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: _checkoutLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _IconTile(
                icon: Icons.storefront_rounded,
                background: Color(0xFFEAF2FF),
                foreground: primaryBlue,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Ordering from',
                      style: TextStyle(
                        color: _checkoutMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      terms.cart.stationName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _checkoutInk,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              if (status != null)
                _StatusTag(label: closed ? 'Closed' : 'Open', open: !closed),
            ],
          ),
          if (fee != null || minimum != null || status != null) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (fee != null)
                  _InfoChip(
                    icon: Icons.local_shipping_outlined,
                    text: fee == 0
                        ? 'Free delivery'
                        : 'Delivery ${_money(fee)}',
                  ),
                if (minimum != null)
                  _InfoChip(
                    icon: Icons.shopping_basket_outlined,
                    text: 'Min. order ${_money(minimum)}',
                  ),
                if (status != null)
                  _InfoChip(icon: Icons.access_time_rounded, text: status),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _MinimumOrderCard extends StatelessWidget {
  const _MinimumOrderCard({required this.terms});

  final _OrderTerms terms;

  @override
  Widget build(BuildContext context) {
    final minimum = terms.minimum!;
    final progress = (terms.itemsTotal / minimum).clamp(0.0, 1.0);
    final reached = !terms.belowMinimum;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: reached ? const Color(0xFFEAF8F0) : const Color(0xFFFFF8E8),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(
          color: reached ? const Color(0xFFBFE6CF) : const Color(0xFFF4E0AE),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                reached
                    ? Icons.check_circle_rounded
                    : Icons.shopping_basket_outlined,
                size: 18,
                color: reached ? success : warning,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  reached
                      ? 'You’ve reached the ${_money(minimum)} minimum order'
                      : 'Add ${_money(terms.shortfall)} more to reach the ${_money(minimum)} minimum order',
                  style: TextStyle(
                    color: reached
                        ? const Color(0xFF1E6B45)
                        : const Color(0xFF73591B),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: Colors.white,
              color: reached ? success : warning,
            ),
          ),
        ],
      ),
    );
  }
}

class _CartProductTile extends StatelessWidget {
  const _CartProductTile({
    required this.item,
    required this.busy,
    required this.onDecrease,
    required this.onIncrease,
    required this.onRemove,
  });

  final CustomerCartItem item;
  final bool busy;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;
  final VoidCallback onRemove;

  bool get _isRefill => item.containerOption == 'refill_existing';

  @override
  Widget build(BuildContext context) {
    final each = item.quantity > 0 ? item.lineTotal / item.quantity : 0.0;
    final returnText = item.returnPolicy?.trim();

    final String? note;
    if (_isRefill) {
      note = returnText != null && returnText.isNotEmpty
          ? returnText
          : item.requiresEmptyContainer
          ? 'Have your empty gallon ready for the rider.'
          : null;
    } else {
      note =
          'Refill ${_money(item.refillPrice)} + container ${_money(item.containerPrice)}'
          '${item.deposit > 0 ? ' + deposit ${_money(item.deposit)}' : ''} each';
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: _checkoutLine),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _IconTile(
            icon: Icons.water_drop_rounded,
            background: Color(0xFFEAF2FF),
            foreground: primaryBlue,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  style: const TextStyle(
                    color: _checkoutInk,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${item.optionLabel} · ${item.waterType} · ${item.containerType}',
                  style: const TextStyle(color: _checkoutMuted, fontSize: 11),
                ),
                if (note != null) ...[
                  const SizedBox(height: 5),
                  Text(
                    note,
                    style: const TextStyle(
                      color: primaryBlue,
                      fontSize: 11,
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    _QuantityButton(
                      icon: Icons.remove_rounded,
                      tooltip: 'Decrease quantity',
                      onTap: busy ? null : onDecrease,
                    ),
                    SizedBox(
                      width: 34,
                      child: busy
                          ? const Center(
                              child: SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: primaryBlue,
                                ),
                              ),
                            )
                          : Text(
                              '${item.quantity}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: _checkoutInk,
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                    ),
                    _QuantityButton(
                      icon: Icons.add_rounded,
                      tooltip: 'Increase quantity',
                      onTap: busy ? null : onIncrease,
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      tooltip: 'Remove ${item.name}',
                      visualDensity: VisualDensity.compact,
                      onPressed: busy ? null : onRemove,
                      icon: const Icon(
                        Icons.delete_outline_rounded,
                        color: danger,
                        size: 20,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _money(item.lineTotal),
                style: const TextStyle(
                  color: _checkoutInk,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              if (item.quantity > 1) ...[
                const SizedBox(height: 3),
                Text(
                  '${_money(each)} each',
                  style: const TextStyle(color: _checkoutMuted, fontSize: 11),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _QuantityButton extends StatelessWidget {
  const _QuantityButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: onTap == null ? const Color(0xFFF0F2F6) : lightBlue,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          icon,
          color: onTap == null ? _checkoutMuted : primaryBlue,
          size: 18,
        ),
      ),
    ),
  );
}

class _CartMessage extends StatelessWidget {
  const _CartMessage({
    required this.icon,
    required this.title,
    required this.detail,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _IconTile(
            icon: icon,
            background: lightBlue,
            foreground: primaryBlue,
            size: 68,
          ),
          const SizedBox(height: 17),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _checkoutInk,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _checkoutMuted,
              fontSize: 12,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: onAction,
            style: FilledButton.styleFrom(backgroundColor: primaryBlue),
            child: Text(actionLabel),
          ),
        ],
      ),
    ),
  );
}

// ===========================================================================
// Checkout
// ===========================================================================

class CheckoutScreen extends StatefulWidget {
  final Widget Function() buildMainWrapper;
  final CustomerCart cart;

  /// Pass the info the cart already loaded to avoid a second request.
  final StationDeliveryInfo? deliveryInfo;

  const CheckoutScreen({
    super.key,
    required this.buildMainWrapper,
    required this.cart,
    this.deliveryInfo,
  });

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen>
    with WidgetsBindingObserver {
  final _formKey = GlobalKey<FormState>();
  final _recipientController = TextEditingController();
  final _phoneController = TextEditingController();
  final _addressLineController = TextEditingController();
  final _barangayController = TextEditingController();
  final _cityController = TextEditingController();
  final _provinceController = TextEditingController();
  final _postalCodeController = TextEditingController();
  final _landmarkController = TextEditingController();
  final _notesController = TextEditingController();
  String _addressLabel = 'Home';
  _PhoneCountry _phoneCountry = _PhoneCountry.philippines;
  String _paymentMethod = 'cod';
  double? _latitude;
  double? _longitude;
  CheckoutOrder? _createdOrder;
  String? _checkoutError;
  bool _submitting = false;
  bool _awaitingPayMongoReturn = false;
  OverlayEntry? _paymentPendingNoticeEntry;
  late StationDeliveryInfo? _info = widget.deliveryInfo;
  final PhilippineAddressService _addressService =
      const PhilippineAddressService();
  List<PhilippineDivision> _provinces = const [];
  List<PhilippineDivision> _cities = const [];
  List<PhilippineDivision> _barangays = const [];
  String? _provinceCode;
  String? _cityCode;
  String? _barangayCode;
  String? _divisionError;
  bool _loadingProvinces = false;
  bool _loadingCities = false;
  bool _loadingBarangays = false;
  int _divisionRequest = 0;

  _OrderTerms get _terms => _OrderTerms(widget.cart, _info);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _removePaymentPendingNotice();
    _recipientController.dispose();
    _phoneController.dispose();
    _addressLineController.dispose();
    _barangayController.dispose();
    _cityController.dispose();
    _provinceController.dispose();
    _postalCodeController.dispose();
    _landmarkController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _showPaymentPendingNotice() {
    _removePaymentPendingNotice();
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
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF123A63),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: .16),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.pending_actions_rounded,
                              color: Colors.white,
                              size: 22,
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Text(
                                'Your order is saved and awaiting payment. '
                                'Use the button below to open or resume its '
                                'secure checkout.',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  height: 1.35,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            TextButton.icon(
                              onPressed: _startPayMongoCheckout,
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                              ),
                              icon: const Icon(
                                Icons.open_in_new_rounded,
                                size: 16,
                              ),
                              label: const Text('Open / resume checkout'),
                            ),
                            TextButton.icon(
                              onPressed: () =>
                                  _checkPaymentStatus(manual: true),
                              style: TextButton.styleFrom(
                                foregroundColor: const Color(0xFFD9E9F9),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                              ),
                              icon: const Icon(Icons.refresh_rounded, size: 16),
                              label: const Text('Check payment'),
                            ),
                          ],
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

    _paymentPendingNoticeEntry = entry;
    overlay.insert(entry);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _paymentPendingNoticeEntry != entry) return;
      isVisible = true;
      entry.markNeedsBuild();
    });
  }

  void _removePaymentPendingNotice() {
    _paymentPendingNoticeEntry?.remove();
    _paymentPendingNoticeEntry = null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSavedDeliveryAddress();
    _prefillContact();
    unawaited(_loadProvinces());
    if (_info == null) _loadDeliveryInfo();
  }

  Future<void> _loadProvinces() async {
    setState(() {
      _loadingProvinces = true;
      _divisionError = null;
    });
    try {
      final divisions = await _addressService.getProvinces();
      if (!mounted) return;
      setState(() {
        _provinces = divisions;
        _loadingProvinces = false;
      });
      await _restoreAddressSelections();
    } on Exception catch (exception) {
      if (!mounted) return;
      setState(() {
        _loadingProvinces = false;
        _divisionError = exception.toString();
      });
    }
  }

  Future<void> _restoreAddressSelections() async {
    final request = ++_divisionRequest;
    final provinceName = _provinceController.text.trim();
    setState(() {
      _provinceCode = null;
      _cityCode = null;
      _barangayCode = null;
      _cities = const [];
      _barangays = const [];
      _loadingCities = false;
      _loadingBarangays = false;
      _divisionError = null;
    });
    if (provinceName.isEmpty || _provinces.isEmpty) return;
    final province = _findDivision(_provinces, provinceName);
    if (province == null) return;

    setState(() {
      _provinceCode = province.code;
      _loadingCities = true;
      _divisionError = null;
    });
    try {
      final cities = await _addressService.getCities(province.code);
      if (!mounted || request != _divisionRequest) return;
      final city = _findDivision(cities, _cityController.text.trim());
      setState(() {
        _cities = cities;
        _loadingCities = false;
        _cityCode = city?.code;
      });
      if (city == null) return;

      setState(() => _loadingBarangays = true);
      final barangays = await _addressService.getBarangays(city.code);
      if (!mounted || request != _divisionRequest) return;
      final barangay = _findDivision(
        barangays,
        _barangayController.text.trim(),
      );
      setState(() {
        _barangays = barangays;
        _loadingBarangays = false;
        _barangayCode = barangay?.code;
      });
    } on Exception catch (exception) {
      if (!mounted || request != _divisionRequest) return;
      setState(() {
        _loadingCities = false;
        _loadingBarangays = false;
        _divisionError = exception.toString();
      });
    }
  }

  PhilippineDivision? _findDivision(
    List<PhilippineDivision> divisions,
    String name,
  ) {
    if (name.isEmpty) return null;
    for (final division in divisions) {
      if (division.name.toLowerCase() == name.toLowerCase()) return division;
    }
    return null;
  }

  Future<void> _selectProvince(String? code) async {
    if (code == null) return;
    final request = ++_divisionRequest;
    final province = _provinces.firstWhere((item) => item.code == code);
    setState(() {
      _provinceCode = code;
      _cityCode = null;
      _barangayCode = null;
      _cityController.clear();
      _barangayController.clear();
      _cities = const [];
      _barangays = const [];
      _loadingCities = true;
      _loadingBarangays = false;
      _divisionError = null;
    });
    _provinceController.text = province.name;
    try {
      final cities = await _addressService.getCities(code);
      if (!mounted || request != _divisionRequest) return;
      setState(() {
        _cities = cities;
        _loadingCities = false;
      });
    } on Exception catch (exception) {
      if (!mounted || request != _divisionRequest) return;
      setState(() {
        _loadingCities = false;
        _divisionError = exception.toString();
      });
    }
  }

  Future<void> _selectCity(String? code) async {
    if (code == null) return;
    final request = ++_divisionRequest;
    final city = _cities.firstWhere((item) => item.code == code);
    setState(() {
      _cityCode = code;
      _barangayCode = null;
      _barangayController.clear();
      _barangays = const [];
      _loadingBarangays = true;
      _divisionError = null;
    });
    _cityController.text = city.name;
    try {
      final barangays = await _addressService.getBarangays(code);
      if (!mounted || request != _divisionRequest) return;
      setState(() {
        _barangays = barangays;
        _loadingBarangays = false;
      });
    } on Exception catch (exception) {
      if (!mounted || request != _divisionRequest) return;
      setState(() {
        _loadingBarangays = false;
        _divisionError = exception.toString();
      });
    }
  }

  void _selectBarangay(String? code) {
    if (code == null) return;
    final barangay = _barangays.firstWhere((item) => item.code == code);
    setState(() {
      _barangayCode = code;
      _divisionError = null;
    });
    _barangayController.text = barangay.name;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _awaitingPayMongoReturn) {
      _awaitingPayMongoReturn = false;
      unawaited(_returnHomeAndVerifyPayment());
    }
  }

  Future<void> _returnHomeAndVerifyPayment() async {
    final order = _createdOrder;
    if (order == null) return;

    final overlay = Overlay.of(context, rootOverlay: true);
    Navigator.of(
      context,
      rootNavigator: true,
    ).pushNamedAndRemoveUntil('/home', (_) => false);

    Object? lastError;
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        await SupabaseService.reconcileOrderPayment(order.id);
        final result = await SupabaseService.getOrderPaymentResult(order.id);
        if (result.paid) {
          _showCheckoutNotice(
            overlay,
            title: 'Payment confirmed',
            message: 'The station has been notified.',
            type: _CheckoutNoticeType.success,
          );
          return;
        }
        if (result.failureReason != null) {
          _showCheckoutNotice(
            overlay,
            title: 'Payment issue',
            message: result.failureReason!,
            type: _CheckoutNoticeType.error,
          );
          return;
        }
        lastError = null;
      } on Exception catch (error) {
        lastError = error;
        debugPrint('Could not reconcile PayMongo payment: $error');
      }

      if (attempt < 5) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }

    _showCheckoutNotice(
      overlay,
      title: lastError == null
          ? 'Payment processing'
          : 'Could not verify payment',
      message: lastError == null
          ? 'AquaDirect will update the order when PayMongo confirms it.'
          : 'The order will update when PayMongo confirms it. Details: $lastError',
      type: lastError == null
          ? _CheckoutNoticeType.info
          : _CheckoutNoticeType.error,
    );
  }

  Future<void> _checkPaymentStatus({bool manual = false}) async {
    final order = _createdOrder;
    if (order == null || _paymentMethod != 'paymongo' || _submitting) return;
    try {
      try {
        // Pull the latest status from PayMongo first, so payment still
        // registers if the webhook is late or missed.
        await SupabaseService.reconcileOrderPayment(order.id);
      } on Exception {
        // Fall back to whatever status is already stored.
      }
      final result = await SupabaseService.getOrderPaymentResult(order.id);
      if (!mounted) return;
      if (result.paid) {
        _removePaymentPendingNotice();
        _showOrderPlaced(order);
      } else if (result.failureReason != null) {
        setState(() => _checkoutError = result.failureReason);
        _showCheckoutNotice(
          Overlay.of(context, rootOverlay: true),
          title: 'Payment issue',
          message: result.failureReason!,
          type: _CheckoutNoticeType.error,
        );
      } else if (manual) {
        _showCheckoutNotice(
          Overlay.of(context, rootOverlay: true),
          title: 'Payment still processing',
          message: 'It can take a few seconds for PayMongo to confirm it.',
          type: _CheckoutNoticeType.info,
        );
      }
    } on Exception catch (error) {
      debugPrint('Could not check PayMongo payment status: $error');
      if (!mounted || !manual) return;
      _showCheckoutNotice(
        Overlay.of(context, rootOverlay: true),
        title: 'Could not check payment',
        message: error.toString(),
        type: _CheckoutNoticeType.error,
      );
    }
  }

  Future<void> _loadDeliveryInfo() async {
    try {
      final info = await SupabaseService.getStationDeliveryInfo(
        widget.cart.stationId,
      );
      if (mounted) setState(() => _info = info);
    } on Exception {
      // Optional; the server still applies the real fee.
    }
  }

  /// Fills the recipient name and phone from the customer profile.
  Future<void> _prefillContact() async {
    try {
      final profile = await SupabaseService.getCurrentProfile();
      if (!mounted || profile == null) return;
      final name = profile['full_name'];
      final phone = profile['phone'];
      if (name is String && _recipientController.text.trim().isEmpty) {
        _recipientController.text = name;
      }
      if (phone is String && _phoneController.text.trim().isEmpty) {
        final normalizedPhone = phone.replaceAll(RegExp(r'\D'), '');
        final country =
            normalizedPhone.startsWith('1') && normalizedPhone.length == 11
            ? _PhoneCountry.unitedStates
            : _PhoneCountry.philippines;
        setState(() {
          _phoneCountry = country;
          _phoneController.text = _phoneInput(phone, country);
        });
      }
    } on Exception {
      // Customers can type these in themselves.
    }
  }

  Future<void> _loadSavedDeliveryAddress() async {
    try {
      final location = await SupabaseService.getCustomerDeliveryLocation();
      if (!mounted || location == null) return;
      setState(() {
        if (_addressLineController.text.trim().isEmpty) {
          _addressLineController.text =
              location.addressLine ?? location.address ?? '';
        }
        if (_barangayController.text.trim().isEmpty) {
          _barangayController.text = location.barangay ?? '';
        }
        if (_cityController.text.trim().isEmpty) {
          _cityController.text = location.city ?? '';
        }
        if (_provinceController.text.trim().isEmpty) {
          _provinceController.text = location.province ?? '';
        }
        _latitude ??= location.latitude;
        _longitude ??= location.longitude;
      });
      await _restoreAddressSelections();
    } on Exception catch (exception) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not load your saved address: $exception'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final terms = _terms;
    final locked = _createdOrder != null;
    final fee = _createdOrder?.deliveryFee ?? terms.deliveryFee;
    final total =
        _createdOrder?.total ??
        (fee == null ? terms.itemsTotal : terms.itemsTotal + fee);

    return Scaffold(
      backgroundColor: paleBlue,
      appBar: AppBar(
        backgroundColor: paleBlue,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          tooltip: 'Back',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded, color: _checkoutInk),
        ),
        title: const Text(
          'Checkout',
          style: TextStyle(
            color: _checkoutInk,
            fontSize: 19,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      bottomNavigationBar: _CheckoutBottomBar(
        onPlaceOrder: _placeOrder,
        paymentMethod: _paymentMethod,
        amount: total,
        amountLabel: locked
            ? 'ORDER TOTAL'
            : fee == null
            ? 'ITEMS TOTAL'
            : 'ESTIMATED TOTAL',
        caption: locked
            ? fee == 0
                  ? 'Delivery fee: Free'
                  : 'Delivery fee: ${_money(fee!)}'
            : fee == null
            ? 'Delivery fee set when placed'
            : 'Base delivery fee may vary by area',
        submitting: _submitting,
        orderCreated: locked,
        blockedReason: terms.belowMinimum
            ? 'Add ${_money(terms.shortfall)} to reach the minimum order'
            : null,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 3, 20, 20),
          children: [
            _CheckoutProgress(orderCreated: locked),
            const SizedBox(height: 18),
            _OrderSummaryCard(terms: terms),
            if (terms.belowMinimum) ...[
              const SizedBox(height: 12),
              _InlineBanner(
                icon: Icons.shopping_basket_outlined,
                tone: _BannerTone.warning,
                text:
                    'This station needs at least ${_money(terms.minimum!)} per order. Go back and add ${_money(terms.shortfall)} more.',
              ),
            ],
            if (terms.closedNote != null) ...[
              const SizedBox(height: 12),
              _InlineBanner(
                icon: Icons.schedule_rounded,
                tone: _BannerTone.neutral,
                text:
                    'This station is closed now. ${terms.closedNote}. Your order will be handled when it opens.',
              ),
            ],
            const SizedBox(height: 21),
            const _SectionHeading(
              title: 'Delivery address',
              subtitle: 'Where should we bring your order?',
              icon: Icons.location_on_outlined,
            ),
            const SizedBox(height: 10),
            IgnorePointer(
              ignoring: locked,
              child: Opacity(
                opacity: locked ? .65 : 1,
                child: Column(
                  children: [
                    _AddressForm(
                      label: _addressLabel,
                      onLabelChanged: (value) =>
                          setState(() => _addressLabel = value),
                      recipientController: _recipientController,
                      phoneController: _phoneController,
                      phoneCountry: _phoneCountry,
                      onPhoneCountryChanged: (country) =>
                          setState(() => _phoneCountry = country),
                      addressLineController: _addressLineController,
                      provinces: _provinces,
                      cities: _cities,
                      barangays: _barangays,
                      provinceCode: _provinceCode,
                      cityCode: _cityCode,
                      barangayCode: _barangayCode,
                      loadingProvinces: _loadingProvinces,
                      loadingCities: _loadingCities,
                      loadingBarangays: _loadingBarangays,
                      divisionError: _divisionError,
                      onProvinceChanged: _selectProvince,
                      onCityChanged: _selectCity,
                      onBarangayChanged: _selectBarangay,
                      onRetryDivisions: _loadProvinces,
                      postalCodeController: _postalCodeController,
                      landmarkController: _landmarkController,
                      hasCoordinates: _latitude != null && _longitude != null,
                      onPickLocation: _pickLocation,
                    ),
                    const SizedBox(height: 21),
                    const _SectionHeading(
                      title: 'Delivery instructions',
                      subtitle: 'Optional notes for your station or rider.',
                      icon: Icons.sticky_note_2_outlined,
                    ),
                    const SizedBox(height: 10),
                    _TextInput(
                      controller: _notesController,
                      label: 'Notes for delivery',
                      hint: 'e.g. Please leave the containers by the gate',
                      maxLines: 3,
                      requiredField: false,
                      capitalization: TextCapitalization.sentences,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 21),
            const _SectionHeading(
              title: 'Payment method',
              subtitle: 'Choose how you would like to pay.',
              icon: Icons.account_balance_wallet_outlined,
            ),
            const SizedBox(height: 10),
            _PaymentMethodCard(
              value: 'cod',
              selectedValue: _paymentMethod,
              enabled: !locked,
              title: 'Cash on delivery',
              description: 'Pay the rider when your order arrives.',
              icon: Icons.payments_outlined,
              onChanged: (value) => setState(() => _paymentMethod = value),
            ),
            const SizedBox(height: 9),
            _PaymentMethodCard(
              value: 'paymongo',
              selectedValue: _paymentMethod,
              enabled: !locked,
              title: 'GCash, Maya or card',
              description: 'Secure online checkout powered by PayMongo.',
              icon: Icons.credit_card_rounded,
              supportingContent: Wrap(
                spacing: 5,
                runSpacing: 5,
                alignment: WrapAlignment.start,
                children: [
                  for (final logo in const [
                    (asset: 'assets/images/gcash_logo.png', label: 'GCash'),
                    (asset: 'assets/images/maya_logo.jpg', label: 'Maya'),
                    (asset: 'assets/images/visa_logo.png', label: 'Visa'),
                    (
                      asset: 'assets/images/paymongo_logo.png',
                      label: 'PayMongo',
                    ),
                  ])
                    Container(
                      width: 46,
                      height: 32,
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(color: _checkoutLine),
                      ),
                      child: Image.asset(
                        logo.asset,
                        fit: BoxFit.contain,
                        semanticLabel: logo.label,
                      ),
                    ),
                ],
              ),
              onChanged: (value) => setState(() => _paymentMethod = value),
            ),
            const SizedBox(height: 21),
            const _SectionHeading(
              title: 'Price details',
              subtitle: 'Based on the station’s current rates.',
              icon: Icons.receipt_long_outlined,
            ),
            const SizedBox(height: 10),
            _CostSummary(
              rows: [
                ('Water', _money(widget.cart.subtotal)),
                if (widget.cart.containerTotal > 0)
                  ('New gallon containers', _money(widget.cart.containerTotal)),
                if (widget.cart.depositTotal > 0)
                  ('Refundable deposit', _money(widget.cart.depositTotal)),
                (
                  'Delivery fee',
                  fee == null
                      ? 'Set when placed'
                      : fee == 0
                      ? 'Free'
                      : _money(fee),
                ),
              ],
              totalLabel: locked
                  ? 'Order total'
                  : fee == null
                  ? 'Items total'
                  : 'Estimated total',
              total: _money(total),
            ),
            const SizedBox(height: 14),
            if (_checkoutError != null) ...[
              _CheckoutErrorBanner(
                message: _checkoutError!,
                onRetry: _paymentMethod == 'paymongo' && _createdOrder != null
                    ? _startPayMongoCheckout
                    : null,
              ),
              const SizedBox(height: 12),
            ],
            const _CheckoutNote(),
            const SizedBox(height: 95),
          ],
        ),
      ),
    );
  }

  Future<void> _pickLocation() async {
    final selected = await Navigator.of(context).push<DeliveryLocation>(
      MaterialPageRoute<DeliveryLocation>(
        builder: (flowContext) => LocationFlowScreen(
          onLocationSelected: (location) =>
              Navigator.of(flowContext).pop(location),
          onSkip: () => Navigator.of(flowContext).pop(),
        ),
      ),
    );
    if (!mounted || selected == null) return;
    setState(() {
      _latitude = selected.latitude;
      _longitude = selected.longitude;
      if (selected.addressLine != null) {
        _addressLineController.text = selected.addressLine!;
      }
      _barangayController.text = selected.barangay ?? '';
      _cityController.text = selected.city ?? '';
      _provinceController.text = selected.province ?? '';
    });
    await _restoreAddressSelections();
  }

  Future<void> _placeOrder() async {
    if (_submitting) return;
    if (_createdOrder != null) {
      if (_paymentMethod == 'paymongo') await _startPayMongoCheckout();
      return;
    }
    if (_terms.belowMinimum) {
      setState(
        () => _checkoutError =
            'Add ${_money(_terms.shortfall)} more to reach this station’s minimum order.',
      );
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Check the highlighted delivery details.'),
          ),
        );
      return;
    }
    setState(() {
      _submitting = true;
      _checkoutError = null;
    });
    try {
      final address = <String, dynamic>{
        'label': _addressLabel,
        'recipient_name': _recipientController.text.trim(),
        'phone':
            '${_phoneCountry.dialCode}${_phoneInput(_phoneController.text, _phoneCountry)}',
        'address_line': _addressLineController.text.trim(),
        'barangay': _barangayController.text.trim(),
        'city': _cityController.text.trim(),
        'province': _provinceController.text.trim(),
        'psgc_barangay_code': _barangayCode,
        'psgc_city_code': _cityCode,
        'psgc_province_code': _provinceCode,
        'postal_code': _optionalValue(_postalCodeController.text),
        'landmark': _optionalValue(_landmarkController.text),
        'latitude': _latitude,
        'longitude': _longitude,
      };
      final order = await SupabaseService.createOrderFromCart(
        cart: widget.cart,
        address: address,
        paymentMethod: _paymentMethod,
        customerNotes: _optionalValue(_notesController.text),
      );
      if (!mounted) return;
      setState(() => _createdOrder = order);
      if (_paymentMethod == 'paymongo') {
        _showPaymentPendingNotice();
        await _startPayMongoCheckout();
      } else {
        _showOrderPlaced(order);
      }
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _checkoutError = _friendlyCheckoutError(error));
      _showCheckoutNotice(
        Overlay.of(context, rootOverlay: true),
        title: 'Could not place order',
        message: _friendlyCheckoutError(error),
        type: _CheckoutNoticeType.error,
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _startPayMongoCheckout() async {
    final order = _createdOrder;
    if (order == null) return;
    setState(() {
      _submitting = true;
      _checkoutError = null;
    });
    try {
      final checkoutUrl = await SupabaseService.createPayMongoCheckout(
        order.id,
      );
      _awaitingPayMongoReturn = true;
      final launched = await launchUrl(
        Uri.parse(checkoutUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        _awaitingPayMongoReturn = false;
        throw Exception(
          'The secure payment page could not be opened on this device.',
        );
      }
    } on Exception catch (error) {
      _awaitingPayMongoReturn = false;
      if (!mounted) return;
      setState(() => _checkoutError = _friendlyCheckoutError(error));
      _showCheckoutNotice(
        Overlay.of(context, rootOverlay: true),
        title: 'Could not open secure checkout',
        message: _friendlyCheckoutError(error),
        type: _CheckoutNoticeType.error,
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showOrderPlaced(CheckoutOrder order) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => OrderSuccessScreen(
          buildMainWrapper: widget.buildMainWrapper,
          orderNumber: order.orderNumber,
          total: order.total,
          paymentMethod: _paymentMethod,
        ),
      ),
    );
  }
}

String _friendlyCheckoutError(Object error) {
  final message = error.toString().replaceFirst('Exception: ', '');
  if (message.contains('paymongotestmodekys')) {
    return 'PayMongo is not configured yet. Add paymongotestmodekys, '
        'PAYMONGO_SUCCESS_URL and PAYMONGO_CANCEL_URL to your Supabase '
        'Edge Function secrets, then retry payment for this order.';
  }
  return message;
}

String _phoneInput(String value, _PhoneCountry country) {
  var digits = value.replaceAll(RegExp(r'\D'), '');
  switch (country) {
    case _PhoneCountry.philippines:
      if (digits.startsWith('63')) {
        digits = digits.substring(2);
      } else if (digits.startsWith('0')) {
        digits = digits.substring(1);
      }
    case _PhoneCountry.unitedStates:
      if (digits.startsWith('1') && digits.length == 11) {
        digits = digits.substring(1);
      }
  }
  return digits;
}

String? _validatePhone(String? value, _PhoneCountry country) {
  final raw = (value ?? '').trim();
  if (raw.isEmpty) return 'Enter your mobile number';
  final digits = _phoneInput(raw, country);
  final isValid = switch (country) {
    _PhoneCountry.philippines => RegExp(r'^9\d{9}$').hasMatch(digits),
    _PhoneCountry.unitedStates => RegExp(
      r'^[2-9]\d{2}[2-9]\d{6}$',
    ).hasMatch(digits),
  };
  if (!isValid) {
    return country == _PhoneCountry.philippines
        ? 'Enter a valid 10-digit Philippine mobile number'
        : 'Enter a valid 10-digit US phone number';
  }
  return null;
}

class _CheckoutProgress extends StatelessWidget {
  const _CheckoutProgress({required this.orderCreated});

  final bool orderCreated;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: _checkoutLine),
      ),
      child: Row(
        children: [
          const _ProgressLabel(
            number: '1',
            label: 'Cart',
            active: true,
            done: true,
          ),
          const Expanded(child: _ProgressConnector(active: true)),
          _ProgressLabel(
            number: '2',
            label: 'Checkout',
            active: true,
            done: orderCreated,
          ),
          Expanded(child: _ProgressConnector(active: orderCreated)),
          _ProgressLabel(number: '3', label: 'Done', active: orderCreated),
        ],
      ),
    );
  }
}

class _ProgressLabel extends StatelessWidget {
  const _ProgressLabel({
    required this.number,
    required this.label,
    required this.active,
    this.done = false,
  });

  final String number;
  final String label;
  final bool active;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final color = active ? primaryBlue : _checkoutMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: done
                ? primaryBlue
                : active
                ? lightBlue
                : const Color(0xFFF0F2F6),
            shape: BoxShape.circle,
          ),
          child: done
              ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
              : Text(
                  number,
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _ProgressConnector extends StatelessWidget {
  const _ProgressConnector({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) => Container(
    height: 2,
    margin: const EdgeInsets.symmetric(horizontal: 6),
    color: active ? primaryBlue : _checkoutLine,
  );
}

/// Review of what is being ordered, shown before the form.
class _OrderSummaryCard extends StatelessWidget {
  const _OrderSummaryCard({required this.terms});

  final _OrderTerms terms;

  @override
  Widget build(BuildContext context) {
    final cart = terms.cart;
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: _checkoutLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.storefront_rounded,
                color: primaryBlue,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  cart.stationName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _checkoutInk,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                '${terms.itemCount} ${terms.itemCount == 1 ? 'item' : 'items'}',
                style: const TextStyle(color: _checkoutMuted, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(height: 1, color: _checkoutLine),
          const SizedBox(height: 10),
          for (final item in cart.items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${item.quantity}×',
                    style: const TextStyle(
                      color: primaryBlue,
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.name,
                          style: const TextStyle(
                            color: _checkoutInk,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          item.optionLabel,
                          style: const TextStyle(
                            color: _checkoutMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    _money(item.lineTotal),
                    style: const TextStyle(
                      color: _checkoutInk,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
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

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _IconTile(
          icon: icon,
          background: lightBlue,
          foreground: primaryBlue,
          size: 37,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: _checkoutInk,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: const TextStyle(color: _checkoutMuted, fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AddressForm extends StatelessWidget {
  const _AddressForm({
    required this.label,
    required this.onLabelChanged,
    required this.recipientController,
    required this.phoneController,
    required this.phoneCountry,
    required this.onPhoneCountryChanged,
    required this.addressLineController,
    required this.provinces,
    required this.cities,
    required this.barangays,
    required this.provinceCode,
    required this.cityCode,
    required this.barangayCode,
    required this.loadingProvinces,
    required this.loadingCities,
    required this.loadingBarangays,
    required this.divisionError,
    required this.onProvinceChanged,
    required this.onCityChanged,
    required this.onBarangayChanged,
    required this.onRetryDivisions,
    required this.postalCodeController,
    required this.landmarkController,
    required this.hasCoordinates,
    required this.onPickLocation,
  });

  final String label;
  final ValueChanged<String> onLabelChanged;
  final TextEditingController recipientController;
  final TextEditingController phoneController;
  final _PhoneCountry phoneCountry;
  final ValueChanged<_PhoneCountry> onPhoneCountryChanged;
  final TextEditingController addressLineController;
  final List<PhilippineDivision> provinces;
  final List<PhilippineDivision> cities;
  final List<PhilippineDivision> barangays;
  final String? provinceCode;
  final String? cityCode;
  final String? barangayCode;
  final bool loadingProvinces;
  final bool loadingCities;
  final bool loadingBarangays;
  final String? divisionError;
  final ValueChanged<String?> onProvinceChanged;
  final ValueChanged<String?> onCityChanged;
  final ValueChanged<String?> onBarangayChanged;
  final VoidCallback onRetryDivisions;
  final TextEditingController postalCodeController;
  final TextEditingController landmarkController;
  final bool hasCoordinates;
  final VoidCallback onPickLocation;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _checkoutLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            children: [
              for (final value in ['Home', 'Work', 'Other'])
                ChoiceChip(
                  label: Text(value),
                  selected: label == value,
                  showCheckmark: false,
                  onSelected: (_) => onLabelChanged(value),
                  labelStyle: TextStyle(
                    color: label == value ? primaryBlue : _checkoutMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                  backgroundColor: const Color(0xFFF7F9FC),
                  selectedColor: lightBlue,
                  side: BorderSide(
                    color: label == value ? primaryBlue : _checkoutLine,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _TextInput(
            controller: recipientController,
            label: 'Recipient name',
            hint: 'Full name',
            autofillHints: const [AutofillHints.name],
          ),
          const SizedBox(height: 10),
          _TextInput(
            controller: phoneController,
            label: 'Phone number',
            hint: phoneCountry.inputHint,
            keyboardType: TextInputType.phone,
            capitalization: TextCapitalization.none,
            customValidator: (value) => _validatePhone(value, phoneCountry),
            autovalidateMode: AutovalidateMode.onUserInteraction,
            autofillHints: const [AutofillHints.telephoneNumber],
            prefixIcon: _PhoneCountrySelector(
              country: phoneCountry,
              onChanged: onPhoneCountryChanged,
            ),
          ),
          const SizedBox(height: 10),
          const _CheckoutCountryField(),
          const SizedBox(height: 10),
          _CheckoutDivisionSelector(
            label: 'Province',
            value: provinceCode,
            divisions: provinces,
            loading: loadingProvinces,
            onChanged: onProvinceChanged,
          ),
          const SizedBox(height: 10),
          _CheckoutDivisionSelector(
            label: 'City / municipality',
            value: cityCode,
            divisions: cities,
            loading: loadingCities,
            enabled: provinceCode != null,
            onChanged: onCityChanged,
          ),
          const SizedBox(height: 10),
          _CheckoutDivisionSelector(
            label: 'Barangay',
            value: barangayCode,
            divisions: barangays,
            loading: loadingBarangays,
            enabled: cityCode != null,
            onChanged: onBarangayChanged,
          ),
          if (divisionError != null) ...[
            const SizedBox(height: 7),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    'Could not load address choices: $divisionError',
                    style: const TextStyle(
                      color: danger,
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: onRetryDivisions,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          _TextInput(
            controller: addressLineController,
            label: 'Purok / street',
            hint: 'House number, purok, or street',
            autofillHints: const [AutofillHints.streetAddressLine1],
          ),
          const SizedBox(height: 10),
          // A pin can also populate the hierarchy and confirm delivery coverage.
          OutlinedButton.icon(
            onPressed: onPickLocation,
            style: OutlinedButton.styleFrom(
              foregroundColor: primaryBlue,
              backgroundColor: hasCoordinates
                  ? const Color(0xFFF0F7FF)
                  : Colors.white,
              minimumSize: const Size(double.infinity, 46),
              side: BorderSide(
                color: hasCoordinates ? primaryBlue : const Color(0xFFD8E4FC),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(13),
              ),
            ),
            icon: Icon(
              hasCoordinates
                  ? Icons.check_circle_outline_rounded
                  : Icons.add_location_alt_outlined,
              size: 18,
            ),
            label: Text(
              hasCoordinates
                  ? 'Delivery pin set · change'
                  : 'Choose pin on map',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            hasCoordinates
                ? 'The station uses your pin to confirm delivery coverage.'
                : 'Choose a pin to confirm the station delivers to your address.',
            style: const TextStyle(
              color: _checkoutMuted,
              fontSize: 11,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _TextInput(
                  controller: postalCodeController,
                  label: 'Postal code',
                  hint: 'Optional',
                  requiredField: false,
                  keyboardType: TextInputType.number,
                  capitalization: TextCapitalization.none,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: _TextInput(
                  controller: landmarkController,
                  label: 'Landmark',
                  hint: 'Optional',
                  requiredField: false,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PhoneCountrySelector extends StatelessWidget {
  const _PhoneCountrySelector({required this.country, required this.onChanged});

  final _PhoneCountry country;
  final ValueChanged<_PhoneCountry> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      PopupMenuButton<_PhoneCountry>(
        tooltip: 'Choose phone country code',
        padding: EdgeInsets.zero,
        onSelected: onChanged,
        itemBuilder: (context) => [
          for (final option in _PhoneCountry.values)
            PopupMenuItem(
              value: option,
              child: Row(
                children: [
                  Text(option.flag, style: const TextStyle(fontSize: 18)),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      option == _PhoneCountry.philippines
                          ? 'Philippines'
                          : 'United States',
                    ),
                  ),
                  Text(
                    option.dialCode,
                    style: const TextStyle(
                      color: _checkoutMuted,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
        ],
        child: Padding(
          padding: const EdgeInsets.only(left: 10, right: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(country.flag, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 6),
              Text(
                country.dialCode,
                style: const TextStyle(
                  color: _checkoutInk,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 2),
              const Icon(
                Icons.arrow_drop_down_rounded,
                color: _checkoutMuted,
                size: 19,
              ),
            ],
          ),
        ),
      ),
      const SizedBox(
        height: 22,
        child: VerticalDivider(width: 1, thickness: 1, color: _checkoutLine),
      ),
      const SizedBox(width: 8),
    ],
  );
}

class _CheckoutCountryField extends StatelessWidget {
  const _CheckoutCountryField();

  @override
  Widget build(BuildContext context) => InputDecorator(
    decoration: InputDecoration(
      labelText: 'Country',
      labelStyle: const TextStyle(color: _checkoutMuted, fontSize: 12),
      filled: true,
      fillColor: const Color(0xFFFAFBFD),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: _checkoutLine),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: _checkoutLine),
      ),
    ),
    child: const Row(
      children: [
        Text(
          'Philippines',
          style: TextStyle(
            color: _checkoutInk,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class _CheckoutDivisionSelector extends StatelessWidget {
  const _CheckoutDivisionSelector({
    required this.label,
    required this.value,
    required this.divisions,
    required this.loading,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final String? value;
  final List<PhilippineDivision> divisions;
  final bool loading;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
    key: ValueKey('$label|$value|${divisions.length}'),
    initialValue: value,
    isExpanded: true,
    borderRadius: BorderRadius.circular(13),
    style: const TextStyle(
      color: _checkoutInk,
      fontSize: 13,
      fontWeight: FontWeight.w600,
    ),
    icon: loading
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: primaryBlue,
            ),
          )
        : const Icon(Icons.keyboard_arrow_down_rounded, color: _checkoutMuted),
    decoration: InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: _checkoutMuted, fontSize: 12),
      hintText: enabled ? 'Select $label' : 'Select the previous area first',
      hintStyle: const TextStyle(color: Color(0xFFA3ADBB), fontSize: 12),
      filled: true,
      fillColor: enabled ? const Color(0xFFFAFBFD) : const Color(0xFFF1F3F7),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: _checkoutLine),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: _checkoutLine),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: primaryBlue, width: 1.3),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: danger, width: 1.3),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: danger, width: 1.5),
      ),
      errorStyle: const TextStyle(
        color: danger,
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
    ),
    items: [
      for (final division in divisions)
        DropdownMenuItem(
          value: division.code,
          child: Text(division.name, overflow: TextOverflow.ellipsis),
        ),
    ],
    validator: (selection) =>
        selection == null ? 'Select ${label.toLowerCase()}' : null,
    onChanged: enabled && !loading ? onChanged : null,
  );
}

class _TextInput extends StatelessWidget {
  const _TextInput({
    required this.controller,
    required this.label,
    required this.hint,
    this.requiredField = true,
    this.keyboardType,
    this.maxLines = 1,
    this.capitalization = TextCapitalization.words,
    this.customValidator,
    this.autofillHints,
    this.prefixIcon,
    this.autovalidateMode,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final bool requiredField;
  final TextInputType? keyboardType;
  final int maxLines;
  final TextCapitalization capitalization;
  final String? Function(String?)? customValidator;
  final Iterable<String>? autofillHints;
  final Widget? prefixIcon;
  final AutovalidateMode? autovalidateMode;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      maxLines: maxLines,
      textCapitalization: capitalization,
      autofillHints: autofillHints,
      autovalidateMode: autovalidateMode,
      validator:
          customValidator ??
          (requiredField
              ? (value) => value == null || value.trim().isEmpty
                    ? 'Enter ${label.toLowerCase()}'
                    : null
              : null),
      style: const TextStyle(
        color: _checkoutInk,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: prefixIcon,
        prefixIconConstraints: prefixIcon == null
            ? null
            : const BoxConstraints(minWidth: 86, minHeight: 48),
        labelStyle: const TextStyle(color: _checkoutMuted, fontSize: 12),
        hintStyle: const TextStyle(color: Color(0xFFA3ADBB), fontSize: 12),
        filled: true,
        fillColor: const Color(0xFFFAFBFD),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 13,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(color: _checkoutLine),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(color: _checkoutLine),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(color: primaryBlue, width: 1.3),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(color: danger, width: 1.3),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(color: danger, width: 1.5),
        ),
        errorStyle: const TextStyle(
          color: danger,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
        errorMaxLines: 2,
      ),
    );
  }
}

class _PaymentMethodCard extends StatelessWidget {
  const _PaymentMethodCard({
    required this.value,
    required this.selectedValue,
    required this.enabled,
    required this.title,
    required this.description,
    required this.icon,
    required this.onChanged,
    this.supportingContent,
  });

  final String value;
  final String selectedValue;
  final bool enabled;
  final String title;
  final String description;
  final IconData icon;
  final ValueChanged<String> onChanged;
  final Widget? supportingContent;

  @override
  Widget build(BuildContext context) {
    final selected = value == selectedValue;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(17),
      child: InkWell(
        onTap: enabled ? () => onChanged(value) : null,
        borderRadius: BorderRadius.circular(17),
        child: Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(17),
            border: Border.all(
              color: selected ? primaryBlue : _checkoutLine,
              width: selected ? 1.3 : 1,
            ),
          ),
          child: Row(
            children: [
              _IconTile(
                icon: icon,
                background: selected ? lightBlue : const Color(0xFFF4F6F9),
                foreground: selected ? primaryBlue : _checkoutMuted,
                size: 40,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: _checkoutInk,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      description,
                      style: const TextStyle(
                        color: _checkoutMuted,
                        fontSize: 11,
                      ),
                    ),
                    if (supportingContent != null) ...[
                      const SizedBox(height: 8),
                      supportingContent!,
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                color: selected ? primaryBlue : const Color(0xFFB8C1CF),
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CostSummary extends StatelessWidget {
  const _CostSummary({
    required this.rows,
    required this.totalLabel,
    required this.total,
  });

  final List<(String, String)> rows;
  final String totalLabel;
  final String total;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: _checkoutLine),
      ),
      child: Column(
        children: [
          for (var index = 0; index < rows.length; index++) ...[
            if (index > 0) const SizedBox(height: 11),
            _AmountRow(label: rows[index].$1, value: rows[index].$2),
          ],
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 13),
            child: Divider(height: 1, color: _checkoutLine),
          ),
          _AmountRow(label: totalLabel, value: total, emphasize: true),
        ],
      ),
    );
  }
}

class _AmountRow extends StatelessWidget {
  const _AmountRow({
    required this.label,
    required this.value,
    this.emphasize = false,
  });

  final String label;
  final String value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: emphasize ? _checkoutInk : _checkoutMuted,
              fontSize: emphasize ? 14 : 12,
              fontWeight: emphasize ? FontWeight.w800 : FontWeight.w500,
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: _checkoutInk,
            fontSize: emphasize ? 18 : 12,
            fontWeight: emphasize ? FontWeight.w900 : FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _CheckoutBottomBar extends StatelessWidget {
  const _CheckoutBottomBar({
    required this.onPlaceOrder,
    required this.paymentMethod,
    required this.amount,
    required this.amountLabel,
    required this.caption,
    required this.submitting,
    required this.orderCreated,
    this.blockedReason,
  });

  final VoidCallback onPlaceOrder;
  final String paymentMethod;
  final double amount;
  final String amountLabel;
  final String caption;
  final bool submitting;
  final bool orderCreated;
  final String? blockedReason;

  @override
  Widget build(BuildContext context) {
    final blocked = blockedReason != null && !orderCreated;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 11, 20, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: _checkoutInk.withValues(alpha: .08),
            blurRadius: 18,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    amountLabel,
                    style: const TextStyle(
                      color: _checkoutMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: .7,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _money(amount),
                    style: const TextStyle(
                      color: _checkoutInk,
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    blocked ? blockedReason! : caption,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: blocked ? warning : _checkoutMuted,
                      fontSize: 11,
                      fontWeight: blocked ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(
              onPressed: submitting || blocked ? null : onPlaceOrder,
              style: FilledButton.styleFrom(
                backgroundColor: primaryBlue,
                foregroundColor: Colors.white,
                minimumSize: const Size(160, 50),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
              child: submitting
                  ? const SizedBox(
                      width: 19,
                      height: 19,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      orderCreated && paymentMethod == 'paymongo'
                          ? 'Open payment'
                          : paymentMethod == 'cod'
                          ? 'Place order'
                          : 'Continue to pay',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CheckoutNote extends StatelessWidget {
  const _CheckoutNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F5FF),
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, color: primaryBlue, size: 17),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'The server verifies current prices, delivery coverage, fees and stock before confirming your order. PayMongo opens securely outside the app.',
              style: TextStyle(
                color: Color(0xFF536782),
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckoutErrorBanner extends StatelessWidget {
  const _CheckoutErrorBanner({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF1F0),
      borderRadius: BorderRadius.circular(15),
      border: Border.all(color: const Color(0xFFFFD7D3)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.error_outline_rounded, color: danger, size: 18),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Checkout needs attention',
                style: TextStyle(
                  color: Color(0xFF9C332C),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                message,
                style: const TextStyle(
                  color: Color(0xFF8D4944),
                  fontSize: 11,
                  height: 1.35,
                ),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: onRetry,
                  style: TextButton.styleFrom(
                    foregroundColor: primaryBlue,
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text(
                    'Retry secure checkout',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

// ===========================================================================
// Shared bits
// ===========================================================================

enum _BannerTone { neutral, warning }

class _InlineBanner extends StatelessWidget {
  const _InlineBanner({
    required this.icon,
    required this.text,
    required this.tone,
  });

  final IconData icon;
  final String text;
  final _BannerTone tone;

  @override
  Widget build(BuildContext context) {
    final warn = tone == _BannerTone.warning;
    final foreground = warn ? const Color(0xFF73591B) : _checkoutInk;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: warn ? const Color(0xFFFFF8E8) : const Color(0xFFEEF1F6),
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

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: const Color(0xFFF5F8FC),
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
            color: _checkoutInk,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

class _StatusTag extends StatelessWidget {
  const _StatusTag({required this.label, required this.open});

  final String label;
  final bool open;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: open ? const Color(0xFFEAF8F0) : const Color(0xFFEEF1F6),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: open ? success : _checkoutMuted,
        fontSize: 11,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

class _IconTile extends StatelessWidget {
  const _IconTile({
    required this.icon,
    required this.background,
    required this.foreground,
    this.size = 45,
  });

  final IconData icon;
  final Color background;
  final Color foreground;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(icon, color: foreground, size: size * .5),
    );
  }
}

class CheckoutTitle extends StatelessWidget {
  final String title;

  const CheckoutTitle(this.title, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      title,
      style: const TextStyle(
        color: _checkoutInk,
        fontSize: 15,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

// ===========================================================================
// Order success
// ===========================================================================

class OrderSuccessScreen extends StatelessWidget {
  final Widget Function() buildMainWrapper;
  final int orderNumber;
  final double total;
  final String paymentMethod;

  const OrderSuccessScreen({
    super.key,
    required this.buildMainWrapper,
    required this.orderNumber,
    required this.total,
    this.paymentMethod = 'cod',
  });

  @override
  Widget build(BuildContext context) {
    final isCod = paymentMethod == 'cod';
    final paymentLabel = isCod ? 'Cash on delivery' : 'PayMongo online payment';

    return Scaffold(
      backgroundColor: paleBlue,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 92,
                  height: 92,
                  decoration: BoxDecoration(
                    color: lightBlue,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: primaryBlue.withValues(alpha: .12),
                        blurRadius: 25,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    size: 48,
                    color: primaryBlue,
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Order placed',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _checkoutInk,
                    fontSize: 27,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Your order has been sent to the station for confirmation.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _checkoutMuted, fontSize: 13),
                ),
                const SizedBox(height: 22),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(19),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(21),
                    border: Border.all(color: _checkoutLine),
                  ),
                  child: Column(
                    children: [
                      const Text(
                        'ORDER TOTAL',
                        style: TextStyle(
                          color: _checkoutMuted,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: .8,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        _money(total),
                        style: const TextStyle(
                          color: _checkoutInk,
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 13),
                      const Divider(height: 1, color: _checkoutLine),
                      const SizedBox(height: 13),
                      Row(
                        children: [
                          const Icon(
                            Icons.payments_outlined,
                            color: primaryBlue,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '#AQ-$orderNumber · $paymentLabel',
                              style: const TextStyle(
                                color: _checkoutInk,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const Icon(
                            Icons.check_circle_rounded,
                            color: success,
                            size: 17,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(19),
                    border: Border.all(color: _checkoutLine),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'What happens next',
                        style: TextStyle(
                          color: _checkoutInk,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 10),
                      const _NextStep(
                        number: '1',
                        text: 'The station confirms your order.',
                      ),
                      const _NextStep(
                        number: '2',
                        text: 'A rider is assigned and heads to you.',
                      ),
                      _NextStep(
                        number: '3',
                        text: isCod
                            ? 'Pay the rider in cash and hand over any empty gallons.'
                            : 'Hand over any empty gallons when your order arrives.',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed: () => _returnHome(context),
                    style: FilledButton.styleFrom(
                      backgroundColor: primaryBlue,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(15),
                      ),
                    ),
                    child: const Text(
                      'Continue',
                      style: TextStyle(fontWeight: FontWeight.w800),
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

  void _returnHome(BuildContext context) {
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => buildMainWrapper()),
      (_) => false,
    );
  }
}

class _NextStep extends StatelessWidget {
  const _NextStep({required this.number, required this.text});

  final String number;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: lightBlue,
            shape: BoxShape.circle,
          ),
          child: Text(
            number,
            style: const TextStyle(
              color: primaryBlue,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              text,
              style: const TextStyle(
                color: _checkoutMuted,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class CustomerCart {
  const CustomerCart({
    required this.id,
    required this.stationId,
    required this.stationName,
    required this.items,
  });

  final String id;
  final String stationId;
  final String stationName;
  final List<CustomerCartItem> items;

  int get itemCount =>
      items.fold<int>(0, (count, item) => count + item.quantity);

  double get itemTotal =>
      items.fold<double>(0, (total, item) => total + item.lineTotal);

  double get subtotal => items.fold<double>(
    0,
    (total, item) => total + item.refillPrice * item.quantity,
  );

  double get containerTotal => items.fold<double>(
    0,
    (total, item) =>
        total +
        (item.containerOption == 'new_gallon'
            ? item.containerPrice * item.quantity
            : 0),
  );

  double get depositTotal => items.fold<double>(
    0,
    (total, item) =>
        total +
        (item.containerOption == 'new_gallon'
            ? item.deposit * item.quantity
            : 0),
  );
}

class CustomerCartItem {
  const CustomerCartItem({
    required this.id,
    required this.productId,
    required this.name,
    required this.waterType,
    required this.containerType,
    required this.containerOption,
    required this.quantity,
    required this.refillPrice,
    required this.containerPrice,
    required this.deposit,
    required this.requiresEmptyContainer,
    required this.returnPolicy,
  });

  final String id;
  final String productId;
  final String name;
  final String waterType;
  final String containerType;
  final String containerOption;
  final int quantity;
  final double refillPrice;
  final double containerPrice;
  final double deposit;
  final bool requiresEmptyContainer;
  final String? returnPolicy;

  double get unitPrice =>
      refillPrice +
      (containerOption == 'new_gallon' ? containerPrice + deposit : 0);

  double get lineTotal => unitPrice * quantity;

  String get optionLabel =>
      containerOption == 'new_gallon' ? 'New container' : 'Refill';
}

class CheckoutOrder {
  const CheckoutOrder({
    required this.id,
    required this.orderNumber,
    required this.total,
    required this.deliveryFee,
  });

  final String id;
  final int orderNumber;
  final double total;
  final double deliveryFee;
}

class CustomerOrder {
  const CustomerOrder({
    required this.id,
    required this.orderNumber,
    required this.stationName,
    required this.status,
    required this.paymentMethod,
    required this.paymentStatus,
    required this.total,
    required this.deliveryFee,
    required this.createdAt,
    required this.addressSnapshot,
    required this.items,
    this.estimatedDeliveryAt,
  });

  final String id;
  final int orderNumber;
  final String stationName;
  final String status;
  final String paymentMethod;
  final String paymentStatus;
  final double total;
  final double deliveryFee;
  final DateTime createdAt;
  final Map<String, dynamic> addressSnapshot;
  final List<CustomerOrderItem> items;
  final DateTime? estimatedDeliveryAt;

  bool get isInProgress => const {
    'pending',
    'confirmed',
    'preparing',
    'ready',
    'rider_assigned',
    'out_for_delivery',
  }.contains(status);

  String get statusLabel => switch (status) {
    'pending' => 'Pending',
    'confirmed' => 'Confirmed',
    'preparing' => 'Preparing',
    'ready' => 'Ready',
    'rider_assigned' => 'Rider assigned',
    'out_for_delivery' => 'Out for delivery',
    'delivered' => 'Delivered',
    'cancelled' => 'Cancelled',
    'failed' => 'Failed',
    _ => status.replaceAll('_', ' '),
  };

  String get paymentMethodLabel => switch (paymentMethod) {
    'cod' => 'Cash on delivery',
    'paymongo' => 'PayMongo',
    _ => paymentMethod,
  };

  String get formattedNumber => '#AQ-${orderNumber.toString().padLeft(4, '0')}';

  String get formattedDate {
    final local = createdAt.toLocal();
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final period = local.hour < 12 ? 'AM' : 'PM';
    return '${months[local.month - 1]} ${local.day}, ${local.year} · '
        '$hour:$minute $period';
  }

  String get itemSummary {
    if (items.isEmpty) return 'No item details available';
    final first = items.first;
    final firstLine = '${first.quantity} × ${first.productName}';
    if (items.length == 1) return firstLine;
    return '$firstLine + ${items.length - 1} more';
  }

  String get deliveryAddress {
    final parts =
        [
              addressSnapshot['address_line'],
              addressSnapshot['barangay'],
              addressSnapshot['city'],
              addressSnapshot['province'],
            ]
            .whereType<String>()
            .map((part) => part.trim())
            .where((part) => part.isNotEmpty)
            .toList(growable: false);
    return parts.isEmpty ? 'Address not available' : parts.join(', ');
  }
}

class CustomerOrderItem {
  const CustomerOrderItem({
    required this.productName,
    required this.waterType,
    required this.containerType,
    required this.containerOption,
    required this.quantity,
    required this.unitRefillPrice,
    required this.unitContainerPrice,
    required this.unitDeposit,
    required this.lineTotal,
  });

  final String productName;
  final String waterType;
  final String containerType;
  final String containerOption;
  final int quantity;
  final double unitRefillPrice;
  final double unitContainerPrice;
  final double unitDeposit;
  final double lineTotal;

  String get optionLabel =>
      containerOption == 'new_gallon' ? 'New container' : 'Refill';
}

class CustomerDeliveryTracking {
  const CustomerDeliveryTracking({
    required this.order,
    this.deliveryStatus,
    this.riderName,
    this.riderPhone,
    this.estimatedDeliveryAt,
    this.riderLatitude,
    this.riderLongitude,
    this.locationRecordedAt,
  });

  final CustomerOrder order;
  final String? deliveryStatus;
  final String? riderName;
  final String? riderPhone;
  final DateTime? estimatedDeliveryAt;
  final double? riderLatitude;
  final double? riderLongitude;
  final DateTime? locationRecordedAt;

  bool get hasRiderLocation => riderLatitude != null && riderLongitude != null;
}

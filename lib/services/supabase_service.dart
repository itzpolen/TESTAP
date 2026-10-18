import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_config.dart';
import '../models/customer_cart.dart';
import '../models/nearby_station.dart';
import '../models/station_delivery_info.dart';
import '../models/station_marketplace_product.dart';
import '../models/station_social_links.dart';
import 'location_service.dart';

class SupabaseService {
  const SupabaseService._();

  static SupabaseClient get client => SupabaseConfig.client;

  static Future<AuthResponse> signIn({
    required String identity,
    required String password,
  }) {
    final normalizedIdentity = identity.trim();
    if (normalizedIdentity.contains('@')) {
      return client.auth.signInWithPassword(
        email: normalizedIdentity,
        password: password,
      );
    }
    return client.auth.signInWithPassword(
      phone: normalizedIdentity,
      password: password,
    );
  }

  static Future<bool> signInWithOAuth({
    required OAuthProvider provider,
    String? redirectTo,
  }) {
    return client.auth.signInWithOAuth(provider, redirectTo: redirectTo);
  }

  static Future<AuthResponse> signUp({
    required String fullName,
    required String phone,
    required String email,
    required String password,
  }) {
    return client.auth.signUp(
      email: email.trim(),
      password: password,
      data: {'full_name': fullName.trim(), 'phone': phone.trim()},
    );
  }

  static Future<Map<String, dynamic>?> getCurrentProfile() async {
    final user = client.auth.currentUser;
    if (user == null) return null;
    return client
        .from('profiles')
        .select('id, full_name, phone, avatar_path, status, created_at')
        .eq('id', user.id)
        .maybeSingle();
  }

  static Future<void> updateCurrentProfile({
    required String fullName,
    required String phone,
  }) async {
    final userId = client.auth.currentUser?.id;
    if (userId == null) throw StateError('Sign in to update your profile.');
    final normalizedName = fullName.trim();
    final normalizedPhone = phone.trim();
    if (normalizedName.isEmpty) {
      throw const FormatException('Enter your name.');
    }
    final updated = await client
        .from('profiles')
        .update({
          'full_name': normalizedName,
          'phone': normalizedPhone.isEmpty ? null : normalizedPhone,
        })
        .eq('id', userId)
        .select('id')
        .maybeSingle();
    if (updated == null) {
      throw StateError('Your profile could not be found. Sign in again.');
    }
  }

  static Future<DeliveryLocation?> getCustomerDeliveryLocation() async {
    final userId = client.auth.currentUser?.id;
    if (userId == null) return null;

    final savedAddress = await client
        .from('addresses')
        .select('address_line, barangay, city, province, latitude, longitude')
        .eq('user_id', userId)
        .eq('is_default', true)
        .maybeSingle();
    if (savedAddress != null) {
      final addressLine = savedAddress['address_line'];
      final barangay = savedAddress['barangay'];
      final city = savedAddress['city'];
      final province = savedAddress['province'];
      final latitude = savedAddress['latitude'];
      final longitude = savedAddress['longitude'];
      if (addressLine is! String ||
          (barangay != null && barangay is! String) ||
          city is! String ||
          province is! String ||
          (latitude != null && latitude is! num) ||
          (longitude != null && longitude is! num)) {
        throw const FormatException('The saved customer address is invalid.');
      }
      final addressParts = <String>[
        addressLine,
        if (barangay is String && barangay.isNotEmpty) barangay,
        city,
        province,
      ];
      return DeliveryLocation(
        latitude: (latitude as num?)?.toDouble(),
        longitude: (longitude as num?)?.toDouble(),
        address: addressParts.join(', '),
        addressLine: addressLine,
        barangay: barangay as String?,
        city: city,
        province: province,
      );
    }
    return null;
  }

  static Future<DeliveryLocation?> getCustomerBrowsingLocation() async {
    final userId = client.auth.currentUser?.id;
    if (userId == null) return null;
    final row = await client
        .from('user_preferences')
        .select('preferences')
        .eq('user_id', userId)
        .maybeSingle();
    final preferences = row?['preferences'];
    if (preferences is! Map) return null;
    final saved = preferences['browsing_location'];
    if (saved is! Map) return null;

    final latitude = saved['latitude'];
    final longitude = saved['longitude'];
    if (latitude is! num ||
        longitude is! num ||
        !latitude.toDouble().isFinite ||
        !longitude.toDouble().isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      throw const FormatException('The saved browsing location is invalid.');
    }
    return DeliveryLocation(
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
    );
  }

  static Future<void> saveCustomerBrowsingLocation(
    DeliveryLocation location,
  ) async {
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;
    final latitude = location.latitude;
    final longitude = location.longitude;
    if (latitude == null ||
        longitude == null ||
        !latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      throw const FormatException(
        'A valid latitude and longitude are required to save a browsing location.',
      );
    }

    final existing = await client
        .from('user_preferences')
        .select('preferences')
        .eq('user_id', userId)
        .maybeSingle();
    final rawPreferences = existing?['preferences'];
    final preferences = rawPreferences is Map
        ? Map<String, dynamic>.from(rawPreferences)
        : <String, dynamic>{};
    preferences['browsing_location'] = {
      'latitude': latitude,
      'longitude': longitude,
    };
    await client.from('user_preferences').upsert({
      'user_id': userId,
      'preferences': preferences,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  static Future<void> saveCustomerDeliveryLocation(
    DeliveryLocation location,
  ) async {
    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      throw Exception('Sign in before saving your delivery location.');
    }
    if ((location.latitude == null) != (location.longitude == null)) {
      throw const FormatException(
        'The delivery location must include both coordinates or neither.',
      );
    }

    final addressLine = location.addressLine?.trim();
    final barangay = location.barangay?.trim();
    final city = location.city?.trim();
    final province = location.province?.trim();
    if (addressLine?.isNotEmpty == true &&
        city?.isNotEmpty == true &&
        province?.isNotEmpty == true) {
      final currentDefault = await client
          .from('addresses')
          .select(
            'id, address_line, barangay, city, province, latitude, longitude',
          )
          .eq('user_id', userId)
          .eq('is_default', true)
          .maybeSingle();
      final sameDefault =
          currentDefault != null &&
          currentDefault['address_line'] == addressLine &&
          currentDefault['barangay'] == barangay &&
          currentDefault['city'] == city &&
          currentDefault['province'] == province &&
          currentDefault['latitude'] == location.latitude &&
          currentDefault['longitude'] == location.longitude;
      if (!sameDefault) {
        final addressValues = {
          'address_line': addressLine,
          'barangay': barangay,
          'city': city,
          'province': province,
          'latitude': location.latitude,
          'longitude': location.longitude,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        };
        if (currentDefault != null) {
          await client
              .from('addresses')
              .update(addressValues)
              .eq('id', currentDefault['id'])
              .eq('user_id', userId);
        } else {
          final savedAddress = await client
              .from('addresses')
              .insert({
                ...addressValues,
                'user_id': userId,
                'label': 'Home',
                'is_default': false,
              })
              .select('id')
              .single();
          await client.rpc(
            'set_default_address',
            params: {'p_address_id': savedAddress['id']},
          );
        }
      }
    }
  }

  static Future<List<NearbyStation>> getNearbyStations({
    required double latitude,
    required double longitude,
    required double radiusKm,
    int pageSize = 20,
    int pageOffset = 0,
  }) async {
    final rows =
        await client.rpc(
              'nearby_stations_with_barangay',
              params: {
                'p_latitude': latitude,
                'p_longitude': longitude,
                'p_radius_km': radiusKm,
                'p_filters': <String, dynamic>{},
                'p_page_size': pageSize,
                'p_page_offset': pageOffset,
              },
            )
            as List<dynamic>;

    return rows
        .map(
          (row) =>
              NearbyStation.fromJson(Map<String, dynamic>.from(row as Map)),
        )
        .toList(growable: false);
  }

  static Future<List<StationMarketplaceProduct>> getStationProducts(
    String stationId,
  ) async {
    final products =
        await client
                .from('station_products')
                .select(
                  'id, name, description, water_type_id, container_type_id, '
                  'refill_available, refill_price, new_container_available, '
                  'new_container_price, deposit_amount, requires_empty_container, '
                  'return_policy, stock_quantity, max_order_quantity',
                )
                .eq('station_id', stationId)
                .eq('status', 'active')
                .order('name')
            as List<dynamic>;
    if (products.isEmpty) return const [];

    final productRows = products
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList(growable: false);
    final productIds = productRows
        .map((product) => product['id'] as String)
        .toList(growable: false);
    final waterTypeIds = productRows
        .map((product) => product['water_type_id'] as String)
        .toSet()
        .toList(growable: false);
    final containerTypeIds = productRows
        .map((product) => product['container_type_id'] as String)
        .toSet()
        .toList(growable: false);

    final results = await Future.wait([
      client
          .from('station_product_images')
          .select('product_id, storage_path, alt_text, sort_order')
          .inFilter('product_id', productIds)
          .order('sort_order'),
      client
          .from('water_types')
          .select('id, name')
          .inFilter('id', waterTypeIds),
      client
          .from('container_types')
          .select('id, name, volume_liters')
          .inFilter('id', containerTypeIds),
      client
          .from('container_policies')
          .select(
            'container_type_id, deposit_amount, requires_empty_return, '
            'return_policy',
          )
          .eq('station_id', stationId)
          .eq('is_active', true),
    ]);

    final imagesByProduct = <String, List<StationMarketplaceProductImage>>{};
    for (final row in results[0] as List<dynamic>) {
      final image = Map<String, dynamic>.from(row as Map);
      final productImages = imagesByProduct[image['product_id'] as String] ??=
          <StationMarketplaceProductImage>[];
      productImages.add(
        StationMarketplaceProductImage(
          storagePath: image['storage_path'] as String,
          altText: image['alt_text'] as String?,
        ),
      );
    }

    final waterNames = {
      for (final row in results[1] as List<dynamic>)
        (row as Map<String, dynamic>)['id'] as String: (row)['name'] as String,
    };
    final containerNames = {
      for (final row in results[2] as List<dynamic>)
        (row as Map<String, dynamic>)['id'] as String: (row)['name'] as String,
    };
    final containerVolumes = {
      for (final row in results[2] as List<dynamic>)
        (row as Map<String, dynamic>)['id'] as String:
            (row)['volume_liters'] as num?,
    };
    final policiesByContainer = {
      for (final row in results[3] as List<dynamic>)
        (row as Map<String, dynamic>)['container_type_id'] as String: row,
    };

    return productRows
        .map((product) {
          final refillAvailable = product['refill_available'] as bool;
          final newContainerAvailable =
              product['new_container_available'] as bool;
          final policy = policiesByContainer[product['container_type_id']];
          final deposit =
              (product['deposit_amount'] as num?)?.toDouble() ??
              (policy?['deposit_amount'] as num?)?.toDouble() ??
              0;
          final prices = <double>[
            if (refillAvailable) (product['refill_price'] as num).toDouble(),
            if (newContainerAvailable)
              (product['refill_price'] as num).toDouble() +
                  (product['new_container_price'] as num).toDouble() +
                  deposit,
          ];
          if (prices.isEmpty) {
            throw const FormatException(
              'An active station product has no purchasable option.',
            );
          }

          final productId = product['id'] as String;
          return StationMarketplaceProduct(
            id: productId,
            name: product['name'] as String,
            waterType: waterNames[product['water_type_id']] ?? 'Drinking water',
            containerType:
                containerNames[product['container_type_id']] ?? 'Container',
            containerVolumeLiters:
                containerVolumes[product['container_type_id']]?.toDouble(),
            startingPrice: prices.reduce((a, b) => a < b ? a : b),
            refillAvailable: refillAvailable,
            refillPrice: (product['refill_price'] as num).toDouble(),
            newContainerAvailable: newContainerAvailable,
            newContainerPrice: (product['new_container_price'] as num?)
                ?.toDouble(),
            depositAmount: deposit,
            stockQuantity: (product['stock_quantity'] as num?)?.toInt(),
            maxOrderQuantity: (product['max_order_quantity'] as num).toInt(),
            requiresEmptyContainer:
                (product['requires_empty_container'] as bool?) ??
                (policy?['requires_empty_return'] as bool?) ??
                false,
            returnPolicy:
                product['return_policy'] as String? ??
                policy?['return_policy'] as String?,
            images: List.unmodifiable(imagesByProduct[productId] ?? const []),
            description: product['description'] as String?,
          );
        })
        .toList(growable: false);
  }

  /// Seller delivery settings used by the storefront. Returns null when the
  /// station row is not readable, so the screen can simply hide those details.
  static Future<StationDeliveryInfo?> getStationDeliveryInfo(
    String stationId,
  ) async {
    final results = await Future.wait<dynamic>([
      client
          .from('stations')
          .select(
            'service_radius_km, default_delivery_fee, minimum_order_amount',
          )
          .eq('id', stationId)
          .maybeSingle(),
      client
          .from('station_operating_hours')
          .select('weekday, opens_at, closes_at, is_closed')
          .eq('station_id', stationId),
    ]);

    final station = results[0] as Map<String, dynamic>?;
    if (station == null) return null;
    final hours = (results[1] as List<dynamic>)
        .map(
          (row) => StationOperatingHour.fromJson(
            Map<String, dynamic>.from(row as Map),
          ),
        )
        .toList(growable: false);

    return StationDeliveryInfo(
      serviceRadiusKm: (station['service_radius_km'] as num?)?.toDouble(),
      deliveryFee: (station['default_delivery_fee'] as num?)?.toDouble(),
      minimumOrderAmount: (station['minimum_order_amount'] as num?)?.toDouble(),
      hours: hours,
    );
  }

  static Future<String?> getPublicStationPhone(String stationId) async {
    final phone = await client.rpc(
      'get_public_station_phone',
      params: {'p_station_id': stationId},
    );
    if (phone == null) return null;
    if (phone is! String || phone.trim().isEmpty) {
      throw const FormatException('The station contact number is invalid.');
    }
    return phone.trim();
  }

  static Future<StationSocialLinks?> getPublicStationSocialLinks(
    String stationId,
  ) async {
    final result = await client.rpc(
      'get_public_station_social_links',
      params: {'p_station_id': stationId},
    );
    if (result == null) return null;
    if (result is! Map) {
      throw const FormatException('The station social links are invalid.');
    }
    return StationSocialLinks.fromJson(Map<String, dynamic>.from(result));
  }

  static Future<void> addToCart({
    required String stationId,
    required String productId,
    required String containerOption,
    int quantity = 1,
  }) async {
    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      throw Exception('Sign in to add items to your cart.');
    }
    if (containerOption != 'refill_existing' &&
        containerOption != 'new_gallon') {
      throw ArgumentError.value(containerOption, 'containerOption');
    }
    if (quantity <= 0) {
      throw ArgumentError.value(quantity, 'quantity');
    }

    final product = await client
        .from('station_products')
        .select(
          'id, station_id, status, refill_available, new_container_available, '
          'stock_quantity, max_order_quantity',
        )
        .eq('id', productId)
        .eq('station_id', stationId)
        .eq('status', 'active')
        .maybeSingle();
    if (product == null) {
      throw Exception('This product is no longer available.');
    }
    final optionAvailable = containerOption == 'refill_existing'
        ? product['refill_available'] as bool
        : product['new_container_available'] as bool;
    if (!optionAvailable) {
      throw Exception('This container option is no longer available.');
    }

    final existingCart = await client
        .from('carts')
        .select('id, station_id')
        .eq('user_id', userId)
        .eq('status', 'active')
        .maybeSingle();

    String cartId;
    if (existingCart == null) {
      final created = await client
          .from('carts')
          .insert({'user_id': userId, 'station_id': stationId})
          .select('id')
          .single();
      cartId = created['id'] as String;
    } else {
      cartId = existingCart['id'] as String;
      final activeStationId = existingCart['station_id'] as String?;
      if (activeStationId != null && activeStationId != stationId) {
        final itemCount = await client
            .from('cart_items')
            .count()
            .eq('cart_id', cartId);
        if (itemCount > 0) {
          throw Exception(
            'Your cart already has items from another station. '
            'Remove them before shopping at this station.',
          );
        }
        await client
            .from('carts')
            .update({'station_id': stationId})
            .eq('id', cartId);
      } else if (activeStationId == null) {
        await client
            .from('carts')
            .update({'station_id': stationId})
            .eq('id', cartId);
      }
    }

    final existingItem = await client
        .from('cart_items')
        .select('id, quantity')
        .eq('cart_id', cartId)
        .eq('product_id', productId)
        .eq('container_option', containerOption)
        .maybeSingle();

    final productItems = await client
        .from('cart_items')
        .select('quantity')
        .eq('cart_id', cartId)
        .eq('product_id', productId);
    final currentQuantity = (productItems as List<dynamic>).fold<int>(
      0,
      (sum, row) =>
          sum + ((row as Map<String, dynamic>)['quantity'] as num).toInt(),
    );
    final maxOrderQuantity = (product['max_order_quantity'] as num).toInt();
    final stockQuantity = (product['stock_quantity'] as num?)?.toInt();
    final maxAllowedQuantity = stockQuantity == null
        ? maxOrderQuantity
        : (stockQuantity < maxOrderQuantity ? stockQuantity : maxOrderQuantity);
    if (currentQuantity + quantity > maxAllowedQuantity) {
      throw Exception(
        stockQuantity != null && stockQuantity < maxOrderQuantity
            ? 'Only $stockQuantity of this product are currently in stock.'
            : 'You can add up to $maxOrderQuantity of this product per order.',
      );
    }

    if (existingItem == null) {
      await client.from('cart_items').insert({
        'cart_id': cartId,
        'product_id': productId,
        'container_option': containerOption,
        'quantity': quantity,
      });
    } else {
      await client
          .from('cart_items')
          .update({'quantity': (existingItem['quantity'] as int) + quantity})
          .eq('id', existingItem['id'] as String);
    }
  }

  static Future<CustomerCart?> getActiveCart() async {
    final userId = client.auth.currentUser?.id;
    if (userId == null) return null;

    final cart = await client
        .from('carts')
        .select('id, station_id')
        .eq('user_id', userId)
        .eq('status', 'active')
        .maybeSingle();
    if (cart == null) return null;

    final cartId = cart['id'] as String;
    final stationId = cart['station_id'] as String?;
    if (stationId == null) {
      throw const FormatException('The active cart is missing its station.');
    }
    final rows =
        await client
                .from('cart_items')
                .select('id, product_id, container_option, quantity')
                .eq('cart_id', cartId)
                .order('created_at')
            as List<dynamic>;
    if (rows.isEmpty) {
      return CustomerCart(
        id: cartId,
        stationId: stationId,
        stationName: await _getStationName(stationId),
        items: const [],
      );
    }

    final itemRows = rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList(growable: false);
    final productIds = itemRows
        .map((row) => row['product_id'] as String)
        .toSet()
        .toList(growable: false);
    final productRows =
        await client
                .from('station_products')
                .select(
                  'id, name, water_type_id, container_type_id, refill_price, '
                  'new_container_price, deposit_amount, requires_empty_container, '
                  'return_policy',
                )
                .inFilter('id', productIds)
            as List<dynamic>;
    final productsById = {
      for (final raw in productRows)
        (raw as Map<String, dynamic>)['id'] as String: raw,
    };

    final waterIds = productRows
        .map((row) => (row as Map<String, dynamic>)['water_type_id'] as String)
        .toSet()
        .toList(growable: false);
    final containerIds = productRows
        .map(
          (row) => (row as Map<String, dynamic>)['container_type_id'] as String,
        )
        .toSet()
        .toList(growable: false);
    final typeResults = await Future.wait([
      client.from('water_types').select('id, name').inFilter('id', waterIds),
      client
          .from('container_types')
          .select('id, name')
          .inFilter('id', containerIds),
      client
          .from('container_policies')
          .select(
            'container_type_id, deposit_amount, requires_empty_return, '
            'return_policy',
          )
          .eq('station_id', stationId)
          .eq('is_active', true),
    ]);
    final waterNames = {
      for (final row in typeResults[0] as List<dynamic>)
        (row as Map<String, dynamic>)['id'] as String: row['name'] as String,
    };
    final containerNames = {
      for (final row in typeResults[1] as List<dynamic>)
        (row as Map<String, dynamic>)['id'] as String: row['name'] as String,
    };
    final policiesByContainer = {
      for (final row in typeResults[2] as List<dynamic>)
        (row as Map<String, dynamic>)['container_type_id'] as String: row,
    };

    final items = <CustomerCartItem>[];
    for (final row in itemRows) {
      final product = productsById[row['product_id']];
      if (product == null) {
        throw const FormatException(
          'A product in your cart is no longer available.',
        );
      }
      final productId = row['product_id'] as String;
      final policy = policiesByContainer[product['container_type_id']];
      items.add(
        CustomerCartItem(
          id: row['id'] as String,
          productId: productId,
          name: product['name'] as String,
          waterType: waterNames[product['water_type_id']] ?? 'Drinking water',
          containerType:
              containerNames[product['container_type_id']] ?? 'Container',
          containerOption: row['container_option'] as String,
          quantity: row['quantity'] as int,
          refillPrice: (product['refill_price'] as num).toDouble(),
          containerPrice:
              (product['new_container_price'] as num?)?.toDouble() ?? 0,
          deposit:
              (product['deposit_amount'] as num?)?.toDouble() ??
              (policy?['deposit_amount'] as num?)?.toDouble() ??
              0,
          requiresEmptyContainer:
              (product['requires_empty_container'] as bool?) ??
              (policy?['requires_empty_return'] as bool?) ??
              false,
          returnPolicy:
              product['return_policy'] as String? ??
              policy?['return_policy'] as String?,
        ),
      );
    }
    return CustomerCart(
      id: cartId,
      stationId: stationId,
      stationName: await _getStationName(stationId),
      items: List.unmodifiable(items),
    );
  }

  static Future<String> _getStationName(String stationId) async {
    final station = await client
        .from('stations')
        .select('display_name')
        .eq('id', stationId)
        .maybeSingle();
    return station?['display_name'] as String? ?? 'Water station';
  }

  static Future<void> updateCartItemQuantity({
    required String itemId,
    required int quantity,
  }) async {
    if (quantity < 0) throw ArgumentError.value(quantity, 'quantity');
    if (quantity == 0) {
      await client.from('cart_items').delete().eq('id', itemId);
      return;
    }
    final item = await client
        .from('cart_items')
        .select('cart_id, product_id')
        .eq('id', itemId)
        .single();
    final cartId = item['cart_id'] as String;
    final productId = item['product_id'] as String;

    final product = await client
        .from('station_products')
        .select('status, stock_quantity, max_order_quantity')
        .eq('id', productId)
        .maybeSingle();
    if (product == null || product['status'] != 'active') {
      throw Exception('This product is no longer available.');
    }

    final maxOrder = (product['max_order_quantity'] as num).toInt();
    final stock = (product['stock_quantity'] as num?)?.toInt();
    final maxAllowed = stock == null
        ? maxOrder
        : (stock < maxOrder ? stock : maxOrder);

    // Other lines of the same product (refill vs new gallon) share one limit.
    final others = await client
        .from('cart_items')
        .select('quantity')
        .eq('cart_id', cartId)
        .eq('product_id', productId)
        .neq('id', itemId);
    final otherQuantity = (others as List<dynamic>).fold<int>(
      0,
      (sum, row) =>
          sum + ((row as Map<String, dynamic>)['quantity'] as num).toInt(),
    );
    if (otherQuantity + quantity > maxAllowed) {
      throw Exception(
        stock != null && stock < maxOrder
            ? 'Only $stock of this product are currently in stock.'
            : 'You can order up to $maxOrder of this product.',
      );
    }

    await client
        .from('cart_items')
        .update({'quantity': quantity})
        .eq('id', itemId);
  }

  static Future<CheckoutOrder> createOrderFromCart({
    required CustomerCart cart,
    required Map<String, dynamic> address,
    required String paymentMethod,
    String? customerNotes,
  }) async {
    if (paymentMethod != 'cod' && paymentMethod != 'paymongo') {
      throw ArgumentError.value(paymentMethod, 'paymentMethod');
    }
    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      throw Exception('Sign in before placing an order.');
    }

    final existingOrder = await client
        .from('orders')
        .select('id, order_number, total, delivery_fee')
        .eq('cart_id', cart.id)
        .eq('customer_id', userId)
        .maybeSingle();
    if (existingOrder != null) {
      return CheckoutOrder(
        id: existingOrder['id'] as String,
        orderNumber: (existingOrder['order_number'] as num).toInt(),
        total: (existingOrder['total'] as num).toDouble(),
        deliveryFee: (existingOrder['delivery_fee'] as num).toDouble(),
      );
    }

    final savedAddress = await client
        .from('addresses')
        .insert({...address, 'user_id': userId})
        .select('id')
        .single();
    final items = cart.items
        .map(
          (item) => {
            'product_id': item.productId,
            'container_option': item.containerOption,
            'quantity': item.quantity,
          },
        )
        .toList(growable: false);
    final orderId = await client.rpc(
      'create_order',
      params: {
        'p_station_id': cart.stationId,
        'p_address_id': savedAddress['id'],
        'p_items': items,
        'p_payment_method': paymentMethod,
        'p_customer_notes': customerNotes,
        'p_cart_id': cart.id,
      },
    );
    if (orderId is! String || orderId.isEmpty) {
      throw const FormatException('The order service returned no order ID.');
    }
    final order = await client
        .from('orders')
        .select('id, order_number, total, delivery_fee')
        .eq('id', orderId)
        .eq('customer_id', userId)
        .single();
    return CheckoutOrder(
      id: order['id'] as String,
      orderNumber: (order['order_number'] as num).toInt(),
      total: (order['total'] as num).toDouble(),
      deliveryFee: (order['delivery_fee'] as num).toDouble(),
    );
  }

  static Future<String> createPayMongoCheckout(String orderId) async {
    final response = await client.functions.invoke(
      'create_paymongo_checkout',
      body: {'order_id': orderId},
    );
    if (response.status < 200 || response.status >= 300) {
      final payload = response.data;
      final message = payload is Map ? payload['error'] : null;
      throw StateError(
        message is String
            ? message
            : 'Could not start PayMongo checkout (HTTP ${response.status}).',
      );
    }
    final payload = response.data;
    if (payload is! Map || payload['checkout_url'] is! String) {
      throw const FormatException('PayMongo did not return a checkout URL.');
    }
    final checkoutUri = Uri.tryParse(payload['checkout_url'] as String);
    if (checkoutUri == null ||
        checkoutUri.scheme != 'https' ||
        checkoutUri.host.isEmpty) {
      throw const FormatException(
        'PayMongo returned an invalid secure checkout URL.',
      );
    }
    return checkoutUri.toString();
  }

  /// Asks the reconcile_payment Edge Function to pull the real payment status
  /// from PayMongo and apply it. Works even when the webhook was missed.
  static Future<
    ({String? status, bool latePaymentRefundRequired, bool pending})
  >
  reconcileOrderPayment(String orderId) async {
    final row = await client
        .from('payments')
        .select('id')
        .eq('order_id', orderId)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    final paymentId = row?['id'];
    if (paymentId is! String) {
      throw StateError(
        'Could not find a payment for order $orderId. Make sure you are signed '
        'in as the customer who placed this order.',
      );
    }
    final response = await client.functions.invoke(
      'reconcile_payment',
      body: {'payment_id': paymentId},
    );
    if (response.status < 200 || response.status >= 300) {
      final payload = response.data;
      final message = payload is Map ? payload['error'] : null;
      throw Exception(
        message is String
            ? message
            : 'Payment reconciliation failed (HTTP ${response.status}).',
      );
    }
    final payload = response.data;
    if (payload is! Map) {
      throw const FormatException(
        'Payment reconciliation returned an invalid response.',
      );
    }
    return (
      status: payload['status'] is String ? payload['status'] as String : null,
      latePaymentRefundRequired:
          payload['late_payment_refund_required'] == true,
      pending: payload['pending'] == true,
    );
  }

  /// Latest payment attempt for an order. Uses the paid_at / failed_at
  /// columns, so it does not depend on the payment_status enum labels.
  static Future<({bool paid, String? failureReason})> getOrderPaymentResult(
    String orderId,
  ) async {
    final row = await client
        .from('payments')
        .select('status, paid_at, failed_at, failure_reason')
        .eq('order_id', orderId)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    if (row == null) return (paid: false, failureReason: null);
    final status = row['status'] as String?;
    final paid = row['paid_at'] != null || status == 'paid';
    // 'failed' and 'cancelled' are the payment_status enum's terminal states.
    // A failed attempt inside a live checkout stays 'processing' so the
    // customer can retry on the PayMongo page.
    final failureReason = paid
        ? null
        : status == 'failed'
        ? 'The payment failed. Please try again.'
        : status == 'cancelled'
        ? 'This payment expired or was cancelled, so the order was '
              'cancelled. Please place a new order.'
        : null;
    return (paid: paid, failureReason: failureReason);
  }

  static Future<List<CustomerOrder>> getCustomerOrders() async {
    final userId = client.auth.currentUser?.id;
    if (userId == null) return const [];

    final results = await Future.wait([
      client
          .from('orders')
          .select(
            'id, order_number, status, payment_method, total, delivery_fee, '
            'address_snapshot, station_snapshot, created_at, estimated_delivery_at',
          )
          .eq('customer_id', userId)
          .order('created_at', ascending: false),
      client
          .from('customer_order_dismissals')
          .select('order_id')
          .eq('user_id', userId),
    ]);
    final rawOrders = results[0] as List<dynamic>;
    final dismissedOrderIds = (results[1] as List<dynamic>)
        .map((row) => (row as Map)['order_id'] as String)
        .toSet();
    final visibleRawOrders = rawOrders
        .where((row) => !dismissedOrderIds.contains((row as Map)['id']))
        .toList(growable: false);
    if (visibleRawOrders.isEmpty) return const [];

    final orders = visibleRawOrders
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList(growable: false);
    final orderIds = orders
        .map((order) => order['id'] as String)
        .toList(growable: false);
    final related = await Future.wait([
      client
          .from('order_items')
          .select(
            'order_id, product_name_snapshot, water_type_snapshot, '
            'container_type_snapshot, container_option, quantity, '
            'unit_refill_price, unit_container_price, unit_deposit, line_total',
          )
          .inFilter('order_id', orderIds)
          .order('created_at'),
      client
          .from('payments')
          .select('order_id, status, created_at')
          .inFilter('order_id', orderIds)
          .order('created_at', ascending: false),
    ]);

    final itemsByOrder = <String, List<CustomerOrderItem>>{};
    for (final raw in related[0] as List<dynamic>) {
      final item = Map<String, dynamic>.from(raw as Map);
      final orderId = item['order_id'] as String;
      (itemsByOrder[orderId] ??= <CustomerOrderItem>[]).add(
        CustomerOrderItem(
          productName: item['product_name_snapshot'] as String,
          waterType: item['water_type_snapshot'] as String,
          containerType: item['container_type_snapshot'] as String,
          containerOption: item['container_option'] as String,
          quantity: (item['quantity'] as num).toInt(),
          unitRefillPrice: (item['unit_refill_price'] as num).toDouble(),
          unitContainerPrice: (item['unit_container_price'] as num).toDouble(),
          unitDeposit: (item['unit_deposit'] as num).toDouble(),
          lineTotal: (item['line_total'] as num).toDouble(),
        ),
      );
    }
    final paymentStatusByOrder = <String, String>{};
    for (final raw in related[1] as List<dynamic>) {
      final payment = Map<String, dynamic>.from(raw as Map);
      paymentStatusByOrder.putIfAbsent(
        payment['order_id'] as String,
        () => payment['status'] as String,
      );
    }

    return orders
        .map((order) {
          final address = order['address_snapshot'];
          final stationSnapshot = order['station_snapshot'];
          final stationName = stationSnapshot is Map
              ? (stationSnapshot['display_name'] as String?)?.trim()
              : null;
          final createdAt = DateTime.tryParse(order['created_at'] as String);
          if (createdAt == null) {
            throw const FormatException(
              'An order has an invalid created_at value.',
            );
          }
          return CustomerOrder(
            id: order['id'] as String,
            orderNumber: (order['order_number'] as num).toInt(),
            stationName: stationName?.isNotEmpty == true
                ? stationName!
                : 'Water station',
            status: order['status'] as String,
            paymentMethod: order['payment_method'] as String,
            paymentStatus:
                paymentStatusByOrder[order['id'] as String] ?? 'pending',
            total: (order['total'] as num).toDouble(),
            deliveryFee: (order['delivery_fee'] as num).toDouble(),
            createdAt: createdAt,
            addressSnapshot: address is Map
                ? Map<String, dynamic>.from(address)
                : const {},
            items: List.unmodifiable(itemsByOrder[order['id']] ?? const []),
            estimatedDeliveryAt: order['estimated_delivery_at'] is String
                ? DateTime.tryParse(order['estimated_delivery_at'] as String)
                : null,
          );
        })
        .toList(growable: false);
  }

  static Future<void> dismissCancelledCustomerOrder(String orderId) async {
    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      throw Exception('Sign in to remove a cancelled order from your history.');
    }
    await client.from('customer_order_dismissals').insert({
      'user_id': userId,
      'order_id': orderId,
    });
  }

  static Future<List<CustomerDeliveryTracking>>
  getCustomerOrderTracking() async {
    final orders = (await getCustomerOrders())
        .where((order) => order.isInProgress || order.status == 'cancelled')
        .toList(growable: false);
    if (orders.isEmpty) return const [];

    final deliveries = await client
        .from('deliveries')
        .select('id, order_id, status, rider_name, rider_phone, updated_at')
        .inFilter('order_id', orders.map((order) => order.id).toList());
    final deliveryByOrderId = <String, Map<String, dynamic>>{};
    final deliveryIds = <String>[];
    for (final raw in deliveries as List<dynamic>) {
      final row = Map<String, dynamic>.from(raw as Map);
      final orderId = row['order_id'] as String;
      final deliveryId = row['id'] as String;
      deliveryByOrderId[orderId] = row;
      deliveryIds.add(deliveryId);
    }

    final latestLocationByDeliveryId = <String, Map<String, dynamic>>{};
    if (deliveryIds.isNotEmpty) {
      final locationResults = await Future.wait(
        deliveryIds.map(
          (deliveryId) => client
              .from('delivery_tracking')
              .select('delivery_id, latitude, longitude, recorded_at')
              .eq('delivery_id', deliveryId)
              .order('recorded_at', ascending: false)
              .limit(1),
        ),
      );
      for (final result in locationResults) {
        if (result.isEmpty) continue;
        final row = Map<String, dynamic>.from(result.first);
        latestLocationByDeliveryId[row['delivery_id'] as String] = row;
      }
    }

    return orders
        .map((order) {
          final delivery = deliveryByOrderId[order.id];
          final location = delivery == null
              ? null
              : latestLocationByDeliveryId[delivery['id'] as String];
          final latitude = location?['latitude'];
          final longitude = location?['longitude'];
          final recordedAt = location?['recorded_at'];
          return CustomerDeliveryTracking(
            order: order,
            deliveryStatus: delivery?['status'] as String?,
            riderName: delivery?['rider_name'] as String?,
            riderPhone: delivery?['rider_phone'] as String?,
            estimatedDeliveryAt: order.estimatedDeliveryAt,
            riderLatitude: latitude is num ? latitude.toDouble() : null,
            riderLongitude: longitude is num ? longitude.toDouble() : null,
            locationRecordedAt: recordedAt is String
                ? DateTime.tryParse(recordedAt)
                : null,
          );
        })
        .toList(growable: false);
  }
}

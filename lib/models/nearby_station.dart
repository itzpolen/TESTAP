class NearbyStation {
  const NearbyStation({
    required this.id,
    required this.name,
    required this.distanceKm,
    required this.startingPrice,
    required this.isOpen,
    this.description,
    this.logoPath,
    this.barangay,
    this.city,
    this.province,
    this.estimatedDeliveryMinutes,
    this.ratingAverage,
    this.ratingCount = 0,
  });

  final String id;
  final String name;
  final double distanceKm;
  final double startingPrice;
  final bool isOpen;
  final String? description;
  final String? logoPath;
  final String? barangay;
  final String? city;
  final String? province;
  final int? estimatedDeliveryMinutes;
  final double? ratingAverage;
  final int ratingCount;

  factory NearbyStation.fromJson(Map<String, dynamic> json) {
    final id = json['station_id'];
    final name = json['display_name'];
    final distanceKm = json['distance_km'];
    final startingPrice = json['starting_price'];
    final isOpen = json['is_open'];

    if (id is! String ||
        name is! String ||
        distanceKm is! num ||
        startingPrice is! num ||
        isOpen is! bool) {
      throw const FormatException(
        'The nearby station response is missing required fields.',
      );
    }

    return NearbyStation(
      id: id,
      name: name,
      description: json['description'] as String?,
      logoPath: json['logo_path'] as String?,
      barangay: json['barangay'] as String?,
      city: json['city'] as String?,
      province: json['province'] as String?,
      distanceKm: distanceKm.toDouble(),
      startingPrice: startingPrice.toDouble(),
      estimatedDeliveryMinutes: json['estimated_delivery_minutes'] as int?,
      isOpen: isOpen,
      ratingAverage: (json['rating_average'] as num?)?.toDouble(),
      ratingCount: json['rating_count'] as int? ?? 0,
    );
  }
}

class StationMarketplaceProductImage {
  const StationMarketplaceProductImage({
    required this.storagePath,
    this.altText,
  });

  final String storagePath;
  final String? altText;
}

class StationMarketplaceProduct {
  const StationMarketplaceProduct({
    required this.id,
    required this.name,
    required this.waterType,
    required this.containerType,
    required this.startingPrice,
    required this.images,
    this.containerVolumeLiters,
    this.refillAvailable = false,
    this.refillPrice = 0,
    this.newContainerAvailable = false,
    this.newContainerPrice,
    this.depositAmount = 0,
    this.stockQuantity,
    this.maxOrderQuantity = 10,
    this.requiresEmptyContainer = false,
    this.returnPolicy,
    this.description,
  });

  final String id;
  final String name;
  final String waterType;
  final String containerType;
  final double? containerVolumeLiters;
  final double startingPrice;
  final bool refillAvailable;
  final double refillPrice;
  final bool newContainerAvailable;
  final double? newContainerPrice;
  final double depositAmount;
  final int? stockQuantity;
  final int maxOrderQuantity;
  final bool requiresEmptyContainer;
  final String? returnPolicy;
  final String? description;
  final List<StationMarketplaceProductImage> images;
}

import 'dart:async';

import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

class DeliveryLocation {
  const DeliveryLocation({
    this.latitude,
    this.longitude,
    this.address,
    this.addressLine,
    this.barangay,
    this.city,
    this.province,
  });

  final double? latitude;
  final double? longitude;
  final String? address;
  final String? addressLine;
  final String? barangay;
  final String? city;
  final String? province;
}

/// What the UI can offer when location fails.
enum LocationFailureAction { none, appSettings, locationSettings }

class LocationServiceException implements Exception {
  const LocationServiceException(
    this.message, {
    this.action = LocationFailureAction.none,
  });

  final String message;
  final LocationFailureAction action;

  @override
  String toString() => message;
}

class LocationService {
  const LocationService();

  static const _gpsTimeout = Duration(seconds: 12);
  static const _geocodeTimeout = Duration(seconds: 8);

  /// Checks that location services are on and permission is granted,
  /// asking the user when needed.
  Future<void> ensurePermission() async {
    

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      throw const LocationServiceException(
        'Location permission was denied. Allow location access or enter your address manually.',
      );
    }
    if (permission == LocationPermission.deniedForever) {
      throw const LocationServiceException(
        'Location permission is blocked. Enable it in your device settings or enter your address manually.',
        action: LocationFailureAction.appSettings,
      );
    }

    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const LocationServiceException(
        'Turn on your device location services, then try again.',
        action: LocationFailureAction.locationSettings,
      );
    }


  }

  /// Fast, slightly coarser fix (usually a few seconds). Good enough to show
  /// the pin and search for stations while a precise fix improves it later.
  Future<DeliveryLocation> quickFix() async {
    await ensurePermission();
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 8),
        ),
      );
      return _fromPosition(position);
    } on TimeoutException {
      final cached = await _lastKnown();
      if (cached != null) return cached;
      throw const LocationServiceException(
        'We couldn’t get a GPS fix in time. Move near a window or open space and try again, or enter your address manually.',
      );
    }
  }

  /// Accurate fix used to refine the pin in the background. Returns null when
  /// it can't be obtained; callers keep the quick fix in that case.
  Future<DeliveryLocation?> preciseFix() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 20),
        ),
      );
      return _fromPosition(position);
    } catch (_) {
      return null;
    }
  }

  /// Single high-accuracy fix (kept for existing callers).
  Future<DeliveryLocation> getCurrentLocation() async {
    await ensurePermission();
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: _gpsTimeout,
        ),
      );
      return _fromPosition(position);
    } on TimeoutException {
      final cached = await _lastKnown();
      if (cached != null) return cached;
      throw const LocationServiceException(
        'We couldn’t get a GPS fix in time. Move near a window or open space and try again, or enter your address manually.',
      );
    }
  }

  DeliveryLocation _fromPosition(Position position) => DeliveryLocation(
    latitude: position.latitude,
    longitude: position.longitude,
  );

  /// Straight-line distance in meters.
  static double distanceMeters(
    double fromLatitude,
    double fromLongitude,
    double toLatitude,
    double toLongitude,
  ) => Geolocator.distanceBetween(
    fromLatitude,
    fromLongitude,
    toLatitude,
    toLongitude,
  );

  Future<DeliveryLocation?> _lastKnown() async {
    try {
      final position = await Geolocator.getLastKnownPosition();
      if (position == null) return null;
      return DeliveryLocation(
        latitude: position.latitude,
        longitude: position.longitude,
      );
    } catch (_) {
      return null; // not supported on every platform
    }
  }

  Future<String?> getAddressFromCoordinates(
    double latitude,
    double longitude,
  ) async {
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      throw const LocationServiceException(
        'The selected map coordinates are invalid.',
      );
    }

    final List<Placemark> placemarks;
    try {
      placemarks = await Geocoding()
          .placemarkFromCoordinates(latitude, longitude)
          .timeout(_geocodeTimeout);
    } on TimeoutException {
      // The platform geocoder can hang (offline, emulator, no Google services).
      throw const LocationServiceException(
        'Address lookup is taking too long. Enter your address manually.',
      );
    } on Exception {
      return null; // "no result" and platform errors -> manual entry
    }
    if (placemarks.isEmpty) return null;

    final place = placemarks.first;
    final municipality = place.locality?.trim().isNotEmpty == true
        ? place.locality
        : place.subAdministrativeArea;
    final parts =
        <String?>[place.subLocality, municipality, place.administrativeArea]
            .whereType<String>()
            .map((part) => part.trim())
            .where((part) => part.isNotEmpty)
            .fold<List<String>>([], (unique, part) {
              if (!unique.any(
                (existing) => existing.toLowerCase() == part.toLowerCase(),
              )) {
                unique.add(part);
              }
              return unique;
            });
    return parts.isEmpty ? null : parts.join(', ');
  }

  /// Opens the right system settings screen for a failed location request.
  Future<void> openSettings(LocationFailureAction action) async {
    switch (action) {
      case LocationFailureAction.appSettings:
        await Geolocator.openAppSettings();
      case LocationFailureAction.locationSettings:
        await Geolocator.openLocationSettings();
      case LocationFailureAction.none:
        break;
    }
  }
}
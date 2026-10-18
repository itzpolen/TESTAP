import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

class DeliveryLocation {
  const DeliveryLocation({
    this.latitude,
    this.longitude,
    this.accuracy,
    this.address,
    this.addressLine,
    this.barangay,
    this.city,
    this.province,
  });

  final double? latitude;
  final double? longitude;

  /// Horizontal accuracy of the GPS reading, in meters (smaller is better).
  /// Save this next to the coordinates so you know how far to trust the pin.
  final double? accuracy;
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
  /// asking the user when needed. This is what shows the OS permission prompt.
  Future<void> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const LocationServiceException(
        'Turn on your device location services, then try again.',
        action: LocationFailureAction.locationSettings,
      );
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      throw const LocationServiceException(
        'Location permission was denied. Allow location access to find stations that deliver to you.',
      );
    }
    if (permission == LocationPermission.deniedForever) {
      throw const LocationServiceException(
        'Location permission is blocked. Enable it in your device settings to find stations that deliver to you.',
        action: LocationFailureAction.appSettings,
      );
    }
  }

  // ---------------------------------------------------------------- live GPS

  /// Live GPS readings at the best accuracy the phone can give.
  ///
  /// The first readings are usually rough and get better every second or two,
  /// so listen until a reading is good enough, then cancel the subscription so
  /// the GPS is not left running. Errors (permission, location off) arrive as
  /// stream errors.
  Stream<DeliveryLocation> positionUpdates() async* {
    await ensurePermission();
    yield* Geolocator.getPositionStream(
      locationSettings: _streamSettings(),
    ).map(_fromPosition);
  }

  /// One-shot version of [positionUpdates]: waits until a reading is within
  /// [targetAccuracy] meters, or [maxWait] passes, and returns the best
  /// reading seen. Handy for checkout or "use my location now" buttons.
  Future<DeliveryLocation> bestFix({
    double targetAccuracy = 25,
    Duration maxWait = const Duration(seconds: 25),
  }) async {
    DeliveryLocation? best;
    final good = Completer<void>();
    final subscription = positionUpdates().listen(
      (fix) {
        final current = best;
        if (current == null || _accuracyOf(fix) < _accuracyOf(current)) {
          best = fix;
        }
        if (_accuracyOf(fix) <= targetAccuracy && !good.isCompleted) {
          good.complete();
        }
      },
      onError: (Object error, StackTrace stack) {
        if (good.isCompleted) return;
        if (best != null) {
          good.complete(); // keep what we already have
        } else {
          good.completeError(error, stack);
        }
      },
    );

    try {
      await good.future.timeout(maxWait);
    } on TimeoutException {
      // Use the best reading seen so far.
    } finally {
      await subscription.cancel();
    }

    final result = best ?? await _lastKnown();
    if (result == null) {
      throw const LocationServiceException(
        'We couldn’t get your GPS location. Go outdoors or near a window and try again.',
      );
    }
    return result;
  }

  static double _accuracyOf(DeliveryLocation location) =>
      location.accuracy ?? double.infinity;

  LocationSettings _streamSettings() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 1),
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 0,
    );
  }

  // ------------------------------------------------ older one-shot helpers
  // Kept so existing callers keep compiling. New code should prefer
  // [positionUpdates] or [bestFix].

  /// Fast, slightly coarser fix (usually a few seconds).
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
        'We couldn’t get a GPS fix in time. Move near a window or open space and try again.',
      );
    }
  }

  /// Accurate fix. Returns null when it can't be obtained.
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

  /// Single high-accuracy fix.
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
        'We couldn’t get a GPS fix in time. Move near a window or open space and try again.',
      );
    }
  }

  DeliveryLocation _fromPosition(Position position) => DeliveryLocation(
    latitude: position.latitude,
    longitude: position.longitude,
    accuracy: position.accuracy,
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
      return _fromPosition(position);
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
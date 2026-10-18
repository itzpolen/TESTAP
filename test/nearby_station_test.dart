import 'package:flutter_test/flutter_test.dart';
import 'package:test4/models/nearby_station.dart';

void main() {
  group('NearbyStation.fromJson', () {
    test('parses a row returned by nearby_stations', () {
      final station = NearbyStation.fromJson({
        'station_id': 'station-123',
        'display_name': 'Clear Spring Water',
        'description': 'Purified water refills',
        'logo_path': 'station-123/station-photo.png',
        'barangay': 'Bagong Pag-asa',
        'city': 'Quezon City',
        'province': 'Metro Manila',
        'distance_km': 1.25,
        'starting_price': 35.0,
        'estimated_delivery_minutes': 30,
        'is_open': true,
        'rating_average': 4.8,
        'rating_count': 12,
      });

      expect(station.id, 'station-123');
      expect(station.name, 'Clear Spring Water');
      expect(station.description, 'Purified water refills');
      expect(station.logoPath, 'station-123/station-photo.png');
      expect(station.barangay, 'Bagong Pag-asa');
      expect(station.distanceKm, 1.25);
      expect(station.startingPrice, 35.0);
      expect(station.isOpen, isTrue);
      expect(station.ratingAverage, 4.8);
      expect(station.ratingCount, 12);
    });

    test('rejects a row missing required fields', () {
      expect(
        () => NearbyStation.fromJson({'station_id': 'station-123'}),
        throwsFormatException,
      );
    });
  });
}

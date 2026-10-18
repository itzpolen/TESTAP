import 'package:flutter_test/flutter_test.dart';
import 'package:test4/services/ph_address_service.dart';

void main() {
  group('PhilippineDivision', () {
    test('parses a PSGC division and optional region code', () {
      final division = PhilippineDivision.fromJson({
        'code': '012800000',
        'name': 'Ilocos Norte',
        'regionCode': '010000000',
      });

      expect(division.code, '012800000');
      expect(division.name, 'Ilocos Norte');
      expect(division.regionCode, '010000000');
    });

    test('rejects malformed PSGC data', () {
      expect(
        () => PhilippineDivision.fromJson({'code': 123, 'name': 'Test'}),
        throwsFormatException,
      );
    });
  });
}

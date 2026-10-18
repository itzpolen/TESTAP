import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'location_service.dart';

class PhilippineDivision {
  const PhilippineDivision({
    required this.code,
    required this.name,
    this.regionCode,
  });

  final String code;
  final String name;
  final String? regionCode;

  factory PhilippineDivision.fromJson(Map<String, dynamic> json) {
    final code = json['code'];
    final name = json['name'];
    final regionCode = json['regionCode'];
    if (code is! String ||
        name is! String ||
        (regionCode != null && regionCode is! String)) {
      throw const FormatException(
        'Administrative address data was returned in an unexpected format.',
      );
    }
    return PhilippineDivision(
      code: code,
      name: name,
      regionCode: regionCode as String?,
    );
  }
}

class PhilippineAddressService {
  const PhilippineAddressService();

  static const _psgcBaseUrl = 'https://psgc.gitlab.io/api';
  static const _requestTimeout = Duration(seconds: 12);
  static const _metroManilaCode = '130000000';
  static Future<void> _nominatimQueue = Future<void>.value();
  static DateTime? _lastNominatimRequest;

  Future<List<PhilippineDivision>> getProvinces() async {
    final provinces = await _getDivisions('/provinces/');
    provinces.add(
      const PhilippineDivision(
        code: _metroManilaCode,
        name: 'Metro Manila',
        regionCode: _metroManilaCode,
      ),
    );
    provinces.sort((a, b) => a.name.compareTo(b.name));
    return provinces;
  }

  Future<List<PhilippineDivision>> getCities(String provinceCode) {
    final path = provinceCode == _metroManilaCode
        ? '/regions/$_metroManilaCode/cities-municipalities/'
        : '/provinces/${Uri.encodeComponent(provinceCode)}/cities-municipalities/';
    return _getDivisions(path);
  }

  Future<List<PhilippineDivision>> getBarangays(String cityCode) =>
      _getDivisions(
        '/cities-municipalities/${Uri.encodeComponent(cityCode)}/barangays/',
      );

  Future<DeliveryLocation?> findAdministrativeArea({
    required String barangay,
    required String city,
    required String province,
  }) async {
    final query = Uri.https('nominatim.openstreetmap.org', '/search', {
      'format': 'jsonv2',
      'q': '$barangay, $city, $province, Philippines',
      'countrycodes': 'ph',
      'limit': '1',
    });
    final response = await _getNominatimResponse(query);
    if (response.statusCode != 200) {
      throw AddressApiException(
        'Map search failed (HTTP ${response.statusCode}).',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! List) {
      throw const FormatException('Map search returned invalid data.');
    }
    if (decoded.isEmpty) return null;
    final result = decoded.first;
    if (result is! Map ||
        result['lat'] is! String ||
        result['lon'] is! String) {
      throw const FormatException('Map search returned invalid coordinates.');
    }
    final latitude = double.tryParse(result['lat'] as String);
    final longitude = double.tryParse(result['lon'] as String);
    if (latitude == null ||
        longitude == null ||
        !latitude.isFinite ||
        !longitude.isFinite ||
        latitude < 4 ||
        latitude > 22 ||
        longitude < 116 ||
        longitude > 128) {
      throw const FormatException(
        'Map search did not return a valid location in the Philippines.',
      );
    }
    return DeliveryLocation(latitude: latitude, longitude: longitude);
  }

  Future<List<PhilippineDivision>> _getDivisions(String path) async {
    final uri = Uri.parse('$_psgcBaseUrl$path');
    final response = await http
        .get(uri, headers: const {'Accept': 'application/json'})
        .timeout(_requestTimeout);
    if (response.statusCode != 200) {
      throw AddressApiException(
        'Administrative address data could not be loaded '
        '(HTTP ${response.statusCode}).',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! List) {
      throw const FormatException(
        'Administrative address data was returned in an unexpected format.',
      );
    }
    return decoded
        .map((item) {
          if (item is! Map) {
            throw const FormatException(
              'Administrative address data was returned in an unexpected format.',
            );
          }
          return PhilippineDivision.fromJson(Map<String, dynamic>.from(item));
        })
        .toList(growable: true)
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  Future<http.Response> _getNominatimResponse(Uri uri) async {
    final turn = Completer<void>();
    final previous = _nominatimQueue;
    _nominatimQueue = turn.future;
    await previous;
    try {
      final lastRequest = _lastNominatimRequest;
      if (lastRequest != null) {
        final wait =
            const Duration(milliseconds: 1100) -
            DateTime.now().difference(lastRequest);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      _lastNominatimRequest = DateTime.now();
      final headers = <String, String>{'Accept': 'application/json'};
      if (!kIsWeb) headers['User-Agent'] = 'AquaDirect customer address picker';
      return await http
          .get(uri, headers: headers)
          .timeout(_requestTimeout);
    } finally {
      turn.complete();
    }
  }
}

class AddressApiException implements Exception {
  const AddressApiException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Seller-configured delivery settings for one station
/// (stations + station_operating_hours).
///
/// Save as lib/models/station_delivery_info.dart
class StationOperatingHour {
  const StationOperatingHour({
    required this.weekday,
    required this.isClosed,
    this.opensAtMinutes,
    this.closesAtMinutes,
  });

  /// 0 = Sunday ... 6 = Saturday (same as the seller portal).
  final int weekday;
  final bool isClosed;
  final int? opensAtMinutes;
  final int? closesAtMinutes;

  bool get isOpenDay =>
      !isClosed &&
      opensAtMinutes != null &&
      closesAtMinutes != null &&
      opensAtMinutes != closesAtMinutes;

  factory StationOperatingHour.fromJson(Map<String, dynamic> json) {
    final weekday = json['weekday'];
    if (weekday is! num) {
      throw const FormatException('Operating hours are missing a weekday.');
    }
    return StationOperatingHour(
      weekday: weekday.toInt(),
      isClosed: json['is_closed'] as bool? ?? true,
      opensAtMinutes: _minutes(json['opens_at']),
      closesAtMinutes: _minutes(json['closes_at']),
    );
  }

  /// Parses Postgres `time` values such as "09:00:00".
  static int? _minutes(Object? value) {
    if (value is! String) return null;
    final parts = value.split(':');
    if (parts.length < 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    return hour * 60 + minute;
  }
}

class StationDeliveryInfo {
  const StationDeliveryInfo({
    this.serviceRadiusKm,
    this.deliveryFee,
    this.minimumOrderAmount,
    this.hours = const [],
  });

  final double? serviceRadiusKm;
  final double? deliveryFee;
  final double? minimumOrderAmount;
  final List<StationOperatingHour> hours;

  static const _dayNames = [
    'Sun',
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
  ];

  static String _formatTime(int minutes) {
    final hour24 = (minutes ~/ 60) % 24;
    final minute = minutes % 60;
    final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
    final suffix = hour24 < 12 ? 'AM' : 'PM';
    return '$hour12:${minute.toString().padLeft(2, '0')} $suffix';
  }

  /// "Open until 8:00 PM", "Opens today 9:00 AM", "Opens Mon 9:00 AM".
  ///
  /// Returns null when the hours are unknown, or when they disagree with the
  /// server's [isOpen] flag (for example a manual override), so the screen
  /// never shows contradictory text.
  String? hoursLabel(DateTime now, {required bool isOpen}) {
    final label = _computeLabel(now);
    if (label == null) return null;
    return label.startsWith('Open until') == isOpen ? label : null;
  }

  String? _computeLabel(DateTime now) {
    final byDay = {
      for (final hour in hours)
        if (hour.isOpenDay) hour.weekday: hour,
    };
    if (byDay.isEmpty) return null;

    final today = now.weekday % 7; // Dart: Mon=1..Sun=7 -> Sun=0
    final minute = now.hour * 60 + now.minute;

    // Overnight window that started yesterday and is still running.
    final yesterday = byDay[(today + 6) % 7];
    if (yesterday != null &&
        yesterday.closesAtMinutes! < yesterday.opensAtMinutes! &&
        minute < yesterday.closesAtMinutes!) {
      return 'Open until ${_formatTime(yesterday.closesAtMinutes!)}';
    }

    final current = byDay[today];
    if (current != null) {
      final opens = current.opensAtMinutes!;
      final closes = current.closesAtMinutes!;
      final overnight = closes < opens;
      final isOpenNow = overnight
          ? minute >= opens
          : minute >= opens && minute < closes;
      if (isOpenNow) return 'Open until ${_formatTime(closes)}';
      if (minute < opens) return 'Opens today ${_formatTime(opens)}';
    }

    for (var offset = 1; offset <= 7; offset++) {
      final day = (today + offset) % 7;
      final next = byDay[day];
      if (next == null) continue;
      final time = _formatTime(next.opensAtMinutes!);
      return offset == 1
          ? 'Opens tomorrow $time'
          : 'Opens ${_dayNames[day]} $time';
    }
    return null;
  }
}
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// How "nearby" works in AquaDirect.
///
/// A station is shown to a customer only when BOTH are true:
///  1. the customer is inside the station's own delivery radius
///     (stations.service_radius_km) or an active delivery zone, and
///  2. the station is within the app's search radius below.
///
/// Radius is measured in kilometers, not meters. Sellers set their own delivery
/// radius (typically 3-10 km); the values below only limit the search.
class NearbyConfig {
  const NearbyConfig._();

  /// First search. Matches a typical city delivery area.
  static const double defaultRadiusKm = 10;

  /// "Expand search" ceiling. nearby_stations() defaults to 25 km and caps at 250.
  static const double expandedRadiusKm = 25;
}

/// 650 m, 1.2 km, 12 km.
String formatDistance(double km) {
  if (km < 1) return '${(km * 1000).round()} m';
  if (km < 10) return '${km.toStringAsFixed(1)} km';
  return '${km.round()} km';
}

const _navy = Color(0xFF12366B);
const _blue = Color(0xFF087CF0);
const _muted = Color(0xFF6B7F9A);

TextStyle _t(
  double size, {
  FontWeight w = FontWeight.w500,
  Color c = _navy,
  double? h,
}) => GoogleFonts.manrope(fontSize: size, fontWeight: w, color: c, height: h);

/// Shown on Home when the search succeeded but no station delivers here yet.
class NoStationsNearby extends StatelessWidget {
  const NoStationsNearby({
    super.key,
    required this.radiusKm,
    required this.onChangeLocation,
    this.onExpandSearch,
  });

  final double radiusKm;
  final VoidCallback onChangeLocation;

  /// Null once the search is already at its maximum radius.
  final VoidCallback? onExpandSearch;

  @override
  Widget build(BuildContext context) => _StateCard(
    icon: Icons.storefront_outlined,
    title: 'No stations deliver here yet',
    message:
        'We searched within ${radiusKm.round()} km and found no station that delivers to this address. We’re growing, so check back soon.',
    primaryLabel: onExpandSearch == null
        ? 'Change location'
        : 'Search wider (${NearbyConfig.expandedRadiusKm.round()} km)',
    onPrimary: onExpandSearch ?? onChangeLocation,
    secondaryLabel: onExpandSearch == null ? null : 'Change location',
    onSecondary: onExpandSearch == null ? null : onChangeLocation,
  );
}

/// Shown on Home when the customer skipped location selection.
class NoLocationCard extends StatelessWidget {
  const NoLocationCard({super.key, required this.onSetLocation});

  final VoidCallback onSetLocation;

  @override
  Widget build(BuildContext context) => _StateCard(
    icon: Icons.location_off_outlined,
    title: 'Set your location',
    message:
        'Use your current position or choose a map pin to find nearby stations. You can add your delivery address at checkout.',
    primaryLabel: 'Choose my location',
    onPrimary: onSetLocation,
  );
}

class _StateCard extends StatelessWidget {
  const _StateCard({
    required this.icon,
    required this.title,
    required this.message,
    required this.primaryLabel,
    required this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final String title;
  final String message;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(22, 26, 22, 20),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0xFFE1EDF8)),
    ),
    child: Column(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFFEAF4FF),
          ),
          child: Icon(icon, color: _blue, size: 28),
        ),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: _t(18, w: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: _t(13.5, c: _muted, h: 1.55),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton(
            onPressed: onPrimary,
            style: ElevatedButton.styleFrom(
              backgroundColor: _blue,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: Text(
              primaryLabel,
              style: _t(14.5, w: FontWeight.w800, c: Colors.white),
            ),
          ),
        ),
        if (secondaryLabel != null && onSecondary != null)
          TextButton(
            onPressed: onSecondary,
            child: Text(
              secondaryLabel!,
              style: _t(13.5, w: FontWeight.w700, c: _muted),
            ),
          ),
      ],
    ),
  );
}

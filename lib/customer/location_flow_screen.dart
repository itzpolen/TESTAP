import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';

import 'auth_screen.dart';
import '../services/location_service.dart';
import '../services/ph_address_service.dart';

/// AquaDirect location flow: finding -> found (or failed).
///
/// The customer never picks a spot on the map. The OS permission prompt is
/// shown once, automatically, when the screen opens. The device GPS is then
/// tracked live: the pin appears on the first reading and sharpens every
/// second or two until it is accurate enough (or the wait runs out).
///
/// Put this file at lib/customer/location_flow_screen.dart.
class LocationFlowScreen extends StatefulWidget {
  const LocationFlowScreen({
    super.key,
    this.onComplete,
    this.onLocationSelected,
    this.onSkip,
    this.findLocation,
    this.checkCoverage,
    this.browsingOnly = false,
  });

  final ValueChanged<String>? onComplete;
  final ValueChanged<DeliveryLocation>? onLocationSelected;
  final VoidCallback? onSkip;

  /// Ignored. Kept only so existing callers still compile.
  final Future<String?> Function()? findLocation;
  final bool browsingOnly;

  /// Optional: how many stations deliver to this point (e.g. your
  /// nearby_stations RPC). When null, the coverage card is not shown.
  final Future<int> Function(double latitude, double longitude)? checkCoverage;

  @override
  State<LocationFlowScreen> createState() => _LocationFlowScreenState();
}

enum _Stage { finding, found, failed }

/// Real progress of the finding step (not a timer).
enum _FindPhase { permission, position }

enum _CoverageState { idle, checking, ready, unavailable }

class _Coverage {
  const _Coverage(this.state, [this.count = 0]);
  const _Coverage.idle() : this(_CoverageState.idle);
  final _CoverageState state;
  final int count;
}

// ------------------------------------------------------------------ tokens

const _navy = Color(0xFF12366B);
const _blue = Color(0xFF087CF0);
const _muted = Color(0xFF6B7F9A);
const _line = Color(0xFFE4EDF6);
const _surface = Color(0xFFF7FAFD);
const _green = Color(0xFF12B981);

// ------------------------------------------------------ accuracy tuning (m)

/// Stop refining as soon as a reading is this accurate.
const _targetAccuracy = 25.0;

/// Above this we warn the customer that the pin is only approximate.
const _approximateAccuracy = 100.0;

/// Above this, Continue is blocked until the pin gets more precise.
const _maxUsableAccuracy = 150.0;

/// Longest we keep sharpening the pin before settling on the best reading.
const _maxRefineWait = Duration(seconds: 25);

const _genericFailure =
    'We couldn’t get your location. Check that location is on, then try again.';

TextStyle _t(
  double size, {
  FontWeight w = FontWeight.w500,
  Color c = _navy,
  double? h,
  double? ls,
}) => GoogleFonts.manrope(
  fontSize: size,
  fontWeight: w,
  color: c,
  height: h,
  letterSpacing: ls,
);

InputDecoration _fieldDecoration(
  String label, {
  String? hint,
  Widget? prefixIcon,
}) {
  OutlineInputBorder border(Color color) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: BorderSide(color: color),
  );
  return InputDecoration(
    labelText: label,
    hintText: hint,
    labelStyle: _t(13.5, c: _muted),
    hintStyle: _t(13.5, c: const Color(0xFFA7B6C8)),
    prefixIcon: prefixIcon,
    filled: true,
    fillColor: _surface,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    border: border(_line),
    enabledBorder: border(_line),
    disabledBorder: border(_line),
    focusedBorder: border(_blue),
  );
}

bool _inPhilippines(double lat, double lng) =>
    lat >= 4 && lat <= 22 && lng >= 116 && lng <= 128;

// ------------------------------------------------------------------- state

class _LocationFlowScreenState extends State<LocationFlowScreen>
    with WidgetsBindingObserver {
  _Stage stage = _Stage.finding;
  _FindPhase findPhase = _FindPhase.permission;
  String? error;
  LocationFailureAction failureAction = LocationFailureAction.none;

  double? latitude;
  double? longitude;

  /// Accuracy of the current reading in meters (from the device GPS).
  double? accuracy;

  /// True while the GPS is still sharpening the pin.
  bool refining = false;

  bool loadingProvinces = true;
  bool loadingCities = false;
  bool loadingBarangays = false;
  List<PhilippineDivision> provinces = const [];
  List<PhilippineDivision> cities = const [];
  List<PhilippineDivision> barangays = const [];
  String? provinceCode;
  String? cityCode;
  String? barangayCode;
  String? addressFormError;
  String? divisionLoadError;

  int areaLookupRequest = 0;
  int findRequest = 0;
  int coverageRequest = 0;
  double? coverageLat;
  double? coverageLng;
  String? toastMessage;
  bool toastVisible = false;
  Timer? toastTimer;
  bool slowFinding = false;
  Timer? slowTimer;
  Timer? settleTimer;
  StreamSubscription<DeliveryLocation>? locationSub;
  _Coverage coverage = const _Coverage.idle();

  final addressLineController = TextEditingController();
  final addressLineFocus = FocusNode();
  final LocationService locationService = const LocationService();
  final PhilippineAddressService addressService =
      const PhilippineAddressService();

  bool get located => latitude != null && longitude != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!widget.browsingOnly) unawaited(_loadProvinces());
      unawaited(startFinding());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    slowTimer?.cancel();
    toastTimer?.cancel();
    settleTimer?.cancel();
    unawaited(locationSub?.cancel());
    addressLineController.dispose();
    addressLineFocus.dispose();
    super.dispose();
  }

  /// If the customer fixed a denied permission or turned location services on
  /// in system settings, find them again as soon as they come back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        stage == _Stage.failed &&
        failureAction != LocationFailureAction.none) {
      unawaited(startFinding());
    }
  }

  String? get selectedProvince => _divisionName(provinces, provinceCode);
  String? get selectedCity => _divisionName(cities, cityCode);
  String? get selectedBarangay => _divisionName(barangays, barangayCode);

  String? get structuredAddress {
    final parts = <String>[
      addressLineController.text.trim(),
      ?selectedBarangay,
      ?selectedCity,
      ?selectedProvince,
    ]..removeWhere((part) => part.isEmpty);
    return parts.isEmpty ? null : parts.join(', ');
  }

  static String? _divisionName(
    List<PhilippineDivision> divisions,
    String? code,
  ) {
    if (code == null) return null;
    for (final division in divisions) {
      if (division.code == code) return division.name;
    }
    return null;
  }

  // ------------------------------------------------------------------ toast

  /// Soft toast below the status bar. Fades out after 2.5 seconds.
  void _toast(String message) {
    if (!mounted) return;
    toastTimer?.cancel();
    setState(() {
      toastMessage = message;
      toastVisible = true;
    });
    toastTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => toastVisible = false);
    });
  }

  // --------------------------------------------------------------- divisions

  Future<void> _loadProvinces() async {
    setState(() {
      loadingProvinces = true;
      divisionLoadError = null;
    });
    try {
      final result = await addressService.getProvinces();
      if (!mounted) return;
      setState(() {
        provinces = result;
        loadingProvinces = false;
      });
    } on Exception catch (exception) {
      if (!mounted) return;
      setState(() {
        loadingProvinces = false;
        divisionLoadError = exception.toString();
      });
    }
  }

  Future<void> _selectProvince(String? code) async {
    if (code == null) return;
    final request = ++areaLookupRequest;
    setState(() {
      provinceCode = code;
      cityCode = null;
      barangayCode = null;
      cities = const [];
      barangays = const [];
      loadingCities = true;
      loadingBarangays = false;
      divisionLoadError = null;
      addressFormError = null;
    });
    try {
      final result = await addressService.getCities(code);
      if (!mounted || request != areaLookupRequest || provinceCode != code) {
        return;
      }
      setState(() {
        cities = result;
        loadingCities = false;
      });
    } on Exception catch (exception) {
      if (!mounted || request != areaLookupRequest) return;
      setState(() {
        loadingCities = false;
        divisionLoadError = exception.toString();
      });
    }
  }

  Future<void> _selectCity(String? code) async {
    if (code == null) return;
    final request = ++areaLookupRequest;
    setState(() {
      cityCode = code;
      barangayCode = null;
      barangays = const [];
      loadingBarangays = true;
      divisionLoadError = null;
      addressFormError = null;
    });
    try {
      final result = await addressService.getBarangays(code);
      if (!mounted || request != areaLookupRequest || cityCode != code) return;
      setState(() {
        barangays = result;
        loadingBarangays = false;
      });
    } on Exception catch (exception) {
      if (!mounted || request != areaLookupRequest) return;
      setState(() {
        loadingBarangays = false;
        divisionLoadError = exception.toString();
      });
    }
  }

  /// The dropdowns only describe the address in words. They never move the
  /// pin, which always comes from the device GPS.
  void _selectBarangay(String? code) {
    if (code == null) return;
    setState(() {
      barangayCode = code;
      addressFormError = null;
    });
  }

  // ---------------------------------------------------------------- finding

  /// Asks for permission (once, via the OS prompt), then follows the device
  /// GPS. The pin appears on the first reading and keeps sharpening until it
  /// is accurate enough or [_maxRefineWait] runs out.
  Future<void> startFinding() async {
    final request = ++findRequest;
    slowTimer?.cancel();
    await _stopTracking();
    if (!mounted || request != findRequest) return;

    setState(() {
      stage = _Stage.finding;
      findPhase = _FindPhase.permission;
      error = null;
      failureAction = LocationFailureAction.none;
      latitude = null;
      longitude = null;
      accuracy = null;
      refining = false;
      slowFinding = false;
      coverage = const _Coverage.idle();
      coverageLat = null;
      coverageLng = null;
    });
    slowTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && request == findRequest && stage == _Stage.finding) {
        setState(() => slowFinding = true);
      }
    });

    try {
      await locationService.ensurePermission();
    } on LocationServiceException catch (exception) {
      _fail(request, exception.message, exception.action);
      return;
    } on Exception {
      _fail(request, _genericFailure, LocationFailureAction.none);
      return;
    }
    if (!mounted || request != findRequest) return;
    setState(() => findPhase = _FindPhase.position);

    locationSub = locationService.positionUpdates().listen(
      (fix) => _onFix(request, fix),
      onError: (Object exception) {
        if (!mounted || request != findRequest || located) return;
        if (exception is LocationServiceException) {
          _fail(request, exception.message, exception.action);
        } else {
          _fail(request, _genericFailure, LocationFailureAction.none);
        }
      },
    );
    settleTimer = Timer(
      _maxRefineWait,
      () => unawaited(_finishTracking(request)),
    );
  }

  /// A new GPS reading. The first one shows the pin; later ones only replace
  /// it when they are more accurate.
  void _onFix(int request, DeliveryLocation fix) {
    if (!mounted || request != findRequest) return;
    final lat = fix.latitude;
    final lng = fix.longitude;
    if (lat == null || lng == null) return;

    final first = !located;
    final newAccuracy = fix.accuracy ?? double.infinity;
    final currentAccuracy = accuracy ?? double.infinity;
    if (!first && newAccuracy >= currentAccuracy) return;

    slowTimer?.cancel();
    setState(() {
      latitude = lat;
      longitude = lng;
      accuracy = fix.accuracy;
      stage = _Stage.found;
      slowFinding = false;
      error = null;
      failureAction = LocationFailureAction.none;
      refining = true;
    });
    if (first) unawaited(runCoverageCheck());
    if (newAccuracy <= _targetAccuracy) unawaited(_finishTracking(request));
  }

  /// Stops the GPS and settles on the best reading seen.
  Future<void> _finishTracking(int request) async {
    if (!mounted || request != findRequest) return;
    await _stopTracking();
    if (!mounted || request != findRequest) return;

    final lat = latitude;
    final lng = longitude;
    if (lat == null || lng == null) {
      _fail(
        request,
        'Finding your location took too long. Go outdoors or near a window, then try again.',
        LocationFailureAction.none,
      );
      return;
    }

    final reading = accuracy ?? 0;
    final approximate = reading > _approximateAccuracy;
    setState(() {
      refining = false;
      if (approximate) {
        error =
            'Your location is only accurate to about ${reading.round()} m. Go outdoors or near a window, and make sure Precise location is on for AquaDirect, then try again.';
      }
    });
    if (!approximate) _toast('Location confirmed');

    final checkedLat = coverageLat;
    final checkedLng = coverageLng;
    final moved = checkedLat == null || checkedLng == null
        ? double.infinity
        : LocationService.distanceMeters(checkedLat, checkedLng, lat, lng);
    if (moved >= 25) unawaited(runCoverageCheck());
  }

  Future<void> _stopTracking() async {
    settleTimer?.cancel();
    settleTimer = null;
    final subscription = locationSub;
    locationSub = null;
    await subscription?.cancel();
  }

  void _fail(int request, String message, LocationFailureAction action) {
    if (!mounted || request != findRequest) return;
    slowTimer?.cancel();
    unawaited(_stopTracking());
    setState(() {
      stage = _Stage.failed;
      error = message;
      failureAction = action;
      slowFinding = false;
      refining = false;
    });
  }

  Future<void> runCoverageCheck() async {
    final check = widget.checkCoverage;
    final lat = latitude;
    final lng = longitude;
    if (check == null || lat == null || lng == null) return;
    final request = ++coverageRequest;
    coverageLat = lat;
    coverageLng = lng;
    setState(() => coverage = const _Coverage(_CoverageState.checking));
    try {
      final count = await check(lat, lng).timeout(const Duration(seconds: 8));
      if (!mounted || request != coverageRequest) return;
      setState(() => coverage = _Coverage(_CoverageState.ready, count));
    } on Exception {
      if (!mounted || request != coverageRequest) return;
      setState(() => coverage = const _Coverage(_CoverageState.unavailable));
    }
  }

  Future<void> openSettings() => locationService.openSettings(failureAction);

  // --------------------------------------------------------------- continue

  void _finish(DeliveryLocation location, String label) {
    findRequest++;
    unawaited(_stopTracking());
    if (widget.onLocationSelected != null) {
      widget.onLocationSelected!(location);
      return;
    }
    if (widget.onComplete != null) {
      widget.onComplete!(label);
      return;
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => LoginScreen(initialBrowsingLocation: location),
      ),
    );
  }

  /// Returns an error message when the current reading can't be used yet.
  String? _locationProblem() {
    final lat = latitude;
    final lng = longitude;
    if (lat == null || lng == null) {
      return 'We still need your device location. Tap Try again.';
    }
    if (!_inPhilippines(lat, lng)) {
      return widget.browsingOnly
          ? 'The location must be within the Philippines.'
          : 'Your location must be within the Philippines.';
    }
    if ((accuracy ?? 0) > _maxUsableAccuracy) {
      return 'Your location isn’t precise enough yet. Go outdoors or near a window, then tap Try again.';
    }
    return null;
  }

  void continueFlow() {
    if (widget.browsingOnly) {
      final problem = _locationProblem();
      if (problem != null) {
        setState(() => addressFormError = problem);
        return;
      }
      _finish(
        DeliveryLocation(
          latitude: latitude,
          longitude: longitude,
          accuracy: accuracy,
        ),
        'Current location',
      );
      return;
    }

    final streetAddress = addressLineController.text.trim();
    if (selectedProvince == null ||
        selectedCity == null ||
        selectedBarangay == null) {
      setState(
        () => addressFormError =
            'Select your province, city or municipality, and barangay.',
      );
      return;
    }
    if (streetAddress.isEmpty) {
      setState(
        () => addressFormError =
            'Enter your house number, street, or sitio/purok.',
      );
      FocusScope.of(context).requestFocus(addressLineFocus);
      return;
    }
    final problem = _locationProblem();
    if (problem != null) {
      setState(() => addressFormError = problem);
      return;
    }
    final location = DeliveryLocation(
      latitude: latitude,
      longitude: longitude,
      accuracy: accuracy,
      address: structuredAddress,
      addressLine: streetAddress,
      barangay: selectedBarangay,
      city: selectedCity,
      province: selectedProvince,
    );
    _finish(location, location.address!);
  }

  /// Continues to authentication without a delivery location. Only offered
  /// after a failure. The home screen should then ask the customer to set one
  /// (see NoLocationCard).
  void skip() {
    findRequest++;
    slowTimer?.cancel();
    unawaited(_stopTracking());
    if (widget.onSkip != null) {
      widget.onSkip!();
      return;
    }
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => LoginScreen()));
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                switchInCurve: Curves.easeOut,
                child: _content(key: ValueKey(stage)),
              ),
            ),
            if (toastMessage != null)
              Positioned(
                left: 24,
                right: 24,
                top: 12,
                child: IgnorePointer(
                  child: AnimatedSlide(
                    offset: toastVisible ? Offset.zero : const Offset(0, -.3),
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                    child: AnimatedOpacity(
                      opacity: toastVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 250),
                      child: _ToastCard(message: toastMessage!),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      bottomNavigationBar: _footer(),
    );
  }

  Widget _content({required Key key}) => switch (stage) {
    _Stage.finding => _finding(key),
    _Stage.found => _found(key),
    _Stage.failed => _failed(key),
  };

  Widget? _footer() {
    switch (stage) {
      case _Stage.finding:
        return null;
      case _Stage.failed:
        final none = failureAction == LocationFailureAction.none;
        return _Footer(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _PrimaryButton(
                label: switch (failureAction) {
                  LocationFailureAction.none => 'Try again',
                  LocationFailureAction.appSettings => 'Open app settings',
                  LocationFailureAction.locationSettings =>
                    'Open location settings',
                },
                onTap: none ? startFinding : openSettings,
              ),
              TextButton(
                onPressed: skip,
                child: Text(
                  'Skip for now',
                  style: _t(13.5, w: FontWeight.w700, c: _muted),
                ),
              ),
            ],
          ),
        );
      case _Stage.found:
        return _Footer(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _PrimaryButton(
                label: widget.browsingOnly ? 'See nearby stations' : 'Continue',
                onTap: continueFlow,
              ),
              const SizedBox(height: 4),
            ],
          ),
        );
    }
  }

  // ---------------------------------------------------------------- finding

  Widget _finding(Key key) => SizedBox.expand(
    key: key,
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 92,
              height: 92,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  const SizedBox(
                    width: 92,
                    height: 92,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _blue,
                      backgroundColor: _line,
                    ),
                  ),
                  Container(
                    width: 64,
                    height: 64,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFFEAF4FF),
                    ),
                    child: const Icon(
                      Icons.near_me_rounded,
                      color: _blue,
                      size: 28,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            Text(
              'Finding your location',
              textAlign: TextAlign.center,
              style: _t(24, w: FontWeight.w800, h: 1.2, ls: -.6),
            ),
            const SizedBox(height: 10),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(
                findPhase == _FindPhase.permission
                    ? 'Allow location access when prompted.'
                    : 'Getting an accurate position…',
                key: ValueKey(findPhase),
                textAlign: TextAlign.center,
                style: _t(14.5, c: _muted, h: 1.5),
              ),
            ),
            if (slowFinding) ...[
              const SizedBox(height: 24),
              const _Notice(
                message:
                    'This is taking longer than usual. Check that location services are on, and try going outdoors or near a window.',
              ),
            ],
          ],
        ),
      ),
    ),
  );

  // ----------------------------------------------------------------- failed

  Widget _failed(Key key) {
    final title = switch (failureAction) {
      LocationFailureAction.none => 'We can’t find you yet',
      LocationFailureAction.appSettings => 'Location access is off',
      LocationFailureAction.locationSettings => 'Turn on location',
    };
    return SizedBox.expand(
      key: key,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFFEAF4FF),
                ),
                child: const Icon(
                  Icons.location_off_rounded,
                  color: _blue,
                  size: 30,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                title,
                textAlign: TextAlign.center,
                style: _t(24, w: FontWeight.w800, h: 1.2, ls: -.6),
              ),
              const SizedBox(height: 10),
              Text(
                error ?? _genericFailure,
                textAlign: TextAlign.center,
                style: _t(14.5, c: _muted, h: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ found

  Widget _found(Key key) {
    final browsing = widget.browsingOnly;
    final title = browsing ? 'Your location' : 'Confirm your address';
    final subtitle = browsing
        ? 'We use your device location to find nearby stations. It won’t be saved as a delivery address.'
        : 'We found where you are. Add your address details so the rider can find you.';

    final map = _MapPreview(
      height: browsing ? null : 200,
      latitude: latitude,
      longitude: longitude,
      accuracy: accuracy,
    );

    final header = <Widget>[
      Text(title, style: _t(25, w: FontWeight.w800, h: 1.2, ls: -.6)),
      const SizedBox(height: 6),
      Text(subtitle, style: _t(14.5, c: _muted, h: 1.5)),
      const SizedBox(height: 16),
      if (error != null) ...[
        _Notice(message: error!, actionLabel: 'Try again', onAction: startFinding),
        const SizedBox(height: 14),
      ],
    ];

    final status = _StatusLine(refining: refining, accuracy: accuracy);

    final feedback = <Widget>[
      if (coverage.state != _CoverageState.idle) ...[
        const SizedBox(height: 14),
        _CoverageCard(coverage: coverage, onRetry: runCoverageCheck),
      ],
      if (addressFormError != null) ...[
        const SizedBox(height: 12),
        _Notice(message: addressFormError!, error: true),
      ],
    ];

    // Browsing: the map fills the free space, so there is no dead gap above
    // the footer.
    if (browsing) {
      return SizedBox.expand(
        key: key,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ...header,
              Expanded(child: map),
              status,
              ...feedback,
            ],
          ),
        ),
      );
    }

    return SizedBox.expand(
      key: key,
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...header,
            map,
            status,
            const SizedBox(height: 16),
            _DivisionSelector(
              label: 'Province',
              value: provinceCode,
              divisions: provinces,
              loading: loadingProvinces,
              onChanged: _selectProvince,
            ),
            const SizedBox(height: 12),
            _DivisionSelector(
              label: 'City / municipality',
              value: cityCode,
              divisions: cities,
              loading: loadingCities,
              enabled: provinceCode != null,
              onChanged: _selectCity,
            ),
            const SizedBox(height: 12),
            _DivisionSelector(
              label: 'Barangay',
              value: barangayCode,
              divisions: barangays,
              loading: loadingBarangays,
              enabled: cityCode != null,
              onChanged: _selectBarangay,
            ),
            if (divisionLoadError != null) ...[
              const SizedBox(height: 10),
              _Notice(
                message: divisionLoadError!,
                error: true,
                actionLabel: 'Retry',
                onAction: () {
                  if (provinceCode == null) {
                    unawaited(_loadProvinces());
                  } else if (cityCode == null) {
                    unawaited(_selectProvince(provinceCode));
                  } else {
                    unawaited(_selectCity(cityCode));
                  }
                },
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: addressLineController,
              focusNode: addressLineFocus,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              style: _t(14.5, w: FontWeight.w600),
              onChanged: (_) => setState(() => addressFormError = null),
              decoration: _fieldDecoration(
                'House number, street, or sitio/purok',
                hint: 'e.g. 12 Rizal St. or Purok 3',
                prefixIcon: const Icon(
                  Icons.home_outlined,
                  color: _muted,
                  size: 20,
                ),
              ),
            ),
            ...feedback,
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- components

class _ToastCard extends StatelessWidget {
  const _ToastCard({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: _line),
      boxShadow: [
        BoxShadow(
          color: _navy.withValues(alpha: .10),
          blurRadius: 24,
          offset: const Offset(0, 8),
        ),
      ],
    ),
    child: Row(
      children: [
        const Icon(Icons.check_circle_rounded, color: _green, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(message, style: _t(13.5, w: FontWeight.w700)),
        ),
      ],
    ),
  );
}

class _Footer extends StatelessWidget {
  const _Footer({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(top: BorderSide(color: _line)),
    ),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
        child: child,
      ),
    ),
  );
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    height: 52,
    child: ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: _blue,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: Text(
        label,
        style: _t(15, w: FontWeight.w800, c: Colors.white),
      ),
    ),
  );
}

/// Quiet status under the map: sharpening, then confirmed.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.refining, required this.accuracy});
  final bool refining;
  final double? accuracy;

  @override
  Widget build(BuildContext context) {
    final meters = accuracy == null ? '' : ' (±${accuracy!.round()} m)';
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: refining
          ? _row(
              const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(strokeWidth: 2, color: _blue),
              ),
              'Improving accuracy…$meters',
              _muted,
            )
          : _row(
              const Icon(Icons.check_circle_rounded, size: 15, color: _green),
              'Using your device location$meters',
              _green,
            ),
    );
  }

  Widget _row(Widget icon, String text, Color color) => Row(
    children: [
      icon,
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          text,
          style: _t(12.5, w: FontWeight.w600, c: color),
        ),
      ),
    ],
  );
}

class _CoverageCard extends StatelessWidget {
  const _CoverageCard({required this.coverage, required this.onRetry});
  final _Coverage coverage;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    late final Widget icon;
    late final String title;
    String? body;
    var background = _surface;
    var border = _line;
    var action = false;

    switch (coverage.state) {
      case _CoverageState.checking:
        icon = const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2.2, color: _blue),
        );
        title = 'Checking for stations near you…';
      case _CoverageState.ready when coverage.count > 0:
        icon = const Icon(Icons.storefront_rounded, color: _green, size: 20);
        title =
            '${coverage.count} station${coverage.count == 1 ? '' : 's'} deliver${coverage.count == 1 ? 's' : ''} to this location';
        background = const Color(0xFFF2FBF7);
        border = const Color(0xFFCDEBDD);
      case _CoverageState.ready:
        icon = const Icon(Icons.storefront_outlined, color: _blue, size: 20);
        title = 'No stations deliver here yet';
        body =
            'We’re growing. You can still create an account, and we’ll show stations as soon as one opens near you.';
      case _CoverageState.unavailable:
      case _CoverageState.idle:
        icon = const Icon(Icons.wifi_off_rounded, color: _muted, size: 20);
        title = 'We couldn’t check station availability';
        body = 'You can continue. We’ll check again on the home screen.';
        action = true;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: icon),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: _t(13.5, w: FontWeight.w700)),
                if (body != null) ...[
                  const SizedBox(height: 4),
                  Text(body, style: _t(12.5, c: _muted, h: 1.5)),
                ],
                if (action) ...[
                  const SizedBox(height: 6),
                  GestureDetector(
                    onTap: onRetry,
                    child: Text(
                      'Try again',
                      style: _t(12.5, w: FontWeight.w800, c: _blue),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Soft inline message. Amber by default, red when [error] is true.
class _Notice extends StatelessWidget {
  const _Notice({
    required this.message,
    this.actionLabel,
    this.onAction,
    this.error = false,
  });
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final background = error
        ? const Color(0xFFFFF5F3)
        : const Color(0xFFFFF8EC);
    final border = error ? const Color(0xFFF2CBC5) : const Color(0xFFFBE6B8);
    final text = error ? const Color(0xFF9B342A) : const Color(0xFF8A5A12);
    final iconColor = error ? const Color(0xFFC0463A) : const Color(0xFFB7791F);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.info_outline_rounded, size: 18, color: iconColor),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  style: _t(12.5, w: FontWeight.w600, c: text, h: 1.45),
                ),
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(height: 6),
                  GestureDetector(
                    onTap: onAction,
                    child: Text(
                      actionLabel!,
                      style: _t(12.5, w: FontWeight.w800, c: _blue),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DivisionSelector extends StatelessWidget {
  const _DivisionSelector({
    required this.label,
    required this.value,
    required this.divisions,
    required this.loading,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final String? value;
  final List<PhilippineDivision> divisions;
  final bool loading;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
    // Re-create when the value is reset from outside (e.g. province changed).
    key: ValueKey('$label|$value|${divisions.length}'),
    initialValue: value,
    isExpanded: true,
    borderRadius: BorderRadius.circular(14),
    style: _t(14.5, w: FontWeight.w600),
    icon: loading
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: _blue),
          )
        : const Icon(Icons.keyboard_arrow_down_rounded, color: _muted),
    decoration: _fieldDecoration(label),
    items: [
      for (final division in divisions)
        DropdownMenuItem(
          value: division.code,
          child: Text(division.name, overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: enabled && !loading ? onChanged : null,
  );
}

// --------------------------------------------------------------- map preview

/// Read-only map that follows the device GPS. The customer can't tap or drag
/// it. A soft circle shows how accurate the reading is.
class _MapPreview extends StatefulWidget {
  const _MapPreview({
    required this.height,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
  });

  final double? height;
  final double? latitude;
  final double? longitude;
  final double? accuracy;

  @override
  State<_MapPreview> createState() => _MapPreviewState();
}

class _MapPreviewState extends State<_MapPreview> {
  static const double _zoom = 17;
  final MapController _controller = MapController();

  @override
  void didUpdateWidget(covariant _MapPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final lat = widget.latitude;
    final lng = widget.longitude;
    if (lat == null || lng == null) return;
    if (lat != oldWidget.latitude || lng != oldWidget.longitude) {
      // Slide the map to the sharper reading once the frame is built.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _controller.move(LatLng(lat, lng), _zoom);
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lat = widget.latitude;
    final lng = widget.longitude;
    final accuracy = widget.accuracy;

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Container(
        height: widget.height,
        width: double.infinity,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _line),
        ),
        child: Stack(
          children: [
            FlutterMap(
              mapController: _controller,
              options: MapOptions(
                initialCenter: lat != null && lng != null
                    ? LatLng(lat, lng)
                    : const LatLng(12.8797, 121.7740),
                initialZoom: lat != null && lng != null ? _zoom : 5,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.none,
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.test4',
                  maxZoom: 19,
                ),
                if (lat != null && lng != null && accuracy != null)
                  CircleLayer(
                    circles: [
                      CircleMarker(
                        point: LatLng(lat, lng),
                        radius: accuracy,
                        useRadiusInMeter: true,
                        color: _blue.withValues(alpha: .12),
                        borderColor: _blue.withValues(alpha: .4),
                        borderStrokeWidth: 1,
                      ),
                    ],
                  ),
                if (lat != null && lng != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: LatLng(lat, lng),
                        width: 64,
                        height: 64,
                        child: const _PinMarker(),
                      ),
                    ],
                  ),
                RichAttributionWidget(
                  alignment: AttributionAlignment.bottomRight,
                  attributions: [
                    TextSourceAttribution('© OpenStreetMap contributors'),
                  ],
                ),
              ],
            ),
            Positioned(
              left: 12,
              top: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .95),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.near_me_rounded, color: _blue, size: 14),
                    const SizedBox(width: 6),
                    Text(
                      'Your current location',
                      style: _t(11.5, w: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Static marker: a dot with a soft halo.
class _PinMarker extends StatelessWidget {
  const _PinMarker();

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    children: [
      Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _blue.withValues(alpha: .14),
        ),
      ),
      Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: _blue,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3.5),
          boxShadow: [
            BoxShadow(color: _blue.withValues(alpha: .35), blurRadius: 8),
          ],
        ),
      ),
    ],
  );
}
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/app_colors.dart';
import '../models/customer_cart.dart';
import '../services/location_service.dart';
import '../services/supabase_service.dart';
import 'auth_screen.dart';
import 'location_flow_screen.dart';

const _heroTop = Color(0xFF2860E8);
const _heroBottom = Color(0xFF1743B5);

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _loading = true;
  bool _saving = false;
  String? _error;
  Map<String, dynamic>? _profile;
  List<CustomerOrder> _orders = const [];
  DeliveryLocation? _deliveryLocation;
  DeliveryLocation? _browsingLocation;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    if (_profile == null) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final results = await Future.wait<Object?>([
        SupabaseService.getCurrentProfile(),
        SupabaseService.getCustomerOrders(),
        SupabaseService.getCustomerDeliveryLocation(),
        SupabaseService.getCustomerBrowsingLocation(),
      ]);
      if (!mounted) return;
      setState(() {
        _profile = results[0] as Map<String, dynamic>?;
        _orders = results[1] as List<CustomerOrder>;
        _deliveryLocation = results[2] as DeliveryLocation?;
        _browsingLocation = results[3] as DeliveryLocation?;
        _loading = false;
        _error = null;
      });
    } on Exception catch (error) {
      if (!mounted) return;
      final hadProfile = _profile != null;
      setState(() {
        _loading = false;
        if (!hadProfile) _error = error.toString();
      });
      if (hadProfile) _showMessage('Couldn’t refresh your profile.');
    }
  }

  Future<void> _editPersonalInformation() async {
    final result = await showModalBottomSheet<({String name, String phone})>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (_) => _EditProfileSheet(
        initialName: _profile?['full_name'] as String? ?? '',
        initialPhone: _profile?['phone'] as String? ?? '',
        email: SupabaseService.client.auth.currentUser?.email,
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _saving = true);
    try {
      await SupabaseService.updateCurrentProfile(
        fullName: result.name,
        phone: result.phone,
      );
      await _loadProfile();
      if (mounted) _showMessage('Profile updated.');
    } on Exception catch (error) {
      if (mounted) _showMessage('Could not update profile: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<DeliveryLocation?> _openLocationFlow({required bool browsingOnly}) {
    return Navigator.of(context).push<DeliveryLocation>(
      MaterialPageRoute(
        builder: (flowContext) => LocationFlowScreen(
          browsingOnly: browsingOnly,
          onLocationSelected: (location) =>
              Navigator.of(flowContext).pop(location),
          onSkip: () => Navigator.of(flowContext).pop(),
        ),
      ),
    );
  }

  Future<void> _editDeliveryAddress() async {
    final location = await _openLocationFlow(browsingOnly: false);
    if (location == null || !mounted) return;
    setState(() => _saving = true);
    try {
      await SupabaseService.saveCustomerDeliveryLocation(location);
      await _loadProfile();
      if (mounted) _showMessage('Delivery address saved.');
    } on Exception catch (error) {
      if (mounted) _showMessage('Could not save delivery address: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editBrowsingLocation() async {
    final location = await _openLocationFlow(browsingOnly: true);
    if (location == null || !mounted) return;
    setState(() => _saving = true);
    try {
      await SupabaseService.saveCustomerBrowsingLocation(location);
      await _loadProfile();
      if (mounted) _showMessage('Browsing location saved.');
    } on Exception catch (error) {
      if (mounted) _showMessage('Could not save location: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text('You can sign back in any time.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: danger),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await SupabaseService.client.auth.signOut();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
        (_) => false,
      );
    } on Exception catch (error) {
      if (mounted) {
        _showMessage('Could not log out: $error');
        setState(() => _saving = false);
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _profile == null) {
      return const Center(child: CircularProgressIndicator(color: primaryBlue));
    }
    if (_error != null && _profile == null) {
      return SafeArea(
        child: _ProfileLoadError(message: _error!, onRetry: _loadProfile),
      );
    }

    final fullName = (_profile?['full_name'] as String?)?.trim() ?? '';
    final email = SupabaseService.client.auth.currentUser?.email;
    final phone = (_profile?['phone'] as String?)?.trim() ?? '';
    final activeCount = _orders.where((o) => o.isInProgress).length;
    final deliveredCount = _orders.where((o) => o.status == 'delivered').length;
    final busy = _saving;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Container(
        color: Colors.white,
        child: RefreshIndicator(
          onRefresh: _loadProfile,
          edgeOffset: MediaQuery.paddingOf(context).top,
          child: ListView(
            padding: EdgeInsets.zero,
            physics: const AlwaysScrollableScrollPhysics(
              parent: ClampingScrollPhysics(),
            ),
            children: [
              _ProfileHero(
                name: fullName.isEmpty ? 'AquaDirect customer' : fullName,
                email: email,
                phone: phone,
                total: _orders.length,
                delivered: deliveredCount,
                active: activeCount,
                onEdit: busy ? null : _editPersonalInformation,
              ),
              // The sheet's rounded top corners sit over the hero colour.
              ColoredBox(
                color: _heroBottom,
                child: Container(
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(28),
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 36),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (busy)
                        const Padding(
                          padding: EdgeInsets.only(top: 6, bottom: 2),
                          child: ClipRRect(
                            borderRadius: BorderRadius.all(Radius.circular(4)),
                            child: LinearProgressIndicator(
                              minHeight: 3,
                              color: primaryBlue,
                              backgroundColor: lightBlue,
                            ),
                          ),
                        )
                      else
                        const SizedBox(height: 9),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          _QuickAction(
                            icon: Icons.edit_outlined,
                            label: 'Edit\nprofile',
                            onTap: busy ? null : _editPersonalInformation,
                          ),
                          _QuickAction(
                            icon: Icons.home_work_outlined,
                            label: 'Delivery\naddress',
                            onTap: busy ? null : _editDeliveryAddress,
                          ),
                          _QuickAction(
                            icon: Icons.my_location_rounded,
                            label: 'Browsing\nlocation',
                            onTap: busy ? null : _editBrowsingLocation,
                          ),
                        ],
                      ),
                      const SizedBox(height: 26),
                      const _SectionLabel('Personal details'),
                      _DetailRow(
                        label: 'Full name',
                        value: fullName.isEmpty ? 'Add your name' : fullName,
                        muted: fullName.isEmpty,
                        onTap: busy ? null : _editPersonalInformation,
                      ),
                      _DetailRow(
                        label: 'Mobile number',
                        value: phone.isEmpty ? 'Add your mobile number' : phone,
                        muted: phone.isEmpty,
                        onTap: busy ? null : _editPersonalInformation,
                      ),
                      _DetailRow(
                        label: 'Email',
                        value: email ?? 'Not available',
                        locked: true,
                      ),
                      const SizedBox(height: 26),
                      const _SectionLabel('Delivery'),
                      _DetailRow(
                        icon: Icons.location_on_outlined,
                        label: 'Default delivery address',
                        value: _placeLabel(_deliveryLocation) ??
                            'Add your default delivery address',
                        muted: _placeLabel(_deliveryLocation) == null,
                        onTap: busy ? null : _editDeliveryAddress,
                      ),
                      _DetailRow(
                        icon: Icons.my_location_rounded,
                        label: 'Browsing location',
                        value: _placeLabel(_browsingLocation) ??
                            'Set where to look for nearby stations',
                        muted: _placeLabel(_browsingLocation) == null,
                        onTap: busy ? null : _editBrowsingLocation,
                      ),
                      const SizedBox(height: 28),
                      InkWell(
                        onTap: busy ? null : _signOut,
                        borderRadius: BorderRadius.circular(14),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 14),
                          child: Row(
                            children: [
                              Icon(Icons.logout_rounded, color: danger, size: 21),
                              SizedBox(width: 12),
                              Text(
                                'Log out',
                                style: TextStyle(
                                  color: danger,
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Center(
                        child: Text(
                          'AquaDirect · Fresh water, delivered',
                          style: TextStyle(color: textGray, fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A readable place for the row: the saved address, or coordinates as a
/// fallback. Returns null when nothing is saved yet.
String? _placeLabel(DeliveryLocation? location) {
  if (location == null) return null;
  final address = location.address?.trim();
  if (address != null && address.isNotEmpty) return address;
  final latitude = location.latitude;
  final longitude = location.longitude;
  if (latitude == null || longitude == null) return null;
  return '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';
}

String _initials(String name) {
  final parts = name
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) return 'A';
  if (parts.length == 1) return parts.first[0].toUpperCase();
  return (parts.first[0] + parts.last[0]).toUpperCase();
}

class _ProfileHero extends StatelessWidget {
  const _ProfileHero({
    required this.name,
    required this.email,
    required this.phone,
    required this.total,
    required this.delivered,
    required this.active,
    required this.onEdit,
  });

  final String name;
  final String? email;
  final String phone;
  final int total;
  final int delivered;
  final int active;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [_heroTop, _heroBottom],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Stack(
        children: [
          // Soft ripples, a quiet nod to water.
          Positioned(
            right: -60,
            top: -40 + top * .4,
            child: _Ripple(size: 220, alpha: .07),
          ),
          Positioned(
            right: 10,
            top: 30 + top * .4,
            child: _Ripple(size: 110, alpha: .08),
          ),
          Positioned(
            left: -50,
            bottom: 10,
            child: _Ripple(size: 150, alpha: .05),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(22, top + 18, 22, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Profile',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .2,
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    GestureDetector(
                      onTap: onEdit,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            width: 74,
                            height: 74,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white.withValues(alpha: .45),
                                width: 4,
                              ),
                            ),
                            child: Text(
                              _initials(name),
                              style: const TextStyle(
                                color: primaryBlue,
                                fontSize: 26,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          Positioned(
                            right: -2,
                            bottom: -2,
                            child: Container(
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                color: _heroBottom,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 2),
                              ),
                              child: const Icon(
                                Icons.edit_rounded,
                                color: Colors.white,
                                size: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -.3,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            phone.isNotEmpty ? phone : (email ?? ''),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: .82),
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 9),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: .16),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.water_drop_rounded,
                                  color: Colors.white,
                                  size: 12,
                                ),
                                SizedBox(width: 5),
                                Text(
                                  'AquaDirect member',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.only(top: 18),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: Colors.white.withValues(alpha: .2),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      _HeroStat(value: '$total', label: 'Orders'),
                      const _HeroDivider(),
                      _HeroStat(value: '$delivered', label: 'Delivered'),
                      const _HeroDivider(),
                      _HeroStat(value: '$active', label: 'In progress'),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Ripple extends StatelessWidget {
  const _Ripple({required this.size, required this.alpha});

  final double size;
  final double alpha;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: alpha),
      ),
    ),
  );
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w900,
            height: 1,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: .78),
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class _HeroDivider extends StatelessWidget {
  const _HeroDivider();

  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 30, color: Colors.white.withValues(alpha: .2));
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Expanded(
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: lightBlue,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(icon, color: primaryBlue, size: 23),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: textDark,
                fontSize: 12,
                height: 1.25,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      title.toUpperCase(),
      style: const TextStyle(
        color: textGray,
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: .9,
      ),
    ),
  );
}

/// Flat list row with a hairline underneath. No card, no box.
class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.icon,
    this.onTap,
    this.muted = false,
    this.locked = false,
  });

  final String label;
  final String value;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool muted;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        InkWell(
          onTap: locked ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, color: primaryBlue, size: 22),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          color: textGray,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        value,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: muted ? textGray : textDark,
                          fontSize: 14.5,
                          fontWeight: muted ? FontWeight.w500 : FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  locked ? Icons.lock_outline_rounded : Icons.chevron_right_rounded,
                  color: const Color(0xFFB8C1CF),
                  size: locked ? 18 : 22,
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1, thickness: 1, color: Color(0xFFF0F2F6)),
      ],
    );
  }
}

/// Owns its controllers, so they are disposed with the sheet instead of while
/// the closing animation is still running.
class _EditProfileSheet extends StatefulWidget {
  const _EditProfileSheet({
    required this.initialName,
    required this.initialPhone,
    required this.email,
  });

  final String initialName;
  final String initialPhone;
  final String? email;

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  late final _name = TextEditingController(text: widget.initialName);
  late final _phone = TextEditingController(text: widget.initialPhone);
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  InputDecoration _decoration(String label, IconData icon) => InputDecoration(
    labelText: label,
    prefixIcon: Icon(icon, size: 20),
    filled: true,
    fillColor: const Color(0xFFF6F8FC),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: primaryBlue, width: 1.4),
    ),
  );

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.pop(context, (
      name: _name.text.trim(),
      phone: _phone.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        22,
        12,
        22,
        22 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFDDE2EA),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'Personal information',
              style: TextStyle(
                color: textDark,
                fontSize: 19,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 18),
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              decoration: _decoration('Full name', Icons.person_outline_rounded),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter your name'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _save(),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9+\s-]')),
              ],
              decoration: _decoration('Mobile number', Icons.phone_outlined),
              validator: (value) {
                final digits = (value ?? '').replaceAll(RegExp(r'\D'), '');
                if (digits.isEmpty) return null;
                return digits.length < 7 ? 'Enter a valid mobile number' : null;
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.lock_outline_rounded, size: 15, color: textGray),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    widget.email == null
                        ? 'Email changes are managed through account verification.'
                        : '${widget.email} · changes are managed through account verification.',
                    style: const TextStyle(color: textGray, fontSize: 11.5),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: _save,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text('Save changes'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileLoadError extends StatelessWidget {
  const _ProfileLoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_rounded, size: 42, color: textGray),
          const SizedBox(height: 12),
          const Text(
            'Could not load your profile',
            style: TextStyle(
              color: textDark,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: textGray, fontSize: 12),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Try again'),
          ),
        ],
      ),
    ),
  );
}
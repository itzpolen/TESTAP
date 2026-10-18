class StationSocialLinks {
  const StationSocialLinks({this.facebookUrl, this.instagramUrl});

  final String? facebookUrl;
  final String? instagramUrl;

  static String? _optionalUrl(Object? value) {
    if (value == null) return null;
    if (value is! String || value.trim().isEmpty) {
      throw const FormatException('A station social link is invalid.');
    }
    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const FormatException('A station social link is invalid.');
    }
    return uri.toString();
  }

  factory StationSocialLinks.fromJson(Map<String, dynamic> json) {
    final facebookUrl = _optionalUrl(json['facebook_url']);
    final instagramUrl = _optionalUrl(json['instagram_url']);
    if (facebookUrl != null && !_isFacebookUrl(facebookUrl)) {
      throw const FormatException('A station Facebook link is invalid.');
    }
    if (instagramUrl != null && !_isInstagramUrl(instagramUrl)) {
      throw const FormatException('A station Instagram link is invalid.');
    }
    return StationSocialLinks(
      facebookUrl: facebookUrl,
      instagramUrl: instagramUrl,
    );
  }

  static bool _isFacebookUrl(String value) {
    final host = Uri.parse(value).host.toLowerCase();
    return host == 'facebook.com' ||
        host.endsWith('.facebook.com') ||
        host == 'fb.com' ||
        host.endsWith('.fb.com');
  }

  static bool _isInstagramUrl(String value) {
    final host = Uri.parse(value).host.toLowerCase();
    return host == 'instagram.com' || host.endsWith('.instagram.com');
  }
}

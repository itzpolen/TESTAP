import 'package:supabase_flutter/supabase_flutter.dart';

import 'env_config.dart';

class SupabaseConfig {
  const SupabaseConfig._();

  static String? initializationError;
  static bool _initialized = false;

  static bool get isInitialized => _initialized;

  static SupabaseClient get client {
    if (!_initialized) {
      throw StateError(
        initializationError ??
            'Supabase is not configured. Add your project URL and anon key to .env.',
      );
    }
    return Supabase.instance.client;
  }

  static Future<void> initialize() async {
    if (!EnvConfig.hasSupabaseCredentials) {
      initializationError =
          'Supabase credentials are missing. Add SUPABASE_URL and '
          'SUPABASE_ANON_KEY to the root .env file.';
      return;
    }

    final uri = Uri.tryParse(EnvConfig.supabaseUrl);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty) {
      initializationError = 'SUPABASE_URL in .env must be a valid HTTP URL.';
      return;
    }

    try {
      await Supabase.initialize(
        url: EnvConfig.supabaseUrl,
        publishableKey: EnvConfig.supabaseAnonKey,
      );
      _initialized = true;
      initializationError = null;
    } on Exception catch (exception) {
      initializationError = 'Supabase initialization failed: $exception';
      rethrow;
    }
  }
}

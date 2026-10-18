import 'package:flutter/material.dart';

import 'app.dart';
import 'config/env_config.dart';
import 'config/supabase_config.dart';

export 'app.dart' show AquaDirectApp, MyApp;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await EnvConfig.load();
    await SupabaseConfig.initialize();
  } on Exception catch (exception, stackTrace) {
    SupabaseConfig.initializationError =
        'Could not load Supabase configuration: $exception';
    debugPrint('$exception\n$stackTrace');
  }
  runApp(const MyApp());

  
}

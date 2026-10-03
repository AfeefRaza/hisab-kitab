import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config.dart';
import 'core/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!AppConfig.isConfigured) {
    runApp(const _MisconfiguredApp());
    return;
  }
  await Supabase.initialize(url: AppConfig.supabaseUrl, publishableKey: AppConfig.supabaseKey);
  runApp(const HisabKitabApp());
}

class _MisconfiguredApp extends StatelessWidget {
  const _MisconfiguredApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: buildTheme(Brightness.light),
      home: const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Hisab Kitab is not configured.\n\nBuild with:\n'
              'flutter build web --dart-define-from-file=.env\n\n'
              '(see .env.example and README.md)',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}

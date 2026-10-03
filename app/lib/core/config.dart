/// Build-time configuration, injected with --dart-define (see .env.example).
/// Only public values belong here: the Supabase URL and its *publishable* key
/// are safe in a client app because every table is protected by RLS.
/// Never pass service-role keys or integration secrets to the client.
class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  static const appEnv = String.fromEnvironment('APP_ENV', defaultValue: 'production');
  static const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

  static bool get isConfigured => supabaseUrl.isNotEmpty && supabaseKey.isNotEmpty;
  static bool get isProduction => appEnv == 'production';
}

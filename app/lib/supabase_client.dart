// app/lib/supabase_client.dart
import 'package:supabase_flutter/supabase_flutter.dart';

const supabaseUrl = 'https://hqchmtkdpashuiarekmh.supabase.co';
const supabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhxY2htdGtkcGFzaHVpYXJla21oIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY4OTEwMDEsImV4cCI6MjA5MjQ2NzAwMX0.NP3i2fK3WdrezYAaK3pyV_JYPHU0MlI-Jt36vpU9jY4';

SupabaseClient get supabase => Supabase.instance.client;

Future<void> initSupabase() async {
  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnonKey,
  );
}

// app/lib/backend/auth.dart
import 'package:omi/supabase_client.dart';

/// Retorna o JWT atual do usuário Supabase para usar nas requests ao backend.
Future<String?> getSupabaseToken() async {
  final session = supabase.auth.currentSession;
  return session?.accessToken;
}

/// Retorna o UID do usuário logado.
String? getCurrentUserId() {
  return supabase.auth.currentUser?.id;
}

/// Retorna true se há um usuário logado.
bool get isLoggedIn => supabase.auth.currentUser != null;

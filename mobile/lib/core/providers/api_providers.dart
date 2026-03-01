import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/api_service.dart';
import 'firebase_providers.dart';

final apiServiceProvider = Provider<ApiService>((ref) {
  final firebaseService = ref.watch(firebaseServiceProvider);
  return ApiService(firebaseService: firebaseService);
});

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/firebase_service.dart';

final firebaseServiceProvider =
    Provider<FirebaseService>((ref) => FirebaseService());

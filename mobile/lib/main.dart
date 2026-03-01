import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicializar Firebase (requiere google-services.json en Android
  // y GoogleService-Info.plist en iOS - ver FASE_0_PLAN.md Paso 7)
  await Firebase.initializeApp();

  runApp(
    // ProviderScope es el widget raíz de Riverpod
    const ProviderScope(
      child: GeminiAgentApp(),
    ),
  );
}

class GeminiAgentApp extends StatelessWidget {
  const GeminiAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gemini Live Agent',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A73E8), // Google Blue
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      // Navegación completa se añade en Fase 2 (go_router)
      home: const Scaffold(
        body: Center(
          child: Text(
            'Gemini Live Agent\nFase 0 - Setup Completo',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 24),
          ),
        ),
      ),
    );
  }
}

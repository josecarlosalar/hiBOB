import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'core/providers/firebase_providers.dart';
import 'features/intro/screens/splash_screen.dart';
import 'features/auth/screens/login_screen.dart';
import 'features/camera/screens/camera_screen.dart';
import 'features/chat/screens/chat_screen.dart';
import 'features/conversations/screens/conversations_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const ProviderScope(child: GeminiAgentApp()));
}

class GeminiAgentApp extends StatelessWidget {
  const GeminiAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'hiBOB AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF673AB7), // Deep Purple
          primary: const Color(0xFF673AB7),
          secondary: const Color(0xFF00B0FF), // Light Blue / Cyan
          surface: const Color(0xFF121212),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        fontFamily: 'Roboto', 
        textTheme: const TextTheme(
          headlineMedium: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.1),
          bodyLarge: TextStyle(fontSize: 16),
        ),
      ),
      home: const SplashScreen(nextScreen: _AuthGate()),
    );
  }
}

class _AuthGate extends ConsumerWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final firebase = ref.watch(firebaseServiceProvider);
    return StreamBuilder<User?>(
      stream: firebase.authStateChanges,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.data == null) return const LoginScreen();
        return const _HomeShell();
      },
    );
  }
}

class _HomeShell extends StatefulWidget {
  const _HomeShell();

  @override
  State<_HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<_HomeShell> {
  int _currentIndex = 0;

  static const _screens = [
    ChatScreen(),
    CameraScreen(),
    ConversationsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline_rounded),
            selectedIcon: Icon(Icons.chat_bubble_rounded),
            label: 'Chat',
          ),
          NavigationDestination(
            icon: Icon(Icons.camera_alt_outlined),
            selectedIcon: Icon(Icons.camera_alt_rounded),
            label: 'Cámara',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history_rounded),
            label: 'Historial',
          ),
        ],
      ),
    );
  }
}

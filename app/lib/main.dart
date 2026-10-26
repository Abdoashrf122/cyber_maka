import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'account.dart';
import 'config.dart';
import 'core.dart';
import 'home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1180, 800),
        minimumSize: Size(420, 560),
        center: true,
        title: 'سيبر مكة — الأدمن',
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }
  // مفتاح JWT القديم (anon) — السيرفر من غير Kong فالمفاتيح الجديدة (sb_publishable_) مش مدعومة
  // ignore: deprecated_member_use
  await Supabase.initialize(url: kApiUrl, anonKey: kAnonKey);
  runApp(const MakaApp());
}

class MakaApp extends StatelessWidget {
  const MakaApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF8B5CF6), brightness: Brightness.dark);
    return MaterialApp(
      title: 'سيبر مكة — الأدمن',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF0E0E1A),
        cardTheme: const CardThemeData(color: Color(0xFF181830), margin: EdgeInsets.symmetric(vertical: 6)),
        fontFamily: isWindows ? 'Segoe UI' : null,
        inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: sb.auth.onAuthStateChange,
      builder: (context, _) {
        if (sb.auth.currentSession == null) return const LoginScreen();
        return const AdminCheck();
      },
    );
  }
}

class AdminCheck extends StatefulWidget {
  const AdminCheck({super.key});
  @override
  State<AdminCheck> createState() => _AdminCheckState();
}

class _AdminCheckState extends State<AdminCheck> {
  late Future<Map<String, dynamic>> _me = _load();

  Future<Map<String, dynamic>> _load() async => Map<String, dynamic>.from(await rpc('admin_me') as Map);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _me,
      builder: (context, s) {
        if (s.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (s.hasError) {
          return _Message(
            text: s.error is ApiError ? s.error.toString() : errorText('network'),
            action: 'جرّب تاني',
            onAction: () => setState(() => _me = _load()),
          );
        }
        if (s.data?['is_admin'] != true) {
          return _Message(text: errorText('not_admin'), action: 'خروج', onAction: () => sb.auth.signOut());
        }
        if (s.data?['must_change_password'] == true) {
          return ForceChangePasswordScreen(onDone: () => setState(() => _me = _load()));
        }
        return HomeScreen(adminName: (s.data?['name'] ?? '') as String);
      },
    );
  }
}

class _Message extends StatelessWidget {
  final String text;
  final String action;
  final VoidCallback onAction;
  const _Message({required this.text, required this.action, required this.onAction});

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(text, style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 16),
            FilledButton(onPressed: onAction, child: Text(action)),
          ]),
        ),
      );
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  String? _err;

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await sb.auth.signInWithPassword(email: loginEmail(_email.text), password: _pass.text);
    } on AuthException {
      setState(() => _err = 'اسم المستخدم أو كلمة السر غلط.');
    } catch (_) {
      setState(() => _err = errorText('network'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: AutofillGroup(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Icon(Icons.sports_esports, size: 64, color: Color(0xFF8B5CF6)),
                const SizedBox(height: 8),
                const Text('سيبر مكة — الأدمن', textAlign: TextAlign.center, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                const SizedBox(height: 24),
                TextField(
                  controller: _email,
                  textDirection: TextDirection.ltr,
                  autocorrect: false,
                  autofillHints: const [AutofillHints.username],
                  decoration: const InputDecoration(labelText: 'اسم المستخدم'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pass,
                  obscureText: true,
                  textDirection: TextDirection.ltr,
                  autofillHints: const [AutofillHints.password],
                  decoration: const InputDecoration(labelText: 'كلمة السر'),
                  onSubmitted: (_) => _busy ? null : _login(),
                ),
                if (_err != null) ...[
                  const SizedBox(height: 12),
                  Text(_err!, style: const TextStyle(color: Color(0xFFFCA5A5))),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _login,
                  style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)),
                  child: Text(_busy ? 'جاري الدخول…' : 'دخول'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => showForgotPassword(context),
                  child: const Text('نسيت كلمة السر؟'),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

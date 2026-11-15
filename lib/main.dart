import 'dart:async';
import 'services/sound.dart';
import 'services/presence.dart';
import 'widgets/duel_invitation_host.dart';
import 'widgets/chat_notification_host.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'screens/auth/login_screen.dart';
import 'screens/character/character_creation_screen.dart';
import 'screens/main_shell.dart';
import 'state/user_doc.dart';
import 'screens/startup_screen.dart';
import 'firebase_options.dart';
import 'services/private_data.dart';
import 'services/legal_consent.dart';
import 'services/google_auth.dart';
import 'screens/auth/legal_consent_screen.dart';

/// Run with  --dart-define=PERF_OVERLAY=true  to draw the frame graph.
const bool kPerfOverlay = bool.fromEnvironment('PERF_OVERLAY');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (kDebugMode) _watchOverflows();
  runApp(const _FirebaseStartup());
}

class _FirebaseStartup extends StatefulWidget {
  const _FirebaseStartup();
  @override
  State<_FirebaseStartup> createState() => _FirebaseStartupState();
}

class _FirebaseStartupState extends State<_FirebaseStartup> {
  late Future<void> _startup = _initialize();
  Future<FirebaseApp>? _firebase;

  Future<void> _initialize() async {
    _firebase ??= Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)
        .onError((Object error, StackTrace stack) {
      _firebase = null;
      Error.throwWithStackTrace(error, stack);
    });
    await _firebase!.timeout(const Duration(seconds: 20));
    if (kIsWeb) {
      // Keep data + not-yet-sent writes on the device (IndexedDB), so a run
      // finished on weak signal still uploads after a reload.
      try {
        FirebaseFirestore.instance.settings = const Settings(
          persistenceEnabled: true,
          // Safari / some networks block the normal live channel, so updates
          // (coins after buying...) arrived minutes late. Fall back when needed.
          webExperimentalAutoDetectLongPolling: true,
        );
      } catch (_) {}
    }
    // Sound is optional: never let it hold up the app.
    unawaited(
      Sound.I
          .init()
          .timeout(const Duration(seconds: 3))
          .catchError((Object _) {}),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _startup,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.done &&
          !snapshot.hasError) {
        return const HakbangHeroApp();
      }
      return MaterialApp(
        home: StartupView(
          progress: 0.03,
          status: snapshot.hasError
              ? 'COULD NOT CONNECT. CHECK YOUR NETWORK.'
              : 'STARTING...',
          failed: snapshot.hasError,
          stuck: snapshot.hasError,
          onRetry: snapshot.hasError
              ? () => setState(() => _startup = _initialize())
              : null,
        ),
      );
    },
  );
}

/// Debug builds only: prints ONE short line per layout overflow with the
/// size and the source file:line of the widget, e.g.
///   [overflow] 4.0px  Row  lib/widgets/foo.dart:123
/// so "overflowed by 4 pixels" errors are easy to find and fix.
void _watchOverflows() {
  final previous = FlutterError.onError;
  final seen = <String>{};
  FlutterError.onError = (details) {
    final text = details.toString();
    if (text.contains('overflowed by')) {
      final px = RegExp(
        r'overflowed by ([\d.]+) pixels',
      ).firstMatch(text)?.group(1);
      final where = RegExp(
        r'(lib/[\w/]+\.dart:\d+)',
      ).firstMatch(text)?.group(1);
      final widget = RegExp(
        r'error-causing widget was:\s*(\w+)',
      ).firstMatch(text)?.group(1);
      final line = '[overflow] ${px}px  ${widget ?? '?'}  ${where ?? '?'}';
      if (seen.add(line)) debugPrint(line);
    }
    (previous ?? FlutterError.presentError)(details);
  };
}

class HakbangHeroApp extends StatelessWidget {
  const HakbangHeroApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HakbangHero',
      navigatorKey: duelNavigatorKey,
      debugShowCheckedModeBanner: false,
      showPerformanceOverlay: kPerfOverlay,
      // Browsers only allow sound after a tap: any touch wakes the music.
      builder: (context, child) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          Sound.I.userGesture();
          Presence.I.touch();
        },
        child: ChatNotificationHost(
          child: DuelInvitationHost(child: child ?? const SizedBox.shrink())),
      ),
      theme: ThemeData(
        brightness: Brightness.dark,
        fontFamily:
            'Nunito', // bundled, see pubspec.yaml (BlockText uses Lilita One)
        scaffoldBackgroundColor: const Color(0xFF060C06),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00FF41),
          secondary: Color(0xFF00CC33),
          surface: Color(0xFF0D1A0D),
        ),
      ),
      navigatorObservers: [_SoundNavObserver(), duelNavigationObserver],
      home: const _AuthGate(),
    );
  }
}

/// Plays a whoosh when a screen / dialog / sheet opens and a soft blip when it
/// closes, so every part of the app gets sound without touching each screen.
class _SoundNavObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) Sound.I.play(Sfx.open, volume: 0.6);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) Sound.I.play(Sfx.back, volume: 0.6);
  }
}

/// Login / sign-up: no background music here. (Signing out lands here too, so
/// the music stops the moment the player logs out.)
class _SilentLogin extends StatefulWidget {
  const _SilentLogin();

  @override
  State<_SilentLogin> createState() => _SilentLoginState();
}

class _SilentLoginState extends State<_SilentLogin> {
  @override
  void initState() {
    super.initState();
    Sound.I.music(null);
  }

  @override
  Widget build(BuildContext context) => const LoginScreen();
}

class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  late Stream<User?> _auth = _watch().distinct((a, b) => a?.uid == b?.uid);

  Stream<User?> _watch() async* {
    final auth = FirebaseAuth.instance;
    yield await auth
        .authStateChanges()
        .timeout(const Duration(seconds: 20))
        .first;
    yield* auth.authStateChanges();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: _auth,
      builder: (context, snapshot) => ValueListenableBuilder<bool>(
        valueListenable: GoogleAuth.inProgress,
        builder: (context, signingUp, _) {
          if (signingUp) return const _SilentLogin();
          if (snapshot.hasError) {
            return StartupView(
              progress: 0.03,
              status: 'COULD NOT RESTORE SIGN-IN',
              failed: true,
              stuck: true,
              onRetry: () => setState(() {
                _auth = _watch().distinct((a, b) => a?.uid == b?.uid);
              }),
            );
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const StartupView(progress: 0.03, status: 'STARTING...');
          }
          final user = snapshot.data;
          if (user != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              duelNavigatorKey.currentState?.popUntil((route) => route.isFirst);
            });
            // loading screen (profile, hero art, icons, effects), then the app
            return StartupGate(
              key: ValueKey(user.uid),
              uid: user.uid,
              child: const ProfileCompletionGate(),
            );
          }
          return const _SilentLogin();
        },
      ),
    );
  }
}

/// Both sign-in methods and app restarts use the same required profile check.
class ProfileCompletionGate extends StatefulWidget {
  const ProfileCompletionGate({super.key});

  @override
  State<ProfileCompletionGate> createState() => _ProfileCompletionGateState();
}

class _ProfileCompletionGateState extends State<ProfileCompletionGate> {
  late Future<Map<String, dynamic>> _profile;
  bool _needsConsent = false;

  @override
  void initState() {
    super.initState();
    _profile = _read();
  }

  Future<Map<String, dynamic>> _read() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('Please sign in again.');
    final user = FirebaseAuth.instance.currentUser!;
    final document = await UserDoc.instance.stream.first.timeout(
      const Duration(seconds: 8),
    );
    if (!document.exists) {
      await GoogleAuth.ensureUserDoc(
        user,
        user.displayName ?? 'Hero',
      ).timeout(const Duration(seconds: 20));
    }
    final profile = await PrivateData.readProfile(uid);
    _needsConsent =
        LegalConsent.requiredFor(profile) &&
        !await LegalConsent.hasAccepted(uid);
    return profile;
  }

  @override
  Widget build(BuildContext context) {
    // Keep this decision stable while onboarding saves its batch. A local
    // pending-write event must not remove the form before the server answers.
    return FutureBuilder<Map<String, dynamic>>(
      future: _profile,
      builder: (context, profile) {
        if (profile.connectionState != ConnectionState.done) {
          return const StartupView(
            status: 'LOADING YOUR PROFILE...',
            progress: 0.5,
          );
        }
        if (profile.hasError) {
          return StartupView(
            status: 'COULD NOT LOAD YOUR PROFILE',
            progress: 0.5,
            failed: true,
            stuck: true,
            onRetry: () => setState(() => _profile = _read()),
          );
        }
        if (_needsConsent) {
          return LegalConsentScreen(
            onAccepted: () {
              setState(() => _profile = _read());
            },
          );
        }
        if (!PrivateData.profileComplete(profile.data!)) {
          return CharacterCreationScreen(
            onCompleted: () {
              setState(() => _profile = _read());
            },
          );
        }
        return const MainShell();
      },
    );
  }
}

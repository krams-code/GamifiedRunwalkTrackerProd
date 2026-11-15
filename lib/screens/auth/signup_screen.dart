import 'dart:async';
import 'package:hakbanghero/widgets/google_logo.dart';
import 'package:hakbanghero/services/usernames.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../services/google_auth.dart';
import '../../utils/password_rules.dart';
import '../../widgets/block_inputs.dart';
import '../../widgets/block_ui.dart';
import '../../widgets/emoji_icons.dart';
import '../../services/legal_consent.dart';
import '../../widgets/legal_consent_controls.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _usernameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _loading = false;
  bool _obscure = true;
  bool _obscureConfirm = true;
  bool _submitted = false; // show field errors only after the first attempt
  bool _termsAccepted = false;
  bool _privacyAcknowledged = false;
  /// The hero type picked on this screen: 'male' | 'female' (null until chosen).
  /// Saved to users/{uid}.gender and used to route the avatar's body sprites.
  String? selectedGender;

  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]{2,}$');
  static final _nameRe = RegExp(r'^[A-Za-z0-9_ ]{3,16}$');

  // ── validation ───────────────────────────────────────────────────────
  String? get _nameError {
    final v = _usernameCtrl.text.trim();
    if (v.isEmpty) return 'Pick a hero name';
    if (!_nameRe.hasMatch(v)) return '3-16 letters, numbers, _ or spaces';
    return null;
  }

  String? get _emailError {
    final v = _emailCtrl.text.trim();
    if (v.isEmpty) return 'Enter your email';
    if (!_emailRe.hasMatch(v)) return 'That email looks invalid';
    return null;
  }

  String? get _passError =>
      PasswordRules.isStrong(_passCtrl.text) ? null : 'Meet all the password rules below';

  String? get _confirmError {
    if (_confirmCtrl.text.isEmpty) return 'Re-enter your password';
    if (_confirmCtrl.text != _passCtrl.text) return 'Passwords do not match';
    return null;
  }

  bool get _valid =>
      _nameError == null &&
      _emailError == null &&
      _passError == null &&
      _confirmError == null &&
      selectedGender != null &&
      LegalConsent.validationError(_termsAccepted, _privacyAcknowledged) == null;

  // ── flow ─────────────────────────────────────────────────────────────
  Future<void> _goHome() async {
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _snack(String msg) {
    if (!mounted) return;
    blockSnack(context, msg);
  }

  Future<UserCredential>? _accountRequest;
  bool _verificationRequested = false;

  Future<void> _signupEmail() async {
    if (_loading) return;
    setState(() => _submitted = true);
    if (!_valid) {
      _snack(LegalConsent.validationError(_termsAccepted, _privacyAcknowledged) ??
          'Pick your hero type and fix the red fields.');
      return;
    }
    final username = _usernameCtrl.text.trim();
    final email = _emailCtrl.text.trim(), password = _passCtrl.text;
    final gender = selectedGender;
    final terms = _termsAccepted, privacy = _privacyAcknowledged;
    setState(() => _loading = true);
    GoogleAuth.inProgress.value = true;
    try {
      if (_accountRequest == null && FirebaseAuth.instance.currentUser == null &&
          await Usernames.isTaken(username)) {
        _snack('That username is taken. Try another one.');
        return;
      }
      var user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        // A UI timeout does not cancel account creation. Retry awaits the same
        // request, and the root auth listener handles a late success.
        _accountRequest ??= FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email, password: password);
        user = (await _accountRequest!.timeout(const Duration(seconds: 30))).user;
      }
      if (user == null) throw StateError('Sign in to finish your account.');
      await GoogleAuth.ensureUserDoc(user, username, gender: gender,
        termsAccepted: terms, privacyAcknowledged: privacy)
          .timeout(const Duration(seconds: 20));
      if (!_verificationRequested && !user.emailVerified) {
        _verificationRequested = true;
        unawaited(user.sendEmailVerification().catchError((Object _) {}));
      }
      _goHome();
    } on FirebaseAuthException catch (e) {
      _accountRequest = null;
      _snack(e.code == 'email-already-in-use'
        ? 'This email already has an account. Log in to continue.'
        : 'Could not confirm signup (${e.code}). Check your connection.');
    } on TimeoutException {
      _snack(FirebaseAuth.instance.currentUser != null
        ? 'Your account is created. Profile setup is pending; retry from the loading screen.'
        : 'Account creation is still unconfirmed. Check your connection; retry will check the same request.');
    } catch (_) {
      _snack(FirebaseAuth.instance.currentUser != null
        ? 'Your account exists. Reconnect to finish setting up your profile.'
        : 'Could not confirm signup. Check your connection and retry.');
    } finally {
      GoogleAuth.inProgress.value = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _signupGoogle() async {
    if (_loading) return;
    setState(() => _submitted = true);
    final error = LegalConsent.validationError(_termsAccepted, _privacyAcknowledged);
    if (error != null) { _snack(error); return; }
    final chosenName = _nameError == null ? _usernameCtrl.text.trim() : null;
    final gender = selectedGender;
    setState(() => _loading = true);
    GoogleAuth.inProgress.value = true;
    try {
      final r = await GoogleAuth.signIn().timeout(const Duration(seconds: 60));
      if (r.user != null) {
        await GoogleAuth.ensureUserDoc(r.user!, chosenName ?? r.user!.displayName ?? 'Hero', gender: gender,
          termsAccepted: _termsAccepted, privacyAcknowledged: _privacyAcknowledged)
            .timeout(const Duration(seconds: 20));
        _goHome();
      } else { _snack(r.message ?? 'Google sign-up was not completed.'); }
    } catch (_) {
      _snack('Sign-in is not confirmed yet. Reconnect to continue account setup.');
    } finally {
      GoogleAuth.inProgress.value = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  // ── UI ───────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Rb.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: PressBlock(
                      color: const Color(0xFFE2E2E2),
                      edge: const Color(0xFF6B6B6B),
                      depth: 4,
                      radius: 12,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      onTap: () => Navigator.pop(context),
                      child: const EmojiText('◀',
                          style: TextStyle(
                              color: Color(0xFF232527),
                              fontSize: 16,
                              fontWeight: FontWeight.w900)),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const AuthBanner(
                    title: 'CREATE ACCOUNT',
                    subtitle: 'BEGIN YOUR HERO JOURNEY',
                  ),
                  const SizedBox(height: 22),
                  Block(
                    color: Rb.panel,
                    edge: Rb.panelEdge,
                    depth: 6,
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        BlockTextField(
                          label: 'HERO NAME',
                          hint: 'e.g. SwiftRunner',
                          icon: '🧑',
                          controller: _usernameCtrl,
                          action: TextInputAction.next,
                          onChanged: (_) => setState(() {}),
                          error: _submitted ? _nameError : null,
                        ),
                        const SizedBox(height: 16),
                        BlockTextField(
                          label: 'EMAIL',
                          hint: 'hero@email.com',
                          icon: '✉️',
                          controller: _emailCtrl,
                          keyboardType: TextInputType.emailAddress,
                          action: TextInputAction.next,
                          onChanged: (_) => setState(() {}),
                          error: _submitted ? _emailError : null,
                        ),
                        const SizedBox(height: 16),
                        BlockTextField(
                          label: 'PASSWORD',
                          hint: 'Make it strong!',
                          icon: '🔒',
                          controller: _passCtrl,
                          obscure: _obscure,
                          action: TextInputAction.next,
                          onChanged: (_) => setState(() {}),
                          error: _submitted ? _passError : null,
                          suffix: _eye(_obscure, () => setState(() => _obscure = !_obscure)),
                        ),
                        const SizedBox(height: 12),
                        _strengthMeter(),
                        const SizedBox(height: 16),
                        BlockTextField(
                          label: 'CONFIRM PASSWORD',
                          hint: 'Type it again',
                          icon: '🔁',
                          controller: _confirmCtrl,
                          obscure: _obscureConfirm,
                          action: TextInputAction.done,
                          onChanged: (_) => setState(() {}),
                          error: (_submitted || _confirmCtrl.text.isNotEmpty)
                              ? _confirmError
                              : null,
                          suffix: _eye(_obscureConfirm,
                              () => setState(() => _obscureConfirm = !_obscureConfirm)),
                        ),
                        const SizedBox(height: 18),
                        const Padding(
                          padding: EdgeInsets.only(left: 4, bottom: 6),
                          child: BlockText('HERO TYPE', size: 12, stroke: 3.5),
                        ),
                        Row(
                          children: [
                            Expanded(child: _genderTile('male', '♂ MALE')),
                            const SizedBox(width: 10),
                            Expanded(child: _genderTile('female', '♀ FEMALE')),
                          ],
                        ),
                        if (_submitted && selectedGender == null)
                          const Padding(
                            padding: EdgeInsets.only(left: 4, top: 8),
                            child: BlockText('⚠ Choose a hero type',
                                size: 11, stroke: 3, color: Color(0xFFFF8A80)),
                          ),
                        const SizedBox(height: 22),
                        LegalConsentControls(
                          terms: _termsAccepted, privacy: _privacyAcknowledged,
                          submitted: _submitted, enabled: !_loading,
                          onTermsChanged: (v) => setState(() => _termsAccepted = v),
                          onPrivacyChanged: (v) => setState(() => _privacyAcknowledged = v),
                        ),
                        const SizedBox(height: 16),
                        NeonBlueButton(
                          label: 'CREATE HERO',
                          loading: _loading,
                          onTap: _signupEmail,
                        ),
                        const SizedBox(height: 16),
                        PressBlock(
                          color: const Color(0xFFF2F3F5),
                          edge: const Color(0xFF6B6F75),
                          depth: 5,
                          radius: 14,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          onTap: _loading ? null : _signupGoogle,
                          child: const SizedBox(
                            width: double.infinity,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                GoogleLogo(size: 20),
                                SizedBox(width: 10),
                                BlockText('SIGN UP WITH GOOGLE', size: 13, stroke: 3.5),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  PressBlock(
                    color: Rb.slot,
                    edge: Rb.slateEdge,
                    depth: 5,
                    radius: 14,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    onTap: () => Navigator.pop(context),
                    child: const SizedBox(
                      width: double.infinity,
                      child: Center(
                        child: BlockText('ALREADY A HERO? LOGIN',
                            size: 13, stroke: 3.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _eye(bool obscured, VoidCallback onTap) =>
      PasswordEye(obscured: obscured, onTap: onTap);

  /// Live checklist + 6-segment power bar.
  Widget _strengthMeter() {
    final pass = _passCtrl.text;
    final done = PasswordRules.passed(pass);
    final total = PasswordRules.all.length;
    final color = done <= 2
        ? Rb.red
        : done <= 4
            ? Rb.orange
            : done < total
                ? Rb.gold
                : Rb.neon;
    final word = pass.isEmpty
        ? 'EMPTY'
        : done <= 2
            ? 'WEAK'
            : done <= 4
                ? 'OKAY'
                : done < total
                    ? 'ALMOST'
                    : 'LEGENDARY';

    return Block(
      color: Rb.slate,
      edge: Rb.slateEdge,
      depth: 4,
      radius: 12,
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const BlockText('🛡 PASSWORD POWER', size: 11, stroke: 3),
              const Spacer(),
              BlockText(word, size: 11, stroke: 3, color: color),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (var i = 0; i < total; i++)
                Expanded(
                  child: Container(
                    height: 12,
                    margin: EdgeInsets.only(right: i == total - 1 ? 0 : 4),
                    decoration: BoxDecoration(
                      color: i < done ? color : const Color(0xFF3A3D40),
                      border: Border.all(color: Colors.black, width: 2),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          for (final r in PasswordRules.all)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                children: [
                  BlockText(r.test(pass) ? '✔' : '✖',
                      size: 11,
                      stroke: 2.5,
                      color: r.test(pass) ? Rb.neon : const Color(0xFFFF8A80)),
                  const SizedBox(width: 8),
                  BlockText(r.label,
                      size: 11,
                      stroke: 2.5,
                      color: r.test(pass) ? Colors.white : const Color(0xFFB8BDC4)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _genderTile(String value, String label) {
    final sel = selectedGender == value;
    return PressBlock(
      color: sel ? Rb.gold : Rb.slot,
      edge: sel ? Rb.goldEdge : Rb.slateEdge,
      depth: 6,
      radius: 14,
      forcePressed: sel,
      padding: const EdgeInsets.symmetric(vertical: 14),
      onTap: () => setState(() => selectedGender = value),
      child: Center(child: BlockText(label, size: 14, stroke: 3.5)),
    );
  }
}

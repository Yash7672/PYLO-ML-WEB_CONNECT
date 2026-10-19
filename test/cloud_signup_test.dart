import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:task_app/services/cloud/cloud_sync_service.dart';

/// A stand-in for Supabase GoTrue (`/auth/v1/...`).
///
/// [confirmEmail] mirrors the project's "Confirm email" setting: when it is on,
/// `/signup` answers with the user but no session.
class _FakeGoTrue {
  _FakeGoTrue({required this.confirmEmail});

  final bool confirmEmail;
  final List<Map<String, dynamic>> signupBodies = [];
  final List<Map<String, dynamic>> tokenBodies = [];

  static const anonKey = 'sb_publishable_test_123';
  static const projectUrl = 'https://project-123.supabase.co';

  http.Client get httpClient => MockClient((request) async {
        final raw = request.body;
        final body = raw.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(raw) as Map<String, dynamic>;
        if (request.url.path == '/auth/v1/signup') {
          signupBodies.add(body);
          final email = body['email'] as String;
          // GoTrue mirrors its real shapes: with "Confirm email" on it answers
          // with the bare user (no session); with auto-confirm it answers with a
          // full session payload.
          return http.Response(
            jsonEncode(confirmEmail ? _user(email) : _session(email)),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path == '/auth/v1/token') {
          tokenBodies.add(body);
          return http.Response(
            jsonEncode(_session(body['email'] as String)),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 404, headers: {'content-type': 'application/json'});
      });

  static Map<String, dynamic> _user(String email) => {
        'id': 'user-1',
        'aud': 'authenticated',
        'role': 'authenticated',
        'email': email,
        'app_metadata': {'provider': 'email', 'providers': ['email']},
        'user_metadata': {},
        'identities': [],
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
      };

  static Map<String, dynamic> _session(String email) => {
        'access_token': 'access-token',
        'refresh_token': 'refresh-token',
        'token_type': 'bearer',
        'expires_in': 3600,
        'user': _user(email),
      };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Create Account signUp', () {
    test('reaches Supabase instead of failing on the PKCE verifier',
        () async {
      final gotrue = _FakeGoTrue(confirmEmail: true);
      // Exactly the options CloudSyncService._buildClientUnlocked uses, so this
      // test fails if that wiring regresses.
      final client = SupabaseClient(
        _FakeGoTrue.projectUrl,
        _FakeGoTrue.anonKey,
        authOptions: CloudSyncService.buildAuthOptions(),
        httpClient: gotrue.httpClient,
      );
      addTearDown(client.dispose);

      final response = await client.auth.signUp(
        email: 'brand.new.user@example.com',
        password: 'password123',
      );

      // The request actually left the device...
      expect(gotrue.signupBodies, hasLength(1));
      expect(gotrue.signupBodies.single['email'], 'brand.new.user@example.com');
      expect(gotrue.signupBodies.single['password'], 'password123');
      // ...carrying a PKCE challenge, which only happens when the
      // code-verifier storage is wired up.
      expect(gotrue.signupBodies.single['code_challenge'], isNotNull);
      expect(gotrue.signupBodies.single['code_challenge_method'], 's256');
      // Email confirmation is on, so Supabase returns the user with no session.
      // CloudSyncService turns exactly this into "check your inbox".
      expect(response.user?.email, 'brand.new.user@example.com');
      expect(response.session, isNull);
    });

    test('returns a session when the project auto-confirms email', () async {
      final gotrue = _FakeGoTrue(confirmEmail: false);
      final client = SupabaseClient(
        _FakeGoTrue.projectUrl,
        _FakeGoTrue.anonKey,
        authOptions: CloudSyncService.buildAuthOptions(),
        httpClient: gotrue.httpClient,
      );
      addTearDown(client.dispose);

      final response = await client.auth.signUp(
        email: 'autoconfirm.user@example.com',
        password: 'password123',
      );

      expect(response.session, isNotNull);
      expect(response.session?.user.email, 'autoconfirm.user@example.com');
      expect(client.auth.currentUser, isNotNull);
    });

    test('regression: a client without PKCE storage cannot sign up', () async {
      // This is what CloudSyncService used to build. signUp died in
      // _generatePKCECodeChallenge() before any HTTP request, which the old
      // error handling flattened into "cloud server error".
      final client = SupabaseClient(
        _FakeGoTrue.projectUrl,
        _FakeGoTrue.anonKey,
        authOptions: const FlutterAuthClientOptions(),
        httpClient: _FakeGoTrue(confirmEmail: true).httpClient,
      );
      addTearDown(client.dispose);

      expect(const FlutterAuthClientOptions().pkceAsyncStorage, isNull);
      expect(const FlutterAuthClientOptions().authFlowType, AuthFlowType.pkce);

      // It is an assertion / null-check failure, not an AuthException — which is
      // why the old handler reported it as a generic "cloud server error".
      await expectLater(
        client.auth.signUp(
          email: 'brand.new.user@example.com',
          password: 'password123',
        ),
        throwsA(isNot(isA<AuthException>())),
      );
    });
  });

  group('Login is unaffected', () {
    test('signInWithPassword still works with the same options', () async {
      final gotrue = _FakeGoTrue(confirmEmail: true);
      final client = SupabaseClient(
        _FakeGoTrue.projectUrl,
        _FakeGoTrue.anonKey,
        authOptions: CloudSyncService.buildAuthOptions(),
        httpClient: gotrue.httpClient,
      );
      addTearDown(client.dispose);

      final response = await client.auth.signInWithPassword(
        email: 'existing.user@example.com',
        password: 'password123',
      );

      expect(gotrue.signupBodies, isEmpty, reason: 'login must not sign up');
      expect(gotrue.tokenBodies, hasLength(1));
      expect(response.session?.user.email, 'existing.user@example.com');
    });
  });
}

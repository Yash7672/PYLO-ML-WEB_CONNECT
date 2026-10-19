import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:task_app/services/cloud/cloud_sync_service.dart';

/// The message the Create Account flow used to show for EVERY unmapped error.
/// It hid the PKCE failure entirely, so a purely local bug was reported as a
/// cloud outage. Nothing may collapse back into it.
const genericCloudError =
    'The cloud server could not complete the request. Please try again.';

void main() {
  group('classifyWithoutProbe surfaces the real Supabase error', () {
    test('duplicate email is reported as an auth error, not a server error',
        () {
      final result = CloudSyncService.classifyWithoutProbe(
        const AuthApiException(
          'User already registered',
          statusCode: '422',
          code: 'user_already_exists',
        ),
      );

      expect(result, isNotNull);
      expect(result!.ok, isFalse);
      expect(result.error, CloudSyncErrorKind.emailTaken);
      expect(result.message, contains('already exists'));
      expect(result.message, isNot(contains(genericCloudError)));
    });

    test('weak password keeps its own message', () {
      final result = CloudSyncService.classifyWithoutProbe(
        AuthWeakPasswordException(
          message: 'Password is too weak',
          statusCode: '422',
          reasons: const ['length'],
        ),
      );

      expect(result!.error, CloudSyncErrorKind.weakPassword);
    });

    test('rejected key is reported as a configuration problem', () {
      final result = CloudSyncService.classifyWithoutProbe(
        const AuthApiException(
          'Invalid API key',
          statusCode: '401',
          code: 'invalid_api_key',
        ),
      );

      expect(result!.error, CloudSyncErrorKind.invalidCredentials);
      expect(result.message, contains('anon'));
    });

    test('a decoded HTTP error keeps its status and code', () {
      final result = CloudSyncService.classifyWithoutProbe(
        const AuthApiException(
          'Something specific went wrong',
          statusCode: '500',
          code: 'unexpected_failure',
        ),
      );

      expect(result!.error, CloudSyncErrorKind.server);
      expect(result.message, contains('HTTP 500'));
      expect(result.message, contains('unexpected_failure'));
      expect(result.message, contains('Something specific went wrong'));
      expect(result.message, isNot(contains(genericCloudError)));
    });

    test('an undecodable response is named instead of being called generic',
        () {
      final result = CloudSyncService.classifyWithoutProbe(
        AuthUnknownException(
          message: 'Received an empty response with status code 502',
          originalError: http.Response('', 502),
        ),
      );

      expect(result!.error, CloudSyncErrorKind.server);
      expect(result.message, contains('unexpected response'));
      expect(result.message, contains('502'));
      expect(result.message, isNot(contains(genericCloudError)));
    });

    test('an AuthException with no status still reports its message', () {
      final result = CloudSyncService.classifyWithoutProbe(
        const AuthException('Code verifier could not be found in local storage.'),
      );

      expect(result!.error, CloudSyncErrorKind.server);
      expect(
        result.message,
        contains('Code verifier could not be found in local storage.'),
      );
      expect(result.message, isNot(contains(genericCloudError)));
    });

    test('a local failure is reported as local, not as a cloud outage', () {
      // The exact shape signUp used to throw once PKCE storage went missing:
      // an assertion, i.e. neither an AuthException nor a transport error.
      final result = CloudSyncService.classifyWithoutProbe(
        AssertionError('You need to provide asyncStorage to perform pkce flow.'),
      );

      expect(result!.error, CloudSyncErrorKind.server);
      expect(result.message, contains('could not complete the cloud request'));
      expect(result.message, contains('pkce flow'));
      expect(result.message, isNot(contains(genericCloudError)));
    });

    test('credentials are redacted out of the surfaced error', () {
      const jwt = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'
          '.eyJyb2xlIjoiYW5vbiIsInJlZiI6ImFiYyJ9'
          '.c2lnbmF0dXJlLXZhbHVl';
      final result = CloudSyncService.classifyWithoutProbe(
        StateError(
          'request failed with apikey=sb_publishable_abcdef123456 '
          'Authorization: Bearer $jwt',
        ),
      );

      expect(result, isNotNull);
      expect(result!.message, isNot(contains('sb_publishable_abcdef123456')));
      expect(result.message, isNot(contains(jwt)));
      expect(result.message, contains('[redacted key]'));
    });

    test('transport failures are left to the reachability probe', () {
      expect(
        CloudSyncService.classifyWithoutProbe(
          const SocketException('Connection refused'),
        ),
        isNull,
      );
      expect(
        CloudSyncService.classifyWithoutProbe(
          AuthRetryableFetchException(message: 'Connection reset by peer'),
        ),
        isNull,
      );
      expect(
        CloudSyncService.classifyWithoutProbe(TimeoutException('too slow')),
        isNull,
      );
    });
  });
}

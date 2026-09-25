import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:task_app/services/cloud/cloud_config_store.dart';

void main() {
  const anonKey = 'sb_publishable_test_123';
  const legacyAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlhdCI6MX0.sig';
  const serviceRoleKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaWF0IjoxfQ.sig';

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('CloudConfig', () {
    test('normalizes a canonical project URL and public key', () {
      const config = CloudConfig(
        url: '  https://project-123.supabase.co///  ',
        anonKey: '  $anonKey  ',
      );

      expect(config.url, 'https://project-123.supabase.co');
      expect(config.anonKey, anonKey);
      expect(config.isConfigured, isTrue);
      expect(config.projectRef, 'project-123');
    });

    test('accepts a legacy anon JWT', () {
      const config = CloudConfig(
        url: 'https://project-123.supabase.co',
        anonKey: legacyAnonKey,
      );

      expect(config.isConfigured, isTrue);
    });

    test('rejects non-canonical project URLs', () {
      const invalidUrls = [
        'http://project-123.supabase.co',
        'https://supabase.co',
        'https://project-123.supabase.co.evil.example',
        'https://user@project-123.supabase.co',
        'https://project-123.supabase.co:443',
        'https://project-123.supabase.co/path',
        'https://project-123.supabase.co?query=1',
      ];

      for (final url in invalidUrls) {
        final config = CloudConfig(url: url, anonKey: anonKey);
        expect(config.isConfigured, isFalse, reason: url);
      }
    });

    test('rejects secret and malformed keys', () {
      final invalidKeys = [
        'sb_secret_test_123',
        serviceRoleKey,
        'not-a-key',
      ];

      for (final key in invalidKeys) {
        final config = CloudConfig(
          url: 'https://project-123.supabase.co',
          anonKey: key,
        );
        expect(config.isConfigured, isFalse, reason: key);
      }
    });

    test('compares normalized configurations', () {
      const first = CloudConfig(
        url: 'https://project-123.supabase.co/',
        anonKey: ' $anonKey ',
      );
      const second = CloudConfig(
        url: ' https://project-123.supabase.co ',
        anonKey: anonKey,
      );

      expect(first.sameAs(second), isTrue);
    });
  });

  group('CloudConfigStore', () {
    test('round-trips and clears a configuration', () async {
      final store = CloudConfigStore();
      const config = CloudConfig(
        url: 'https://project-123.supabase.co',
        anonKey: anonKey,
      );

      await store.save(config);
      final loaded = await store.load();

      expect(loaded, isNotNull);
      expect(loaded!.sameAs(config), isTrue);
      expect(store.current?.sameAs(config), isTrue);

      await store.clear();
      expect(await store.load(), isNull);
    });

    test('does not let a concurrent load overwrite a save', () async {
      final store = CloudConfigStore();
      const config = CloudConfig(
        url: 'https://project-123.supabase.co',
        anonKey: anonKey,
      );

      final save = store.save(config);
      final load = store.load();
      await Future.wait([save, load]);

      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.sameAs(config), isTrue);
    });
  });
}

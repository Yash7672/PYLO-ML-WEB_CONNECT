import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:task_app/database/database_helper.dart';
import 'package:task_app/services/cloud/cloud_config_store.dart';
import 'package:task_app/services/cloud/cloud_sync_service.dart';

void main() {
  const projectUrl = 'https://project-123.supabase.co';
  const publicKey = 'sb_publishable_test_123';

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  CloudSyncService createService(
    MockClient client, {
    CloudConfigStore? store,
  }) {
    return CloudSyncService(
      DatabaseHelper.instance,
      store ?? CloudConfigStore(),
      httpClientFactory: () => client,
    );
  }

  test('uses the auth health endpoint and authorizes the exact config',
      () async {
    final requests = <http.BaseRequest>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/auth/v1/health') {
        return http.Response('{}', 200);
      }
      if (request.url.path == '/rest/v1/daily_data' ||
          request.url.path == '/rest/v1/profiles') {
        return http.Response('[]', 200);
      }
      return http.Response('not found', 404);
    });
    final service = createService(client);
    addTearDown(service.dispose);

    final result = await service.testConnection(
      '  $projectUrl/  ',
      '  $publicKey  ',
    );

    expect(result.ok, isTrue);
    expect(requests, hasLength(3));
    expect(requests.first.url.path, '/auth/v1/health');
    expect(requests[0].headers['apikey'], publicKey);
    expect(requests[0].headers['authorization'], 'Bearer $publicKey');
    expect(requests[1].url.path, '/rest/v1/daily_data');
    expect(requests[1].url.queryParameters['select'],
        'id,user_id,data_date,tasks,lists,sublists,updated_at');
    expect(requests[2].url.path, '/rest/v1/profiles');
    expect(
      requests.every((request) => !request.url.path.contains('/token')),
      isTrue,
    );

    const config = CloudConfig(url: projectUrl, anonKey: publicKey);
    expect(service.isConnectionTestAuthorized(config), isTrue);
    expect(
      service.isConnectionTestAuthorized(
        const CloudConfig(
            url: 'https://other-project.supabase.co', anonKey: publicKey),
      ),
      isFalse,
    );

    service.invalidateConnectionTest();
    expect(service.isConnectionTestAuthorized(config), isFalse);
  });

  test('does not authorize account creation before a successful test',
      () async {
    var requestCount = 0;
    final client = MockClient((_) async {
      requestCount++;
      return http.Response('{}', 200);
    });
    final service = createService(client);
    addTearDown(service.dispose);

    final result = await service.createAuthorizedAccount(
      url: projectUrl,
      anonKey: publicKey,
      email: 'user@example.com',
      password: 'password123',
    );

    expect(result.ok, isFalse);
    expect(result.error, CloudSyncErrorKind.invalidCredentials);
    expect(requestCount, 0);

    final setResult = await service.setConfig(
      const CloudConfig(url: projectUrl, anonKey: publicKey),
    );
    expect(setResult.ok, isFalse);
    expect(await CloudConfigStore().load(), isNull);
  });

  test('rejects a second connection test while one is in flight', () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    final client = MockClient((request) async {
      if (request.url.path == '/auth/v1/health') {
        if (!started.isCompleted) started.complete();
        await gate.future;
        return http.Response('{}', 200);
      }
      return http.Response('[]', 200);
    });
    final service = createService(client);
    addTearDown(service.dispose);

    final first = service.testConnection(projectUrl, publicKey);
    await started.future;
    final second = await service.testConnection(projectUrl, publicKey);

    expect(second.ok, isFalse);
    expect(second.error, CloudSyncErrorKind.unknown);

    gate.complete();
    final firstResult = await first;
    expect(firstResult.ok, isTrue);
  });

  test('does not retain authorization when a test is invalidated in flight',
      () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    final client = MockClient((request) async {
      if (request.url.path == '/auth/v1/health') {
        if (!started.isCompleted) started.complete();
        await gate.future;
        return http.Response('{}', 200);
      }
      return http.Response('[]', 200);
    });
    final service = createService(client);
    addTearDown(service.dispose);

    final resultFuture = service.testConnection(projectUrl, publicKey);
    await started.future;
    service.invalidateConnectionTest();
    gate.complete();
    final result = await resultFuture;

    expect(result.ok, isTrue);
    expect(
      service.isConnectionTestAuthorized(
        const CloudConfig(url: projectUrl, anonKey: publicKey),
      ),
      isFalse,
    );
  });

  test('reports rejected health keys without probing tables', () async {
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      return http.Response('invalid api key', 401);
    });
    final service = createService(client);
    addTearDown(service.dispose);

    final result = await service.testConnection(projectUrl, publicKey);

    expect(result.ok, isFalse);
    expect(result.error, CloudSyncErrorKind.invalidCredentials);
    expect(requests, hasLength(1));
    expect(requests.single.path, '/auth/v1/health');
  });

  test('reports missing tables from the REST check', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/auth/v1/health') {
        return http.Response('{}', 200);
      }
      return http.Response(
        '{"code":"42P01","message":"relation does not exist"}',
        404,
      );
    });
    final service = createService(client);
    addTearDown(service.dispose);

    final result = await service.testConnection(projectUrl, publicKey);

    expect(result.ok, isFalse);
    expect(result.error, CloudSyncErrorKind.server);
    expect(result.message, contains('Tables not found'));
  });
}

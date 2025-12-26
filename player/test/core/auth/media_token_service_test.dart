import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:player/core/auth/media_token_service.dart';
import 'package:player/core/auth/auth_storage.dart';

import 'media_token_service_test.mocks.dart';

@GenerateMocks([GraphQLClient, AuthStorage])
void main() {
  group('MediaTokenService', () {
    late MockGraphQLClient mockClient;
    late MediaTokenService service;
    late MockAuthStorage mockStorage;

    setUp(() {
      mockClient = MockGraphQLClient();
      mockStorage = MockAuthStorage();
      service = MediaTokenService(mockClient, storage: mockStorage);
    });

    group('getToken', () {
      test('returns stored token', () async {
        when(mockStorage.read('media_token'))
            .thenAnswer((_) async => 'test-token');

        final token = await service.getToken();

        expect(token, equals('test-token'));
        verify(mockStorage.read('media_token')).called(1);
      });

      test('returns null when no token stored', () async {
        when(mockStorage.read('media_token'))
            .thenAnswer((_) async => null);

        final token = await service.getToken();

        expect(token, isNull);
      });
    });

    group('setToken', () {
      test('stores token and expiry time', () async {
        final expiresAt = DateTime.now().add(const Duration(hours: 24));
        when(mockStorage.write(any, any)).thenAnswer((_) async {});

        await service.setToken('new-token', expiresAt);

        verify(mockStorage.write('media_token', 'new-token')).called(1);
        verify(mockStorage.write('media_token_expiry', expiresAt.toIso8601String())).called(1);
      });
    });

    group('needsRefresh', () {
      test('returns false when no token exists', () async {
        when(mockStorage.read('media_token'))
            .thenAnswer((_) async => null);

        final result = await service.needsRefresh();

        expect(result, isFalse);
      });

      test('returns true when expiry time is not stored', () async {
        when(mockStorage.read('media_token'))
            .thenAnswer((_) async => 'test-token');
        when(mockStorage.read('media_token_expiry'))
            .thenAnswer((_) async => null);

        final result = await service.needsRefresh();

        expect(result, isTrue);
      });

      test('returns true when token expires within threshold', () async {
        final expiresAt = DateTime.now().add(const Duration(minutes: 30));
        when(mockStorage.read('media_token'))
            .thenAnswer((_) async => 'test-token');
        when(mockStorage.read('media_token_expiry'))
            .thenAnswer((_) async => expiresAt.toIso8601String());

        final result = await service.needsRefresh();

        expect(result, isTrue);
      });

      test('returns false when token is still fresh', () async {
        final expiresAt = DateTime.now().add(const Duration(hours: 12));
        when(mockStorage.read('media_token'))
            .thenAnswer((_) async => 'test-token');
        when(mockStorage.read('media_token_expiry'))
            .thenAnswer((_) async => expiresAt.toIso8601String());

        final result = await service.needsRefresh();

        expect(result, isFalse);
      });
    });

    group('buildMediaUrl', () {
      test('returns URL without token when no token exists', () async {
        when(mockStorage.read('media_token'))
            .thenAnswer((_) async => null);

        final url = await service.buildMediaUrl(
          'https://example.com',
          '/api/v1/stream/file/123',
        );

        expect(url, equals('https://example.com/api/v1/stream/file/123'));
      });

      test('appends token as query parameter', () async {
        when(mockStorage.read('media_token'))
            .thenAnswer((_) async => 'test-token');

        final url = await service.buildMediaUrl(
          'https://example.com',
          '/api/v1/stream/file/123',
        );

        expect(url, equals('https://example.com/api/v1/stream/file/123?media_token=test-token'));
      });

      test('uses ampersand when URL already has query parameters', () async {
        when(mockStorage.read('media_token'))
            .thenAnswer((_) async => 'test-token');

        final url = await service.buildMediaUrl(
          'https://example.com',
          '/api/v1/stream/file/123?strategy=HLS',
        );

        expect(url, equals('https://example.com/api/v1/stream/file/123?strategy=HLS&media_token=test-token'));
      });
    });

    group('isExpired', () {
      test('returns true when expiry time is not stored', () async {
        when(mockStorage.read('media_token_expiry'))
            .thenAnswer((_) async => null);

        final result = await service.isExpired();

        expect(result, isTrue);
      });

      test('returns true when token is expired', () async {
        final expiredTime = DateTime.now().subtract(const Duration(hours: 1));
        when(mockStorage.read('media_token_expiry'))
            .thenAnswer((_) async => expiredTime.toIso8601String());

        final result = await service.isExpired();

        expect(result, isTrue);
      });

      test('returns false when token is not expired', () async {
        final futureTime = DateTime.now().add(const Duration(hours: 12));
        when(mockStorage.read('media_token_expiry'))
            .thenAnswer((_) async => futureTime.toIso8601String());

        final result = await service.isExpired();

        expect(result, isFalse);
      });
    });

    group('ensureValidToken', () {
      test('returns false when no token exists', () async {
        when(mockStorage.read('media_token'))
            .thenAnswer((_) async => null);

        final result = await service.ensureValidToken();

        expect(result, isFalse);
      });
    });
  });
}

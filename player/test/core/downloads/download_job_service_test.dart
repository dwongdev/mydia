import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:player/core/downloads/download_job_service.dart';
import 'package:player/core/auth/media_token_service.dart';
import 'package:player/domain/models/download_option.dart';

import 'download_job_service_test.mocks.dart';

@GenerateMocks([http.Client, MediaTokenService])
void main() {
  group('DownloadJobService', () {
    late MockClient mockHttpClient;
    late MockMediaTokenService mockMediaTokenService;
    late HttpDownloadJobService service;

    const baseUrl = 'https://example.com';
    const authToken = 'test-auth-token';

    setUp(() {
      mockHttpClient = MockClient();
      mockMediaTokenService = MockMediaTokenService();
      service = HttpDownloadJobService(
        baseUrl: baseUrl,
        authToken: authToken,
        mediaTokenService: mockMediaTokenService,
        httpClient: mockHttpClient,
      );
    });

    group('getOptions', () {
      test('returns download options on success', () async {
        final responseBody = jsonEncode({
          'options': [
            {'resolution': '1080p', 'estimated_size': 5242880000},
            {'resolution': '720p', 'estimated_size': 2621440000},
          ],
        });

        when(mockHttpClient.get(
          Uri.parse('$baseUrl/api/v1/download/movie/123/options'),
          headers: anyNamed('headers'),
        )).thenAnswer((_) async => http.Response(responseBody, 200));

        final result = await service.getOptions('movie', '123');

        expect(result.options.length, equals(2));
        expect(result.options[0].resolution, equals('1080p'));
        expect(result.options[0].estimatedSize, equals(5242880000));
        expect(result.options[1].resolution, equals('720p'));
      });

      test('throws exception on 404', () async {
        when(mockHttpClient.get(
          Uri.parse('$baseUrl/api/v1/download/movie/999/options'),
          headers: anyNamed('headers'),
        )).thenAnswer((_) async =>
            http.Response(jsonEncode({'error': 'Media not found'}), 404));

        expect(
          () => service.getOptions('movie', '999'),
          throwsA(isA<DownloadServiceException>()
              .having((e) => e.statusCode, 'statusCode', 404)),
        );
      });
    });

    group('prepareDownload', () {
      test('returns job status on success', () async {
        final responseBody = jsonEncode({
          'job_id': 'job-123',
          'status': 'pending',
          'progress': 0.0,
        });

        when(mockHttpClient.post(
          Uri.parse('$baseUrl/api/v1/download/movie/123/prepare'),
          headers: anyNamed('headers'),
          body: anyNamed('body'),
        )).thenAnswer((_) async => http.Response(responseBody, 200));

        final result = await service.prepareDownload(
          contentType: 'movie',
          id: '123',
          resolution: '720p',
        );

        expect(result.jobId, equals('job-123'));
        expect(result.status, equals(DownloadJobStatusType.pending));
        expect(result.progress, equals(0.0));
      });

      test('throws exception on invalid resolution', () async {
        when(mockHttpClient.post(
          Uri.parse('$baseUrl/api/v1/download/movie/123/prepare'),
          headers: anyNamed('headers'),
          body: anyNamed('body'),
        )).thenAnswer((_) async =>
            http.Response(jsonEncode({'error': 'Invalid resolution'}), 400));

        expect(
          () => service.prepareDownload(
            contentType: 'movie',
            id: '123',
            resolution: 'invalid',
          ),
          throwsA(isA<DownloadServiceException>()
              .having((e) => e.statusCode, 'statusCode', 400)),
        );
      });
    });

    group('getJobStatus', () {
      test('returns job status on success', () async {
        final responseBody = jsonEncode({
          'job_id': 'job-123',
          'status': 'transcoding',
          'progress': 0.5,
        });

        when(mockHttpClient.get(
          Uri.parse('$baseUrl/api/v1/download/job/job-123/status'),
          headers: anyNamed('headers'),
        )).thenAnswer((_) async => http.Response(responseBody, 200));

        final result = await service.getJobStatus('job-123');

        expect(result.jobId, equals('job-123'));
        expect(result.status, equals(DownloadJobStatusType.transcoding));
        expect(result.progress, equals(0.5));
      });

      test('throws exception on job not found', () async {
        when(mockHttpClient.get(
          Uri.parse('$baseUrl/api/v1/download/job/missing/status'),
          headers: anyNamed('headers'),
        )).thenAnswer((_) async =>
            http.Response(jsonEncode({'error': 'Job not found'}), 404));

        expect(
          () => service.getJobStatus('missing'),
          throwsA(isA<DownloadServiceException>()
              .having((e) => e.statusCode, 'statusCode', 404)),
        );
      });
    });

    group('cancelJob', () {
      test('completes successfully', () async {
        when(mockHttpClient.delete(
          Uri.parse('$baseUrl/api/v1/download/job/job-123'),
          headers: anyNamed('headers'),
        )).thenAnswer((_) async =>
            http.Response(jsonEncode({'status': 'cancelled'}), 200));

        await service.cancelJob('job-123');

        verify(mockHttpClient.delete(
          Uri.parse('$baseUrl/api/v1/download/job/job-123'),
          headers: anyNamed('headers'),
        )).called(1);
      });

      test('throws exception on job not found', () async {
        when(mockHttpClient.delete(
          Uri.parse('$baseUrl/api/v1/download/job/missing'),
          headers: anyNamed('headers'),
        )).thenAnswer((_) async =>
            http.Response(jsonEncode({'error': 'Job not found'}), 404));

        expect(
          () => service.cancelJob('missing'),
          throwsA(isA<DownloadServiceException>()
              .having((e) => e.statusCode, 'statusCode', 404)),
        );
      });
    });

    group('getDownloadUrl', () {
      test('returns authenticated URL', () async {
        when(mockMediaTokenService.ensureValidToken())
            .thenAnswer((_) async => true);
        when(mockMediaTokenService.buildMediaUrl(
          baseUrl,
          '/api/v1/download/job/job-123/file',
        )).thenAnswer((_) async =>
            '$baseUrl/api/v1/download/job/job-123/file?token=media-token');

        final url = await service.getDownloadUrl('job-123');

        expect(url, contains('job-123'));
        expect(url, contains('token=media-token'));
        verify(mockMediaTokenService.ensureValidToken()).called(1);
      });
    });
  });

  group('DownloadOption', () {
    test('parses from JSON correctly', () {
      final json = {
        'resolution': '1080p',
        'estimated_size': 5242880000,
      };

      final option = DownloadOption.fromJson(json);

      expect(option.resolution, equals('1080p'));
      expect(option.estimatedSize, equals(5242880000));
    });

    test('formats file size correctly', () {
      const option1 = DownloadOption(resolution: '1080p', estimatedSize: 500);
      expect(option1.formattedSize, equals('500 B'));

      const option2 = DownloadOption(resolution: '720p', estimatedSize: 1536);
      expect(option2.formattedSize, equals('1.5 KB'));

      const option3 =
          DownloadOption(resolution: '480p', estimatedSize: 2097152);
      expect(option3.formattedSize, equals('2.0 MB'));

      const option4 =
          DownloadOption(resolution: '1080p', estimatedSize: 5368709120);
      expect(option4.formattedSize, equals('5.00 GB'));
    });
  });

  group('DownloadJobStatus', () {
    test('parses from JSON correctly', () {
      final json = {
        'job_id': 'job-123',
        'status': 'transcoding',
        'progress': 0.75,
        'error': null,
      };

      final status = DownloadJobStatus.fromJson(json);

      expect(status.jobId, equals('job-123'));
      expect(status.status, equals(DownloadJobStatusType.transcoding));
      expect(status.progress, equals(0.75));
      expect(status.error, isNull);
    });

    test('correctly identifies complete status', () {
      const readyStatus = DownloadJobStatus(
        jobId: 'job-1',
        status: DownloadJobStatusType.ready,
        progress: 1.0,
      );
      expect(readyStatus.isComplete, isTrue);
      expect(readyStatus.isInProgress, isFalse);

      const failedStatus = DownloadJobStatus(
        jobId: 'job-2',
        status: DownloadJobStatusType.failed,
        progress: 0.5,
        error: 'Failed',
      );
      expect(failedStatus.isComplete, isTrue);
      expect(failedStatus.isInProgress, isFalse);
    });

    test('correctly identifies in-progress status', () {
      const pendingStatus = DownloadJobStatus(
        jobId: 'job-1',
        status: DownloadJobStatusType.pending,
        progress: 0.0,
      );
      expect(pendingStatus.isInProgress, isTrue);
      expect(pendingStatus.isComplete, isFalse);

      const transcodingStatus = DownloadJobStatus(
        jobId: 'job-2',
        status: DownloadJobStatusType.transcoding,
        progress: 0.5,
      );
      expect(transcodingStatus.isInProgress, isTrue);
      expect(transcodingStatus.isComplete, isFalse);
    });

    test('formats progress percentage correctly', () {
      const status = DownloadJobStatus(
        jobId: 'job-1',
        status: DownloadJobStatusType.transcoding,
        progress: 0.756,
      );
      expect(status.progressPercentage, equals('76%'));
    });
  });
}

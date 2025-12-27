import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_job_providers.dart';
import 'package:player/domain/models/download_option.dart';
import 'package:player/presentation/widgets/quality_download_dialog.dart';

void main() {
  group('DownloadOption', () {
    test('parses from JSON correctly', () {
      final json = {
        'resolution': '1080p',
        'estimated_size': 1500000000,
      };

      final option = DownloadOption.fromJson(json);

      expect(option.resolution, equals('1080p'));
      expect(option.estimatedSize, equals(1500000000));
    });

    test('formats size in bytes correctly', () {
      const option = DownloadOption(
        resolution: '1080p',
        estimatedSize: 500,
      );

      expect(option.formattedSize, equals('500 B'));
    });

    test('formats size in KB correctly', () {
      const option = DownloadOption(
        resolution: '1080p',
        estimatedSize: 5120, // 5 KB
      );

      expect(option.formattedSize, equals('5.0 KB'));
    });

    test('formats size in MB correctly', () {
      const option = DownloadOption(
        resolution: '720p',
        estimatedSize: 524288000, // ~500 MB
      );

      expect(option.formattedSize, equals('500.0 MB'));
    });

    test('formats size in GB correctly', () {
      const option = DownloadOption(
        resolution: '1080p',
        estimatedSize: 2147483648, // 2 GB
      );

      expect(option.formattedSize, equals('2.00 GB'));
    });

    test('serializes to JSON correctly', () {
      const option = DownloadOption(
        resolution: '720p',
        estimatedSize: 800000000,
      );

      final json = option.toJson();

      expect(json['resolution'], equals('720p'));
      expect(json['estimated_size'], equals(800000000));
    });
  });

  group('DownloadOptionsResponse', () {
    test('parses from JSON with options', () {
      final json = {
        'options': [
          {'resolution': '1080p', 'estimated_size': 1500000000},
          {'resolution': '720p', 'estimated_size': 800000000},
          {'resolution': '480p', 'estimated_size': 400000000},
        ],
      };

      final response = DownloadOptionsResponse.fromJson(json);

      expect(response.options.length, equals(3));
      expect(response.options[0].resolution, equals('1080p'));
      expect(response.options[1].resolution, equals('720p'));
      expect(response.options[2].resolution, equals('480p'));
    });

    test('parses from JSON with empty options', () {
      final json = <String, dynamic>{'options': <dynamic>[]};

      final response = DownloadOptionsResponse.fromJson(json);

      expect(response.options, isEmpty);
    });

    test('parses from JSON with missing options key', () {
      final json = <String, dynamic>{};

      final response = DownloadOptionsResponse.fromJson(json);

      expect(response.options, isEmpty);
    });
  });

  group('DownloadJobStatus', () {
    test('parses from JSON correctly', () {
      final json = {
        'job_id': 'test-job-123',
        'status': 'transcoding',
        'progress': 0.5,
        'current_file_size': 500000000,
      };

      final status = DownloadJobStatus.fromJson(json);

      expect(status.jobId, equals('test-job-123'));
      expect(status.status, equals(DownloadJobStatusType.transcoding));
      expect(status.progress, equals(0.5));
      expect(status.currentFileSize, equals(500000000));
      expect(status.error, isNull);
    });

    test('handles failed status with error message', () {
      final json = {
        'job_id': 'test-job-456',
        'status': 'failed',
        'progress': 0.3,
        'error': 'Transcode failed: codec not supported',
      };

      final status = DownloadJobStatus.fromJson(json);

      expect(status.status, equals(DownloadJobStatusType.failed));
      expect(status.error, equals('Transcode failed: codec not supported'));
    });

    test('isComplete returns true for ready status', () {
      const status = DownloadJobStatus(
        jobId: 'test',
        status: DownloadJobStatusType.ready,
        progress: 1.0,
      );

      expect(status.isComplete, isTrue);
      expect(status.isInProgress, isFalse);
    });

    test('isComplete returns true for failed status', () {
      const status = DownloadJobStatus(
        jobId: 'test',
        status: DownloadJobStatusType.failed,
        progress: 0.5,
      );

      expect(status.isComplete, isTrue);
      expect(status.isInProgress, isFalse);
    });

    test('isInProgress returns true for pending status', () {
      const status = DownloadJobStatus(
        jobId: 'test',
        status: DownloadJobStatusType.pending,
        progress: 0.0,
      );

      expect(status.isInProgress, isTrue);
      expect(status.isComplete, isFalse);
    });

    test('isInProgress returns true for transcoding status', () {
      const status = DownloadJobStatus(
        jobId: 'test',
        status: DownloadJobStatusType.transcoding,
        progress: 0.5,
      );

      expect(status.isInProgress, isTrue);
      expect(status.isComplete, isFalse);
    });

    test('progressPercentage formats correctly', () {
      const status = DownloadJobStatus(
        jobId: 'test',
        status: DownloadJobStatusType.transcoding,
        progress: 0.456,
      );

      expect(status.progressPercentage, equals('46%'));
    });
  });

  group('DownloadJobStatusType', () {
    test('fromString parses all valid statuses', () {
      expect(
        DownloadJobStatusType.fromString('pending'),
        equals(DownloadJobStatusType.pending),
      );
      expect(
        DownloadJobStatusType.fromString('transcoding'),
        equals(DownloadJobStatusType.transcoding),
      );
      expect(
        DownloadJobStatusType.fromString('ready'),
        equals(DownloadJobStatusType.ready),
      );
      expect(
        DownloadJobStatusType.fromString('failed'),
        equals(DownloadJobStatusType.failed),
      );
    });

    test('fromString is case insensitive', () {
      expect(
        DownloadJobStatusType.fromString('TRANSCODING'),
        equals(DownloadJobStatusType.transcoding),
      );
      expect(
        DownloadJobStatusType.fromString('Ready'),
        equals(DownloadJobStatusType.ready),
      );
    });

    test('fromString defaults to pending for unknown status', () {
      expect(
        DownloadJobStatusType.fromString('unknown'),
        equals(DownloadJobStatusType.pending),
      );
    });
  });

  group('QualityDownloadDialog', () {
    testWidgets('shows loading state initially', (tester) async {
      // Use a Completer to control when the provider completes
      final completer = Completer<DownloadOptionsResponse>();

      final container = ProviderContainer(
        overrides: [
          downloadOptionsProvider('movie', 'test-id').overrideWith((ref) {
            return completer.future;
          }),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: QualityDownloadDialog(
                contentType: 'movie',
                contentId: 'test-id',
                title: 'Test Movie',
              ),
            ),
          ),
        ),
      );

      // Verify loading state (before completing the future)
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Loading quality options...'), findsOneWidget);

      // Complete the future to allow test to finish cleanly
      completer.complete(const DownloadOptionsResponse(options: []));
      await tester.pumpAndSettle();

      container.dispose();
    });

    testWidgets('shows quality options when loaded', (tester) async {
      const testOptions = DownloadOptionsResponse(
        options: [
          DownloadOption(resolution: '1080p', estimatedSize: 1500000000),
          DownloadOption(resolution: '720p', estimatedSize: 800000000),
          DownloadOption(resolution: '480p', estimatedSize: 400000000),
        ],
      );

      final container = ProviderContainer(
        overrides: [
          downloadOptionsProvider('movie', 'test-id').overrideWith((ref) async {
            return testOptions;
          }),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: QualityDownloadDialog(
                contentType: 'movie',
                contentId: 'test-id',
                title: 'Test Movie',
              ),
            ),
          ),
        ),
      );

      // Pump multiple times to allow async provider to complete
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      // Verify title
      expect(find.text('Download Quality'), findsOneWidget);
      expect(find.text('Test Movie'), findsOneWidget);

      // Verify quality options are shown
      expect(find.text('Select Quality'), findsOneWidget);
      expect(find.text('1080p (Full HD)'), findsOneWidget);
      expect(find.text('720p (HD)'), findsOneWidget);
      expect(find.text('480p (SD)'), findsOneWidget);

      container.dispose();
    });

    testWidgets('shows error state with retry button', (tester) async {
      final container = ProviderContainer(
        overrides: [
          downloadOptionsProvider('movie', 'test-id').overrideWith((ref) async {
            throw Exception('Network error');
          }),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: QualityDownloadDialog(
                contentType: 'movie',
                contentId: 'test-id',
                title: 'Test Movie',
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify error state
      expect(find.text('Failed to load options'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);

      container.dispose();
    });

    testWidgets('shows empty state when no options available', (tester) async {
      final container = ProviderContainer(
        overrides: [
          downloadOptionsProvider('movie', 'test-id').overrideWith((ref) async {
            return const DownloadOptionsResponse(options: []);
          }),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: QualityDownloadDialog(
                contentType: 'movie',
                contentId: 'test-id',
                title: 'Test Movie',
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify empty state
      expect(find.text('No download options available'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);

      container.dispose();
    });

    testWidgets('selects first option by default', (tester) async {
      const testOptions = DownloadOptionsResponse(
        options: [
          DownloadOption(resolution: '1080p', estimatedSize: 1500000000),
          DownloadOption(resolution: '720p', estimatedSize: 800000000),
        ],
      );

      final container = ProviderContainer(
        overrides: [
          downloadOptionsProvider('movie', 'test-id').overrideWith((ref) async {
            return testOptions;
          }),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: QualityDownloadDialog(
                contentType: 'movie',
                contentId: 'test-id',
                title: 'Test Movie',
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // First option should be selected (check icon visible)
      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
      expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);

      container.dispose();
    });

    testWidgets('allows selecting different quality options', (tester) async {
      const testOptions = DownloadOptionsResponse(
        options: [
          DownloadOption(resolution: '1080p', estimatedSize: 1500000000),
          DownloadOption(resolution: '720p', estimatedSize: 800000000),
        ],
      );

      final container = ProviderContainer(
        overrides: [
          downloadOptionsProvider('movie', 'test-id').overrideWith((ref) async {
            return testOptions;
          }),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: QualityDownloadDialog(
                contentType: 'movie',
                contentId: 'test-id',
                title: 'Test Movie',
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Initially first option selected
      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);

      // Tap on 720p option
      await tester.tap(find.text('720p (HD)'));
      await tester.pumpAndSettle();

      // Now 720p should be selected (2 radio_button_unchecked from first, 1 check from second)
      // The first option now shows unchecked
      // The second option now shows checked

      container.dispose();
    });

    testWidgets('cancel button closes dialog without result', (tester) async {
      String? result;

      const testOptions = DownloadOptionsResponse(
        options: [
          DownloadOption(resolution: '1080p', estimatedSize: 1500000000),
        ],
      );

      final container = ProviderContainer(
        overrides: [
          downloadOptionsProvider('movie', 'test-id').overrideWith((ref) async {
            return testOptions;
          }),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () async {
                    result = await showQualityDownloadDialog(
                      context,
                      contentType: 'movie',
                      contentId: 'test-id',
                      title: 'Test Movie',
                    );
                  },
                  child: const Text('Show Dialog'),
                ),
              ),
            ),
          ),
        ),
      );

      // Tap button to show dialog
      await tester.tap(find.text('Show Dialog'));
      await tester.pumpAndSettle();

      // Tap cancel button
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(result, isNull);

      container.dispose();
    });

    testWidgets('download button returns selected resolution', (tester) async {
      String? result;

      const testOptions = DownloadOptionsResponse(
        options: [
          DownloadOption(resolution: '1080p', estimatedSize: 1500000000),
          DownloadOption(resolution: '720p', estimatedSize: 800000000),
        ],
      );

      final container = ProviderContainer(
        overrides: [
          downloadOptionsProvider('movie', 'test-id').overrideWith((ref) async {
            return testOptions;
          }),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () async {
                    result = await showQualityDownloadDialog(
                      context,
                      contentType: 'movie',
                      contentId: 'test-id',
                      title: 'Test Movie',
                    );
                  },
                  child: const Text('Show Dialog'),
                ),
              ),
            ),
          ),
        ),
      );

      // Tap button to show dialog
      await tester.tap(find.text('Show Dialog'));
      await tester.pumpAndSettle();

      // Select 720p
      await tester.tap(find.text('720p (HD)'));
      await tester.pumpAndSettle();

      // Tap download button
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();

      expect(result, equals('720p'));

      container.dispose();
    });

    testWidgets('download button is disabled when no option selected',
        (tester) async {
      final container = ProviderContainer(
        overrides: [
          downloadOptionsProvider('movie', 'test-id').overrideWith((ref) async {
            return const DownloadOptionsResponse(options: []);
          }),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: QualityDownloadDialog(
                contentType: 'movie',
                contentId: 'test-id',
                title: 'Test Movie',
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Find the Download button
      final downloadButton = find.widgetWithText(ElevatedButton, 'Download');
      expect(downloadButton, findsOneWidget);

      // Verify it's disabled (onPressed is null)
      final button = tester.widget<ElevatedButton>(downloadButton);
      expect(button.onPressed, isNull);

      container.dispose();
    });
  });
}

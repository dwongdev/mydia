import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_job_service.dart';
import 'package:player/core/downloads/p2p_download_job_service.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/domain/models/download_option.dart';

class GraphqlCall {
  final String peer;
  final String query;
  final Map<String, dynamic>? variables;
  final String? operationName;
  final String? authToken;

  const GraphqlCall({
    required this.peer,
    required this.query,
    required this.variables,
    required this.operationName,
    required this.authToken,
  });
}

class BlobRequestCall {
  final String peer;
  final String jobId;
  final String? authToken;

  const BlobRequestCall({
    required this.peer,
    required this.jobId,
    required this.authToken,
  });
}

class BlobDownloadCall {
  final String peer;
  final String ticket;
  final String outputPath;
  final String? authToken;

  const BlobDownloadCall({
    required this.peer,
    required this.ticket,
    required this.outputPath,
    required this.authToken,
  });
}

class FakeP2pService extends P2pService {
  GraphqlCall? lastGraphqlCall;
  BlobRequestCall? lastBlobRequestCall;
  BlobDownloadCall? lastBlobDownloadCall;

  Future<Map<String, dynamic>> Function(GraphqlCall call)? onGraphql;
  Future<Map<String, dynamic>> Function(BlobRequestCall call)? onRequestBlob;
  Future<void> Function(
    BlobDownloadCall call,
    void Function(int downloaded, int total)? onProgress,
  )? onDownloadBlob;

  @override
  Future<Map<String, dynamic>> sendGraphQLRequest({
    required String peer,
    required String query,
    Map<String, dynamic>? variables,
    String? operationName,
    String? authToken,
  }) async {
    final call = GraphqlCall(
      peer: peer,
      query: query,
      variables: variables,
      operationName: operationName,
      authToken: authToken,
    );

    lastGraphqlCall = call;

    final handler = onGraphql;
    if (handler == null) {
      throw Exception('GraphQL handler not configured');
    }

    return handler(call);
  }

  @override
  Future<Map<String, dynamic>> requestBlobDownload({
    required String peer,
    required String jobId,
    String? authToken,
  }) async {
    final call = BlobRequestCall(
      peer: peer,
      jobId: jobId,
      authToken: authToken,
    );

    lastBlobRequestCall = call;

    final handler = onRequestBlob;
    if (handler == null) {
      throw Exception('Blob request handler not configured');
    }

    return handler(call);
  }

  @override
  Future<void> downloadBlob({
    required String peer,
    required String ticket,
    required String outputPath,
    String? authToken,
    void Function(int downloaded, int total)? onProgress,
  }) async {
    final call = BlobDownloadCall(
      peer: peer,
      ticket: ticket,
      outputPath: outputPath,
      authToken: authToken,
    );

    lastBlobDownloadCall = call;

    final handler = onDownloadBlob;
    if (handler == null) {
      throw Exception('Blob download handler not configured');
    }

    await handler(call, onProgress);
  }
}

void main() {
  group('P2pDownloadJobService', () {
    late FakeP2pService p2p;
    late P2pDownloadJobService service;

    const serverNodeAddr = 'server-node-addr';
    const authToken = 'auth-token';

    setUp(() {
      p2p = FakeP2pService();
      service = P2pDownloadJobService(
        p2pService: p2p,
        serverNodeAddr: serverNodeAddr,
        authToken: authToken,
      );
    });

    test('getOptions returns options and sends expected GraphQL request', () async {
      p2p.onGraphql = (_) async => {
            'downloadOptions': [
              {
                'resolution': '1080p',
                'label': 'Full HD',
                'estimatedSize': 5 * 1024 * 1024,
              },
              {
                'resolution': '720p',
                'label': 'HD',
                'estimatedSize': 2 * 1024 * 1024,
              },
            ],
          };

      final result = await service.getOptions('movie', 'movie-1');

      expect(result, isA<DownloadOptionsResponse>());
      expect(result.options, hasLength(2));
      expect(result.options.first.resolution, equals('1080p'));
      expect(result.options.first.label, equals('Full HD'));

      final call = p2p.lastGraphqlCall;
      expect(call, isNotNull);
      expect(call!.peer, equals(serverNodeAddr));
      expect(call.operationName, equals('DownloadOptions'));
      expect(call.authToken, equals(authToken));
      expect(call.variables, equals({'contentType': 'movie', 'id': 'movie-1'}));
      expect(call.query, contains('downloadOptions'));
    });

    test('getOptions throws DownloadServiceException when response is missing options',
        () async {
      p2p.onGraphql = (_) async => {'downloadOptions': null};

      expect(
        () => service.getOptions('movie', 'movie-1'),
        throwsA(isA<DownloadServiceException>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.message, 'message', 'No options returned')),
      );
    });

    test('prepareDownload parses status and file size', () async {
      p2p.onGraphql = (_) async => {
            'prepareDownload': {
              'jobId': 'job-1',
              'status': 'transcoding',
              'progress': 0.25,
              'error': null,
              'fileSize': 12345,
            },
          };

      final result = await service.prepareDownload(
        contentType: 'movie',
        id: 'movie-1',
        resolution: '720p',
      );

      expect(result.jobId, equals('job-1'));
      expect(result.status, equals(DownloadJobStatusType.transcoding));
      expect(result.progress, equals(0.25));
      expect(result.currentFileSize, equals(12345));

      final call = p2p.lastGraphqlCall;
      expect(call, isNotNull);
      expect(call!.operationName, equals('PrepareDownload'));
      expect(
        call.variables,
        equals({'contentType': 'movie', 'id': 'movie-1', 'resolution': '720p'}),
      );
    });

    test('prepareDownload throws when response is missing prepareDownload', () async {
      p2p.onGraphql = (_) async => {'prepareDownload': null};

      expect(
        () => service.prepareDownload(
          contentType: 'movie',
          id: 'movie-1',
          resolution: '720p',
        ),
        throwsA(isA<DownloadServiceException>()
            .having((e) => e.statusCode, 'statusCode', 500)
            .having((e) => e.message, 'message', 'Failed to prepare download')),
      );
    });

    test('getJobStatus returns job details', () async {
      p2p.onGraphql = (_) async => {
            'downloadJobStatus': {
              'jobId': 'job-123',
              'status': 'ready',
              'progress': 1.0,
              'error': null,
              'fileSize': 777,
            },
          };

      final result = await service.getJobStatus('job-123');

      expect(result.jobId, equals('job-123'));
      expect(result.status, equals(DownloadJobStatusType.ready));
      expect(result.progress, equals(1.0));
      expect(result.currentFileSize, equals(777));

      final call = p2p.lastGraphqlCall;
      expect(call, isNotNull);
      expect(call!.operationName, equals('DownloadJobStatus'));
      expect(call.variables, equals({'jobId': 'job-123'}));
    });

    test('getJobStatus throws 404 when job data is missing', () async {
      p2p.onGraphql = (_) async => {'downloadJobStatus': null};

      expect(
        () => service.getJobStatus('missing-job'),
        throwsA(isA<DownloadServiceException>()
            .having((e) => e.statusCode, 'statusCode', 404)
            .having((e) => e.message, 'message', 'Job not found')),
      );
    });

    test('cancelJob succeeds when success is true', () async {
      p2p.onGraphql = (_) async => {
            'cancelDownloadJob': {'success': true},
          };

      await service.cancelJob('job-9');

      final call = p2p.lastGraphqlCall;
      expect(call, isNotNull);
      expect(call!.operationName, equals('CancelDownloadJob'));
      expect(call.variables, equals({'jobId': 'job-9'}));
    });

    test('cancelJob throws when success is false', () async {
      p2p.onGraphql = (_) async => {
            'cancelDownloadJob': {'success': false},
          };

      expect(
        () => service.cancelJob('job-9'),
        throwsA(isA<DownloadServiceException>()
            .having((e) => e.statusCode, 'statusCode', 500)
            .having((e) => e.message, 'message', 'Failed to cancel job')),
      );
    });

    test('requestBlobTicket returns ticket metadata', () async {
      p2p.onRequestBlob = (_) async => {
            'success': true,
            'ticket': '{"hash":"abc"}',
            'filename': 'movie.mp4',
            'fileSize': 999,
          };

      final result = await service.requestBlobTicket('job-blob-1');

      expect(result['success'], isTrue);
      expect(result['ticket'], equals('{"hash":"abc"}'));
      expect(result['filename'], equals('movie.mp4'));
      expect(result['fileSize'], equals(999));

      final call = p2p.lastBlobRequestCall;
      expect(call, isNotNull);
      expect(call!.peer, equals(serverNodeAddr));
      expect(call.jobId, equals('job-blob-1'));
      expect(call.authToken, equals(authToken));
    });

    test('requestBlobTicket throws on failed ticket response', () async {
      p2p.onRequestBlob = (_) async => {
            'success': false,
            'error': 'ticket generation failed',
          };

      expect(
        () => service.requestBlobTicket('job-blob-1'),
        throwsA(isA<DownloadServiceException>()
            .having((e) => e.statusCode, 'statusCode', 500)
            .having((e) => e.message, 'message', 'ticket generation failed')),
      );
    });

    test('downloadBlob forwards peer/auth and relays progress callback', () async {
      final progress = <(int, int)>[];

      p2p.onDownloadBlob = (_, onProgress) async {
        onProgress?.call(128, 1024);
        onProgress?.call(1024, 1024);
      };

      await service.downloadBlob(
        ticket: '{"hash":"abc"}',
        outputPath: '/tmp/movie.mp4',
        onProgress: (downloaded, total) => progress.add((downloaded, total)),
      );

      final call = p2p.lastBlobDownloadCall;
      expect(call, isNotNull);
      expect(call!.peer, equals(serverNodeAddr));
      expect(call.ticket, equals('{"hash":"abc"}'));
      expect(call.outputPath, equals('/tmp/movie.mp4'));
      expect(call.authToken, equals(authToken));

      expect(progress, equals([(128, 1024), (1024, 1024)]));
    });

    test('supportsBlobDownload is true', () {
      expect(service.supportsBlobDownload, isTrue);
    });
  });
}

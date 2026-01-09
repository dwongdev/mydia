import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:player/core/connection/connection_result.dart';
import 'package:player/core/connection/relay_first_connection_manager.dart';
import 'package:player/core/channels/channel_service.dart';
import 'package:player/core/relay/relay_tunnel_service.dart';

import 'relay_first_connection_manager_test.mocks.dart';

@GenerateMocks([ChannelService, RelayTunnel, RelayTunnelInfo])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockRelayTunnel mockTunnel;
  late MockRelayTunnelInfo mockTunnelInfo;

  setUp(() {
    mockTunnel = MockRelayTunnel();
    mockTunnelInfo = MockRelayTunnelInfo();

    // Default mock behavior
    when(mockTunnel.info).thenReturn(mockTunnelInfo);
    when(mockTunnelInfo.directUrls).thenReturn([]);
    when(mockTunnel.isActive).thenReturn(true);
  });

  group('RelayFirstConnectionManager', () {
    group('initialization', () {
      test('creates manager with required parameters', () {
        final manager = RelayFirstConnectionManager(
          directUrls: ['https://mydia.local'],
          instanceId: 'test-instance',
          relayUrl: 'https://relay.example.com',
        );

        expect(manager.state, isNull);
        expect(manager.isConnected, isFalse);
        expect(manager.isReconnecting, isFalse);
      });

      test('initializeWithRelayTunnel sets relay-only mode', () {
        final manager = RelayFirstConnectionManager(
          directUrls: ['https://mydia.local'],
          instanceId: 'test-instance',
          relayUrl: 'https://relay.example.com',
        );

        manager.initializeWithRelayTunnel(mockTunnel);

        expect(manager.state, isNotNull);
        expect(manager.mode, equals(ConnectionMode.relayOnly));
        expect(manager.isRelayOnly, isTrue);
        expect(manager.isConnected, isTrue);
      });

      test('initializeWithDirectConnection sets direct-only mode', () {
        final manager = RelayFirstConnectionManager(
          directUrls: ['https://mydia.local'],
          instanceId: 'test-instance',
          relayUrl: 'https://relay.example.com',
        );

        manager.initializeWithDirectConnection('https://mydia.local');

        expect(manager.state, isNotNull);
        expect(manager.mode, equals(ConnectionMode.directOnly));
        expect(manager.isDirectOnly, isTrue);
        expect(manager.isConnected, isTrue);
      });
    });

    group('state stream', () {
      test('emits state changes on initialization', () async {
        final manager = RelayFirstConnectionManager(
          directUrls: ['https://mydia.local'],
          instanceId: 'test-instance',
          relayUrl: 'https://relay.example.com',
        );

        final states = <ConnectionState>[];
        final subscription = manager.stateChanges.listen(states.add);

        manager.initializeWithRelayTunnel(mockTunnel);

        await Future.delayed(Duration.zero);

        expect(states, hasLength(1));
        expect(states.first.mode, equals(ConnectionMode.relayOnly));

        await subscription.cancel();
        manager.dispose();
      });

      test('emits state changes on request count updates', () async {
        final manager = RelayFirstConnectionManager(
          directUrls: [],
          instanceId: 'test-instance',
          relayUrl: 'https://relay.example.com',
        );

        manager.initializeWithRelayTunnel(mockTunnel);

        final states = <ConnectionState>[];
        final subscription = manager.stateChanges.listen(states.add);

        manager.incrementRelayRequests();
        await Future.delayed(Duration.zero);

        manager.decrementRelayRequests();
        await Future.delayed(Duration.zero);

        // Initial state + 2 updates = 3 states
        expect(states.length, greaterThanOrEqualTo(2));
        expect(states[0].pendingRelayRequests, equals(1));
        expect(states[1].pendingRelayRequests, equals(0));

        await subscription.cancel();
        manager.dispose();
      });
    });

    group('request routing', () {
      test('routes requests to relay in relay-only mode', () async {
        final manager = RelayFirstConnectionManager(
          directUrls: [],
          instanceId: 'test-instance',
          relayUrl: 'https://relay.example.com',
        );

        manager.initializeWithRelayTunnel(mockTunnel);

        RelayTunnel? receivedTunnel;
        String? receivedDirectUrl;

        await manager.executeRequest((tunnel, directUrl) async {
          receivedTunnel = tunnel;
          receivedDirectUrl = directUrl;
          return 'result';
        });

        expect(receivedTunnel, equals(mockTunnel));
        expect(receivedDirectUrl, isNull);
      });

      test('routes requests to direct in direct-only mode', () async {
        final manager = RelayFirstConnectionManager(
          directUrls: ['https://mydia.local'],
          instanceId: 'test-instance',
          relayUrl: 'https://relay.example.com',
        );

        manager.initializeWithDirectConnection('https://mydia.local');

        RelayTunnel? receivedTunnel;
        String? receivedDirectUrl;

        await manager.executeRequest((tunnel, directUrl) async {
          receivedTunnel = tunnel;
          receivedDirectUrl = directUrl;
          return 'result';
        });

        expect(receivedTunnel, isNull);
        expect(receivedDirectUrl, equals('https://mydia.local'));
      });

      test('throws when not initialized', () async {
        final manager = RelayFirstConnectionManager(
          directUrls: ['https://mydia.local'],
          instanceId: 'test-instance',
          relayUrl: 'https://relay.example.com',
        );

        expect(
          () => manager.executeRequest((_, __) async => 'result'),
          throwsA(isA<StateError>()),
        );

        manager.dispose();
      });
    });

    group('request counting', () {
      test('tracks pending relay requests', () {
        final manager = RelayFirstConnectionManager(
          directUrls: [],
          instanceId: 'test-instance',
          relayUrl: 'https://relay.example.com',
        );

        manager.initializeWithRelayTunnel(mockTunnel);

        expect(manager.state!.pendingRelayRequests, equals(0));

        manager.incrementRelayRequests();
        expect(manager.state!.pendingRelayRequests, equals(1));

        manager.incrementRelayRequests();
        expect(manager.state!.pendingRelayRequests, equals(2));

        manager.decrementRelayRequests();
        expect(manager.state!.pendingRelayRequests, equals(1));

        manager.dispose();
      });

      test('tracks pending direct requests', () {
        final manager = RelayFirstConnectionManager(
          directUrls: ['https://mydia.local'],
          instanceId: 'test-instance',
          relayUrl: 'https://relay.example.com',
        );

        manager.initializeWithDirectConnection('https://mydia.local');

        expect(manager.state!.pendingDirectRequests, equals(0));

        manager.incrementDirectRequests();
        expect(manager.state!.pendingDirectRequests, equals(1));

        manager.decrementDirectRequests();
        expect(manager.state!.pendingDirectRequests, equals(0));

        manager.dispose();
      });

      test('clamps pending requests to non-negative', () {
        final manager = RelayFirstConnectionManager(
          directUrls: [],
          instanceId: 'test-instance',
          relayUrl: 'https://relay.example.com',
        );

        manager.initializeWithRelayTunnel(mockTunnel);

        manager.decrementRelayRequests(); // Should not go negative

        expect(manager.state!.pendingRelayRequests, equals(0));

        manager.dispose();
      });
    });

    group('helper accessors', () {
      test('returns relay tunnel when in relay mode', () {
        final manager = RelayFirstConnectionManager(
          directUrls: [],
          instanceId: 'test-instance',
          relayUrl: 'https://relay.example.com',
        );

        manager.initializeWithRelayTunnel(mockTunnel);

        expect(manager.relayTunnel, equals(mockTunnel));
        expect(manager.directUrl, isNull);

        manager.dispose();
      });

      test('returns direct URL when in direct mode', () {
        final manager = RelayFirstConnectionManager(
          directUrls: ['https://mydia.local'],
          instanceId: 'test-instance',
          relayUrl: 'https://relay.example.com',
        );

        manager.initializeWithDirectConnection('https://mydia.local');

        expect(manager.relayTunnel, isNull);
        expect(manager.directUrl, equals('https://mydia.local'));

        manager.dispose();
      });
    });

    group('disposal', () {
      test('closes relay tunnel on dispose', () {
        final manager = RelayFirstConnectionManager(
          directUrls: [],
          instanceId: 'test-instance',
          relayUrl: 'https://relay.example.com',
        );

        manager.initializeWithRelayTunnel(mockTunnel);
        manager.dispose();

        verify(mockTunnel.close()).called(1);
      });

      test('disposes without error when not initialized', () {
        final manager = RelayFirstConnectionManager(
          directUrls: [],
          instanceId: 'test-instance',
          relayUrl: 'https://relay.example.com',
        );

        expect(() => manager.dispose(), returnsNormally);
      });
    });
  });

  group('ConnectionState', () {
    test('creates relay-only state', () {
      final state = ConnectionState.relayOnly(tunnel: mockTunnel);

      expect(state.mode, equals(ConnectionMode.relayOnly));
      expect(state.relayTunnel, equals(mockTunnel));
      expect(state.directUrl, isNull);
      expect(state.hasRelay, isTrue);
      expect(state.hasDirect, isFalse);
    });

    test('creates direct-only state', () {
      final state = ConnectionState.directOnly(url: 'https://mydia.local');

      expect(state.mode, equals(ConnectionMode.directOnly));
      expect(state.relayTunnel, isNull);
      expect(state.directUrl, equals('https://mydia.local'));
      expect(state.hasRelay, isFalse);
      expect(state.hasDirect, isTrue);
    });

    test('creates dual state', () {
      final state = ConnectionState.dual(
        tunnel: mockTunnel,
        directUrl: 'https://mydia.local',
        pendingRelayRequests: 5,
      );

      expect(state.mode, equals(ConnectionMode.dual));
      expect(state.relayTunnel, equals(mockTunnel));
      expect(state.directUrl, equals('https://mydia.local'));
      expect(state.hasRelay, isTrue);
      expect(state.hasDirect, isTrue);
      expect(state.isHotSwapping, isTrue);
      expect(state.pendingRelayRequests, equals(5));
    });

    test('canCloseRelay returns true when no pending requests', () {
      final state = ConnectionState.dual(
        tunnel: mockTunnel,
        directUrl: 'https://mydia.local',
        pendingRelayRequests: 0,
      );

      expect(state.canCloseRelay, isTrue);
    });

    test('canCloseRelay returns false when requests pending', () {
      final state = ConnectionState.dual(
        tunnel: mockTunnel,
        directUrl: 'https://mydia.local',
        pendingRelayRequests: 3,
      );

      expect(state.canCloseRelay, isFalse);
    });

    test('nextProbeDelay returns correct exponential backoff', () {
      expect(
        const ConnectionState(mode: ConnectionMode.relayOnly, probeFailureCount: 0).nextProbeDelay,
        equals(const Duration(seconds: 5)),
      );
      expect(
        const ConnectionState(mode: ConnectionMode.relayOnly, probeFailureCount: 1).nextProbeDelay,
        equals(const Duration(seconds: 10)),
      );
      expect(
        const ConnectionState(mode: ConnectionMode.relayOnly, probeFailureCount: 2).nextProbeDelay,
        equals(const Duration(seconds: 30)),
      );
      expect(
        const ConnectionState(mode: ConnectionMode.relayOnly, probeFailureCount: 3).nextProbeDelay,
        equals(const Duration(seconds: 60)),
      );
      expect(
        const ConnectionState(mode: ConnectionMode.relayOnly, probeFailureCount: 4).nextProbeDelay,
        equals(const Duration(minutes: 5)),
      );
      expect(
        const ConnectionState(mode: ConnectionMode.relayOnly, probeFailureCount: 100).nextProbeDelay,
        equals(const Duration(minutes: 5)), // Clamps to max
      );
    });

    test('copyWith creates new state with updated fields', () {
      final original = ConnectionState.relayOnly(tunnel: mockTunnel);
      final copied = original.copyWith(pendingRelayRequests: 5);

      expect(copied.pendingRelayRequests, equals(5));
      expect(copied.mode, equals(ConnectionMode.relayOnly));
      expect(copied.relayTunnel, equals(mockTunnel));
    });
  });

  group('ConnectionMode', () {
    test('has correct values', () {
      expect(ConnectionMode.values, hasLength(3));
      expect(ConnectionMode.values, contains(ConnectionMode.relayOnly));
      expect(ConnectionMode.values, contains(ConnectionMode.directOnly));
      expect(ConnectionMode.values, contains(ConnectionMode.dual));
    });
  });
}

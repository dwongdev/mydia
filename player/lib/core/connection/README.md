# Connection Management

This directory contains the connection management infrastructure for establishing connections to Mydia instances using a direct-first, relay-fallback strategy.

## Components

### `connection_result.dart`

Result types for connection operations:
- `ConnectionResult` - Wraps connection attempt results with type information
- `ConnectionType` - Enum for `direct` or `relay` connections
- `ConnectionPreferences` - Stores last successful connection method for optimization

### `connection_manager.dart`

The main connection orchestration service that implements:
- **Direct-first strategy**: Tries all direct URLs in parallel, returning the first successful connection
- **Parallel attempts**: All URLs are tried simultaneously with individual timeouts (default 5s), improving connection time when some URLs are unreachable
- **Certificate verification**: (TODO) Validates TLS certificates against stored fingerprints
- **Relay fallback**: Falls back to WebSocket tunnel if all direct URLs fail
- **Preference storage**: Remembers last successful connection method for future optimization
- **State observation**: Emits connection state changes via stream

## Usage Example

```dart
import 'package:mydia_player/core/connection/connection_manager.dart';
import 'package:mydia_player/core/connection/connection_result.dart';

// Create connection manager
final connectionManager = ConnectionManager(
  channelService: channelService,
  relayTunnelService: relayTunnelService,
  directTimeout: Duration(seconds: 5),
);

// Listen to connection state changes
connectionManager.stateChanges.listen((state) {
  print('Connection: $state');
});

// Attempt connection
final result = await connectionManager.connect(
  directUrls: ['https://mydia.example.com', 'https://192.168.1.5:4000'],
  instanceId: 'instance-uuid',
  certFingerprint: 'aa:bb:cc:dd:...',
  relayUrl: 'https://relay.example.com',
);

// Handle result
if (result.success) {
  if (result.isDirect) {
    print('Connected via direct URL: ${result.connectedUrl}');
    // The ChannelService is already connected
    // Now join the appropriate channel
    final joinResult = await channelService.joinPairingChannel();
  } else if (result.isRelay) {
    print('Connected via relay tunnel');
    final tunnel = result.tunnel!;
    // Perform handshake over tunnel
  }
} else {
  print('Connection failed: ${result.error}');
}
```

## Integration with PairingService

The `ConnectionManager` is designed to replace the direct URL iteration in `PairingService.pairWithClaimCodeOnly()`.

### Current Flow (PairingService)

```dart
// Step 2: Try each direct URL until one works
for (final url in claimInfo.directUrls) {
  final connectResult = await _channelService.connect(url);
  if (connectResult.success) {
    connectedUrl = url;
    break;
  }
}

if (connectedUrl == null) {
  return PairingResult.error('Could not connect to server...');
}
```

### Proposed Flow (with ConnectionManager)

```dart
// Step 2: Try direct URLs first, fall back to relay
final connectionResult = await _connectionManager.connect(
  directUrls: claimInfo.directUrls,
  instanceId: claimInfo.instanceId,
  certFingerprint: claimInfo.certFingerprint,
  relayUrl: _relayUrl,
);

if (!connectionResult.success) {
  return PairingResult.error(connectionResult.error!);
}

String? connectedUrl;
RelayTunnel? tunnel;

if (connectionResult.isDirect) {
  connectedUrl = connectionResult.connectedUrl;
} else {
  tunnel = connectionResult.tunnel;
}

// Step 3: Join pairing channel (direct) or perform handshake (relay)
if (tunnel != null) {
  // Relay path: Perform Noise handshake over tunnel
  // (This requires extending PairingService to support tunnel-based handshakes)
} else {
  // Direct path: Continue with existing channel-based flow
  final joinResult = await _channelService.joinPairingChannel();
  // ... rest of existing code
}
```

## Future Enhancements

1. **Certificate Pinning**: Implement actual TLS certificate verification in `_tryDirectConnection()`
2. ~~**Parallel Attempts**: Try multiple direct URLs in parallel with timeout race~~ ✅ Implemented
3. **Connection Quality**: Track connection latency and reliability metrics
4. **Smart Ordering**: Use historical success rates to reorder direct URLs
5. **Relay Handshake**: Extend to support performing Noise handshakes over relay tunnels

## Dependencies

- `ChannelService` - For establishing Phoenix WebSocket connections
- `RelayTunnelService` - For establishing relay WebSocket tunnels
- `CertVerifier` - For certificate fingerprint verification (future)
- `AuthStorage` - For persisting connection preferences

# Remote Access

Remote access allows the Mydia mobile app to connect to your Mydia instance from anywhere, even when your server is behind NAT or a firewall.

## How It Works

Mydia uses a **relay-first connection strategy**:

1. **Initial Connection**: The app always connects via the relay service first, ensuring immediate connectivity regardless of network topology.

2. **Background Probing**: Once connected, the app probes direct URLs in the background to test if direct connection is possible.

3. **Hot Swap**: If direct connection becomes available, the app seamlessly switches from relay to direct without interrupting ongoing requests.

4. **Auto-Fallback**: If direct connection drops, the app automatically falls back to relay.

This approach prioritizes:
- **User experience**: Instant connection, no waiting for direct URL timeouts
- **Performance**: Direct connection when possible for lowest latency
- **Reliability**: Automatic fallback ensures connection is maintained

## Connection Flow

```
┌──────────────────────────────────────────────────────────────────────┐
│                        CONNECTION FLOW                                │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  1. App starts pairing/reconnection                                  │
│         │                                                            │
│         v                                                            │
│  2. Connect via RELAY immediately                                    │
│         │                                                            │
│         v                                                            │
│  3. Complete X25519 key exchange through relay                       │
│         │                                                            │
│         v                                                            │
│  4. App is now usable (relay connection)                             │
│         │                                                            │
│         │ ┌─────────────────────────────────────┐                   │
│         └─┤ Background: Probe direct URLs       │                   │
│           │                                      │                   │
│           │  - Try each URL with timeout         │                   │
│           │  - Test TCP + TLS + Channel join     │                   │
│           │  - Exponential backoff on failure    │                   │
│           └─────────────────────────────────────┘                   │
│                       │                                              │
│                       v                                              │
│  5. If probe succeeds: HOT SWAP to direct                           │
│         │                                                            │
│         v                                                            │
│  6. Direct connection active                                         │
│         │                                                            │
│         │ (if direct drops)                                          │
│         v                                                            │
│  7. AUTO-FALLBACK to relay                                          │
│         │                                                            │
│         └──────────────────────► Restart probing                    │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

## Configuration

### Enable Remote Access

1. Navigate to **Settings > Remote Access** in the Mydia web interface
2. Toggle **Enable Remote Access**
3. Your instance will register with the relay service

### Direct URLs

Direct URLs are automatically detected from your instance's network configuration:
- Local IP addresses (e.g., `https://192.168.1.100:4443`)
- Public hostname (if configured)
- Custom domain (if configured)

The app will try these URLs when probing for direct connectivity.

## Security

### Encryption

All communication is encrypted:

- **Relay tunnel**: TLS to relay + end-to-end encryption via X25519/ChaCha20-Poly1305
- **Direct connection**: TLS with optional certificate pinning

The relay service cannot read your data; it only forwards encrypted messages.

### Authentication

- Initial pairing uses claim codes (QR code or 6-digit code)
- Subsequent connections use device tokens with X25519 key exchange
- Each session establishes fresh encryption keys

### Certificate Verification

For direct connections, the app verifies the server's TLS certificate fingerprint against the fingerprint stored during pairing, preventing man-in-the-middle attacks.

## Connection States

The app can be in one of three connection states:

| State | Description | When |
|-------|-------------|------|
| **Relay** | Traffic flows through relay service | Initial connection, fallback |
| **Dual** | Hot swap in progress | Transitioning to direct |
| **Direct** | Traffic flows directly to server | Direct probe succeeded |

You can see the current state in **Settings** on the mobile app.

## Troubleshooting

### App won't connect

1. **Check remote access is enabled** on your Mydia instance
2. **Verify relay service connectivity** - instance should show "Connected" in Settings > Remote Access
3. **Check claim code** - codes expire after 5 minutes

### Slow performance

1. **Check if using relay** - relay adds latency; look for "Relay" indicator in app
2. **Direct URLs blocked** - firewall may be blocking direct connections
3. **Network issues** - try from different network to isolate

### Stuck on relay

The app stays on relay if direct URLs aren't reachable:

1. **Firewall rules** - ensure ports are open for direct URLs
2. **NAT traversal** - port forwarding may be needed
3. **DNS resolution** - hostname must resolve from mobile network

### Media playback issues

If media won't play while on relay:

1. **Media URLs** - media streaming requires direct connection currently
2. **Bandwidth** - relay has limited throughput
3. **Timeout** - large files may timeout on relay

## Architecture Details

### Relay Service

The relay service is part of the metadata-relay infrastructure:
- Location: `metadata-relay/lib/relay/`
- Endpoint: `wss://relay.mydia.dev/socket`

### Instance Registration

When remote access is enabled, your Mydia instance:
1. Connects to relay service via WebSocket
2. Registers with instance ID and public key
3. Maintains connection with heartbeats
4. Receives incoming connection requests

### Client Connection

When the app connects:
1. Connects to relay service
2. Requests connection to specific instance ID
3. Relay forwards request to instance
4. X25519 handshake proceeds over relay
5. Encrypted session established

## API Reference

### Relay WebSocket Protocol

See `lib/mydia/remote_access/relay/README.md` for detailed protocol documentation.

### Connection Manager API

See `player/lib/core/connection/README.md` for Flutter implementation details.

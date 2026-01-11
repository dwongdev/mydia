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

All communication is encrypted end-to-end:

- **WebRTC DataChannels**: Mandatory Noise protocol encryption (E2EE)
- **Relay tunnel**: TLS to relay + end-to-end encryption via X25519/ChaCha20-Poly1305
- **Direct connection**: TLS with optional certificate pinning

The relay service cannot read your data; it only forwards encrypted messages. E2EE is mandatory for all WebRTC connections - plaintext communication is not supported.

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

## WebRTC E2EE Protocol Specification

This section documents the end-to-end encryption protocol for WebRTC DataChannels.

### Overview

When using WebRTC for remote access, application messages sent over DataChannels are **always** encrypted using the Noise Protocol Framework. E2EE is mandatory - connections without encryption will be rejected. This provides:

- **Forward secrecy**: Compromise of long-term keys doesn't reveal past session keys
- **Replay protection**: Message counters prevent replay attacks
- **Authentication**: Server identity verified via static public key
- **Zero-trust**: No plaintext fallback - data is always encrypted end-to-end

### Noise Protocol Selection

| Parameter | Value |
|-----------|-------|
| Protocol | `Noise_IK_25519_ChaChaPoly_SHA256` |
| DH Function | X25519 (Curve25519) |
| Cipher | ChaCha20-Poly1305 (AEAD) |
| Hash | SHA-256 |

**IK Pattern:**
```
<- s
...
-> e, es, s, ss
<- e, ee, se
```

- Client (initiator) knows server static public key upfront via relay `connected` message
- Client generates ephemeral key pair for each handshake
- Server authenticates to client; client optionally authenticates to server

### Handshake Binding

The handshake prologue binds to the session context:

```
prologue = session_id || instance_id || protocol_version
```

Where:
- `session_id`: 36-byte UUID string
- `instance_id`: 36-byte UUID string  
- `protocol_version`: 1-byte version (currently `0x01`)

### Wire Format

#### Handshake Messages

Handshake messages are sent as raw binary over the `mydia-api` DataChannel.

**Message 1 (Client -> Server):**
```
|| ne (32) || encrypted_s (48) || ciphertext (N + 16) ||
```
- `ne`: Client ephemeral public key (32 bytes)
- `encrypted_s`: Client static public key encrypted + MAC (32 + 16 bytes)
- `ciphertext`: Encrypted payload + MAC (variable)

**Message 2 (Server -> Client):**
```
|| ne (32) || ciphertext (N + 16) ||
```
- `ne`: Server ephemeral public key (32 bytes)
- `ciphertext`: Encrypted payload + MAC (variable)

#### Transport Messages (Post-Handshake)

All transport messages use this framing:

```
|| version (1) || channel (1) || flags (1) || counter (8) || ciphertext ||
```

| Field | Size | Description |
|-------|------|-------------|
| `version` | 1 byte | Protocol version (currently `0x01`) |
| `channel` | 1 byte | Channel ID: `0x01` = api, `0x02` = media |
| `flags` | 1 byte | Reserved for future use (currently `0x00`) |
| `counter` | 8 bytes | Big-endian monotonic counter |
| `ciphertext` | variable | AEAD encrypted payload |

**Total header overhead:** 11 bytes + 16 bytes MAC = 27 bytes minimum

#### Handshake Detection

To distinguish handshake messages from encrypted transport:
- **First byte check**: If `version == 0x01` and valid channel/flags, treat as transport
- **Otherwise**: Treat as handshake message (during handshake phase only)

The server tracks handshake state per session and rejects transport messages before handshake completion.

### AEAD Parameters

ChaCha20-Poly1305 AEAD construction:

| Parameter | Value |
|-----------|-------|
| Key size | 32 bytes |
| Nonce size | 12 bytes |
| Tag size | 16 bytes |

**Nonce construction:**
```
nonce = 0x00000000 || counter (8 bytes big-endian)
```

**Associated Data (AD):**
```
ad = version || channel || flags || counter
```

The header bytes are authenticated but not encrypted.

### Key Derivation

After Noise handshake completion, the transport keys are derived using HKDF:

```
# Noise Split produces two CipherStates (c1, c2)
# For initiator (client):
#   tx_key = c2.key (encrypt outgoing)
#   rx_key = c1.key (decrypt incoming)
# For responder (server):
#   tx_key = c1.key (encrypt outgoing)
#   rx_key = c2.key (decrypt incoming)
```

Both `mydia-api` and `mydia-media` channels use the same key pair. Channel separation is achieved via the `channel` byte in the AD.

### Counter Management

**Per-direction counters:**
- Each direction (tx/rx) maintains an independent 64-bit counter
- Counter starts at 0 after handshake completion
- Counter is incremented after each message

**Replay protection:**
- Receiver rejects any message with counter <= last seen counter
- No window mechanism for out-of-order tolerance initially

**Overflow handling:**
- Counter approaching 2^64-1 triggers mandatory rekey
- Maximum messages per key: 2^64 - 1

### Rekeying

**Triggers:**
- Message count threshold: Every 2^32 messages (configurable)
- Time threshold: Every 60 minutes (configurable)
- Manual request: Application-layer rekey message

**Rekey procedure (Noise Rekey):**
```
new_key = ENCRYPT(k, MAX_NONCE, empty, zeros)[0:32]
```

Where:
- `MAX_NONCE` = `0xFFFFFFFFFFFFFFFF`
- Result truncated to 32 bytes

After rekey, counter resets to 0.

### Error Handling

| Error | Action |
|-------|--------|
| No server public key | Reject connection (E2EE required) |
| Invalid server public key | Reject connection (E2EE required) |
| Handshake failure | Close connection immediately |
| MAC verification failure | Drop message, log, do NOT close connection |
| Counter replay detected | Drop message, log, do NOT close connection |
| Counter overflow imminent | Initiate rekey, warn if fails |

### Protocol Negotiation

During relay `connected` message exchange:

```json
{
  "type": "connected",
  "session_id": "...",
  "public_key": "<base64-encoded-server-static-pubkey>",
  "webrtc_e2ee": 1
}
```

The `webrtc_e2ee` field indicates server capability:
- `1`: Noise E2EE required (mandatory)

E2EE is mandatory. Both client and server will reject connections if:
- Server does not provide a public key
- Server public key is invalid (not 32 bytes)
- Noise handshake fails for any reason

There is no plaintext fallback - all WebRTC DataChannel traffic must be encrypted.

### Channel IDs

| ID | Channel | Typical Traffic |
|----|---------|-----------------|
| `0x01` | mydia-api | JSON GraphQL requests/responses |
| `0x02` | mydia-media | Binary media chunks |

### Message Size Limits

| Limit | Value |
|-------|-------|
| Maximum plaintext size | 64 KB |
| Maximum ciphertext size | 64 KB + 27 bytes overhead |
| Recommended chunk size for media | 16 KB |

### Security Considerations

1. **Static key pinning**: Server static public key from relay should be verified against stored value from initial pairing
2. **Clock skew**: Time-based rekey uses local clocks; implementations should be tolerant
3. **Side channels**: Implementation should use constant-time comparison for MACs

## API Reference

### Relay WebSocket Protocol

See `lib/mydia/remote_access/relay/README.md` for detailed protocol documentation.

### Connection Manager API

See `player/lib/core/connection/README.md` for Flutter implementation details.

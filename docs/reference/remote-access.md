# Remote Access

Technical reference for Mydia's remote access system, enabling Flutter clients to securely connect to self-hosted instances from anywhere.

## Overview

The remote access system provides a Plex-like experience for connecting mobile clients to your Mydia instance. It supports two connection modes to accommodate different network environments and user preferences.

```
┌─────────────────────────────────────────────────────────────────┐
│                        Flutter Client                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   ┌─────────────────────┐       ┌─────────────────────────┐     │
│   │    CONTROL PLANE    │       │      DATA PLANE         │     │
│   │   (GraphQL/Noise)   │       │   (Media Streaming)     │     │
│   ├─────────────────────┤       ├─────────────────────────┤     │
│   │ • Browse library    │       │ • HLS video streams     │     │
│   │ • Playback state    │       │ • Direct file downloads │     │
│   │ • Search            │       │ • Thumbnails/posters    │     │
│   │ • Subscriptions     │       │ • Subtitle files        │     │
│   │ • Progress sync     │       │ • Offline downloads     │     │
│   └──────────┬──────────┘       └────────────┬────────────┘     │
│              │                               │                   │
│         Noise/HTTPS                    Media Token              │
│              │                               │                   │
└──────────────┼───────────────────────────────┼───────────────────┘
               │                               │
               ▼                               ▼
    ┌──────────────────┐           ┌──────────────────────┐
    │  Direct or Relay │           │   Direct HTTPS Only  │
    │  (prefer direct) │           │  (no relay fallback) │
    └────────┬─────────┘           └──────────┬───────────┘
             │                                │
             └────────────┬───────────────────┘
                          ▼
             ┌──────────────────────────────────────────┐
             │              Mydia Instance              │
             │  ┌────────────────┐ ┌─────────────────┐  │
             │  │ GraphQL API    │ │ Media Server    │  │
             │  │ (Absinthe)     │ │ (HLS, files)    │  │
             │  └────────────────┘ └─────────────────┘  │
             └──────────────────────────────────────────┘
```

## Protocol Versioning

All messages in the remote access protocol include versioning to ensure forward compatibility and graceful protocol evolution.

### Message Envelope

Every message follows this envelope structure:

```json
{
  "version": 1,
  "type": "request",
  "body_encoding": "json",
  "payload": { ... }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `version` | integer | Yes | Protocol version number (currently `1`) |
| `type` | string | Yes | Message type identifier |
| `body_encoding` | string | Yes | Encoding of the payload: `"json"`, `"raw"`, or `"base64"` |
| `payload` | object | Varies | Message-specific data (structure depends on `type`) |

### Message Types

| Type | Direction | Description |
|------|-----------|-------------|
| `pairing_handshake` | Both | Initial key exchange during pairing |
| `handshake_init` | Client→Server | Reconnection handshake initiation |
| `handshake_complete` | Server→Client | Handshake completion with session token |
| `claim_code` | Client→Server | Claim code redemption request |
| `pairing_complete` | Server→Client | Successful pairing response |
| `request` | Client→Server | Proxied HTTP request through tunnel |
| `response` | Server→Client | Response to a proxied request |
| `ping` | Client→Server | Keep-alive ping |
| `pong` | Server→Client | Keep-alive response |
| `error` | Server→Client | Error response |
| `close` | Both | Connection termination |

### Body Encoding

The `body_encoding` field specifies how the message body/payload is encoded:

| Encoding | Description | Use Case |
|----------|-------------|----------|
| `json` | JSON-encoded object | Most messages (GraphQL, structured data) |
| `raw` | UTF-8 text | Plain text responses |
| `base64` | Base64-encoded binary | Binary data (images, encrypted blobs) |

### Version Negotiation

Version negotiation occurs during the initial handshake:

1. **Client connects** and sends `pairing_handshake` or `handshake_init` with its supported version
2. **Server responds** with its version in the handshake response
3. **Protocol selection**: Both sides use the minimum of their versions

```
Client (v2)                    Server (v1)
    │                              │
    │  pairing_handshake           │
    │  version: 2                  │
    ├─────────────────────────────>│
    │                              │
    │  pairing_handshake           │
    │  version: 1                  │
    │<─────────────────────────────┤
    │                              │
    │  (Both use v1 protocol)      │
```

**Version selection rules:**

- Use `min(client_version, server_version)` for the session
- If `server_version < client_min_supported`, client should disconnect gracefully
- If `client_version < server_min_supported`, server responds with error

### Backward Compatibility Policy

The protocol follows semantic versioning principles for compatibility:

**Minor version changes (1.x → 1.y):**

- New optional fields may be added to message payloads
- New message types may be introduced
- Existing message semantics remain unchanged
- Clients/servers MUST ignore unknown fields
- Clients/servers MUST ignore unknown message types (log and continue)

**Major version changes (1.x → 2.x):**

- Breaking changes to message structure
- Removal of message types
- Changed semantics of existing fields
- Requires explicit version negotiation and fallback

**Compatibility guarantees:**

| Server Version | Client Version | Behavior |
|----------------|----------------|----------|
| 1 | 1 | Full compatibility |
| 1 | 2 | Client uses v1 protocol |
| 2 | 1 | Server uses v1 if supported, else error |
| 2 | 2 | Full compatibility |

**Implementation requirements:**

1. Always include `version` in outgoing messages
2. Always check `version` in incoming messages
3. Log warnings for unknown fields (don't fail)
4. Gracefully handle unknown message types
5. Maintain backward compatibility for at least 2 major versions

### Example Messages

**Pairing handshake (client → server):**

```json
{
  "version": 1,
  "type": "pairing_handshake",
  "body_encoding": "json",
  "payload": {
    "message": "base64-encoded-client-public-key"
  }
}
```

**Claim code (client → server):**

```json
{
  "version": 1,
  "type": "claim_code",
  "body_encoding": "json",
  "payload": {
    "code": "ABC123",
    "device_name": "iPhone 15 Pro",
    "platform": "ios",
    "static_public_key": "base64-encoded-key"
  }
}
```

**Request (client → server):**

```json
{
  "version": 1,
  "type": "request",
  "body_encoding": "json",
  "payload": {
    "id": "req-123",
    "method": "POST",
    "path": "/api/graphql",
    "headers": {
      "content-type": "application/json"
    },
    "body": "{\"query\": \"...\"}"
  }
}
```

**Response (server → client):**

```json
{
  "version": 1,
  "type": "response",
  "body_encoding": "json",
  "payload": {
    "id": "req-123",
    "status": 200,
    "headers": {
      "content-type": "application/json"
    },
    "body": "{\"data\": {...}}",
    "body_encoding": "raw"
  }
}
```

**Binary response (server → client):**

```json
{
  "version": 1,
  "type": "response",
  "body_encoding": "json",
  "payload": {
    "id": "req-456",
    "status": 200,
    "headers": {
      "content-type": "image/jpeg"
    },
    "body": "base64-encoded-image-data",
    "body_encoding": "base64"
  }
}
```

## Connection Modes

### Mode Selection

| Mode | When to Use | Complexity | Security |
|------|-------------|------------|----------|
| **Claim Code** (default) | Remote access, no direct route, first-time setup | Higher | E2E encrypted |
| **Direct** | LAN, VPN, Tailscale, port-forwarded | Lower | TLS + session |

### Claim Code Mode (Default)

Best for:

- Users who don't know their server's URL/IP
- Remote access without VPN
- Maximum security (E2E encryption)
- Multi-device households (easy pairing)

Flow:

1. Admin requests claim code in Mydia web UI
2. Relay generates and returns code to Mydia
3. Mydia displays code to admin
4. User enters code in Flutter app
5. Relay brokers the connection
6. Noise protocol establishes E2E encrypted channel
7. Device is registered and receives tokens

### Direct Mode

Best for:

- Technical users who know their server URL
- LAN-only deployments
- VPN/Tailscale users with direct access
- Environments where relay is unavailable

Flow:

1. User taps "Direct Connection" in app
2. Enters server URL (e.g., `https://192-168-1-100.sslip.io:4000`)
3. Enters username/password
4. App authenticates via GraphQL mutation
5. Receives session token for ongoing requests

## Direct URLs (Auto-Discovery)

Mydia instances automatically detect their network interfaces and build direct URLs using **sslip.io** - a public wildcard DNS service.

### How sslip.io Works

Any IP embedded in a subdomain resolves to that IP:

```
192-168-1-7.sslip.io  →  192.168.1.7
10-0-0-50.sslip.io    →  10.0.0.50
```

### URL Format

```
https://{ip-with-dashes}.sslip.io:{port}
```

Examples:

- LAN: `https://192-168-1-100.sslip.io:4000`
- VPN: `https://10-8-0-5.sslip.io:4000`
- Public: `https://203-0-113-50.sslip.io:4000`

### Relay-Enriched URLs

The relay enriches URLs at claim lookup time by detecting the public IP from the WebSocket connection:

```
┌──────────────────────────────────────────────────────────────────┐
│                    URL Discovery Flow                             │
├──────────────────────────────────────────────────────────────────┤
│                                                                   │
│  1. MYDIA REGISTRATION (WebSocket connect)                       │
│     ├─→ Mydia auto-detects local IPs: [192.168.1.100, 10.0.0.5]  │
│     ├─→ Sends registration: {instance_id, public_key, direct_urls}│
│     └─→ Relay stores direct_urls AND detected public IP          │
│                                                                   │
│  2. CLAIM LOOKUP (Player requests claim code info)               │
│     ├─→ Player: POST /relay/claim/:code                          │
│     └─→ Relay returns enriched URL list with public IP added     │
│                                                                   │
│  3. PLAYER CONNECTION                                            │
│     ├─→ Tries URLs in order (local first = faster on LAN)        │
│     └─→ Falls back to public URL when remote                     │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘
```

## Claim Code Generation

!!! info "Relay Generates Codes"
    The relay service generates claim codes, not the Mydia instance. This ensures consistent code format and uniqueness across all instances.

```
┌──────────┐     ┌──────────┐     ┌──────────┐
│  Admin   │     │  Mydia   │     │  Relay   │
│ Browser  │     │ Instance │     │ Service  │
└────┬─────┘     └────┬─────┘     └────┬─────┘
     │                │                │
     │ Generate Code  │                │
     │───────────────>│                │
     │                │ Request claim  │
     │                │ (user_id, ttl) │
     │                │───────────────>│
     │                │                │ Generate code
     │                │                │ Store claim
     │                │<───────────────│
     │                │ {code, expires}│
     │                │ Store locally  │
     │<───────────────│                │
     │ Display "ABC123"│               │
```

## Noise Protocol (E2E Encryption)

Claim code mode uses the [Noise Protocol Framework](https://noiseprotocol.org/) for end-to-end encryption, the same protocol used by Signal, WireGuard, and WhatsApp.

### Cipher Suite

```
Noise_IK_25519_ChaChaPoly_BLAKE2b
```

- **X25519** - Key exchange
- **ChaCha20-Poly1305** - Symmetric encryption
- **BLAKE2b** - Hashing

### Handshake Patterns

#### Pairing: Noise_NK

Used when client knows the server's public key from claim code exchange:

```
Noise_NK(s, rs):
  <- s                 # Instance static key (from claim code lookup)
  ...
  -> e, es             # Client sends ephemeral, computes DH(e, s)
  <- e, ee             # Instance sends ephemeral, computes DH(e, e)

  # Channel now encrypted with forward secrecy
```

#### Reconnection: Noise_IK

Used when both sides know each other's static keys (after pairing):

```
Noise_IK(s, rs):
  <- s                 # Instance static key (cached from pairing)
  ...
  -> e, es, s, ss      # Client ephemeral + static, proves identity
  <- e, ee, se         # Instance ephemeral, mutual auth complete
```

## Certificate Strategy

For HTTPS with sslip.io domains, Mydia uses self-signed certificates with fingerprint pinning:

```
┌──────────────────────────────────────────────────────────────────┐
│                    Certificate Trust Flow                         │
├──────────────────────────────────────────────────────────────────┤
│                                                                   │
│  1. PAIRING (Claim Code Mode)                                    │
│     ├─→ Client connects via relay (trusted TLS)                  │
│     ├─→ Noise handshake establishes E2E encrypted channel        │
│     ├─→ Instance sends: {direct_urls[], cert_fingerprint}        │
│     └─→ Client stores cert fingerprint for future direct connects│
│                                                                   │
│  2. DIRECT CONNECTION                                            │
│     ├─→ Client connects to direct_url (self-signed cert)         │
│     ├─→ Client verifies cert fingerprint matches stored value    │
│     └─→ Connection trusted (certificate pinning)                 │
│                                                                   │
│  3. DIRECT MODE (no claim code)                                  │
│     ├─→ User manually enters URL                                 │
│     ├─→ Client shows cert fingerprint, user confirms             │
│     └─→ TOFU: Trust On First Use (like SSH)                      │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘
```

## Connection Strategy

### Post-Pairing Behavior

After initial pairing via relay, the client immediately attempts direct connection:

```
1. PAIRING (via relay - one time, required)
   └─→ Receive: device_token, media_token, direct_urls[], cert_fingerprint

2. INITIAL CONNECTION AFTER PAIRING
   ├─→ Try direct_urls[0] → verify cert fingerprint → Noise_IK
   ├─→ If success: close relay tunnel, use direct connection
   └─→ If all fail: continue using relay tunnel as fallback

3. RECONNECTION (app restart)
   ├─→ Try last successful connection method first
   ├─→ Try direct URLs in order
   └─→ Fallback: relay tunnel
```

### When Direct Unavailable

| Situation | Claim Code Mode | Direct Mode |
|-----------|-----------------|-------------|
| At home (LAN) | Direct | Direct |
| Away + VPN/Tailscale | Direct | Direct |
| Away + port forwarding | Direct | Direct |
| Away, no remote setup | **Relay fallback** | **Cannot connect** |

## Relay Service

The relay handles the control plane for claim code mode:

### API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/relay/instances` | POST | Register new instance |
| `/relay/instances/:id/heartbeat` | PUT | Update presence/URLs |
| `/relay/instances/:id/claim` | POST | Request claim code |
| `/relay/claim/:code` | POST | Redeem claim code |
| `/relay/tunnel` | WS | WebSocket tunnel |

### Instance Registration

```elixir
# Instance registers with relay on startup
%{
  instance_id: "uuid",
  public_key: <<binary>>,
  direct_urls: [
    "https://192-168-1-100.sslip.io:4000",
    "https://10-8-0-5.sslip.io:4000"
  ]
}
```

The relay also stores the detected public IP from the WebSocket connection.

## GraphQL API

All client operations use the GraphQL endpoint at `/api/graphql`:

### Authentication (Direct Mode)

```graphql
mutation Login($input: LoginInput!) {
  login(input: $input) {
    token
    user {
      id
      name
      email
    }
    expiresIn
  }
}

input LoginInput {
  email: String!
  password: String!
  deviceId: String!
  deviceName: String!
  platform: String!  # "ios", "android", "web"
}
```

### Device Management

```graphql
# List user's devices
query Devices {
  devices {
    id
    deviceName
    platform
    lastSeenAt
    connectionMode
  }
}

# Revoke a device
mutation RevokeDevice($id: ID!) {
  revokeDevice(id: $id) {
    success
  }
}
```

## Security Properties

| Property | Claim Code Mode | Direct Mode |
|----------|-----------------|-------------|
| Transport encryption | TLS + Noise | TLS only |
| E2E encryption | Yes | No |
| Forward secrecy | Noise ephemeral keys | TLS 1.3 |
| Relay visibility | Nothing (ciphertext) | N/A |
| Auth method | Noise + device token | Session token |
| Device revocation | Token + key invalid | Session invalid |
| Cert validation | Fingerprint pinning | Fingerprint pinning (TOFU) |

## Database Schemas

### Mydia Instance

```elixir
# remote_access_config - Instance identity
schema "remote_access_config" do
  field :instance_id, :string
  field :static_public_key, :binary
  field :static_private_key_encrypted, :binary
  field :relay_url, :string
  field :enabled, :boolean
  field :direct_urls, {:array, :string}
  field :cert_fingerprint, :string
end

# devices - Connected devices
schema "devices" do
  field :device_id, :string
  field :device_name, :string
  field :platform, :string                  # "ios", "android", "web"
  field :connection_mode, :string           # "claim_code" or "direct"
  field :device_static_public_key, :binary  # Claim code mode only
  field :token_hash, :string
  field :last_seen_at, :utc_datetime
  field :last_ip, :string
  field :revoked_at, :utc_datetime
  belongs_to :user, Mydia.Accounts.User
end
```

### Relay Service

```elixir
# Instance registration
schema "instances" do
  field :instance_id, :string
  field :public_key, :binary
  field :direct_urls, {:array, :string}
  field :public_ip, :string              # Detected from WebSocket
  field :online, :boolean
  field :last_seen_at, :utc_datetime
end
```

## BEAM Patterns

The remote access system leverages Elixir/OTP patterns for reliability.

### ETS for Connection State

O(1) lookups for active connections and token validation:

```elixir
# Connection registry
:ets.new(:relay_connections, [:named_table, :public, read_concurrency: true])

# Token cache
:ets.new(:media_token_cache, [:named_table, :public, read_concurrency: true])
```

### Process Monitoring

Graceful handling of tunnel disconnections:

```elixir
def terminate(_reason, socket) do
  instance_id = socket.assigns.instance_id

  # Unregister from ETS
  ConnectionRegistry.unregister(instance_id)

  # Fail all pending requests with 502
  PendingRequests.fail_all(instance_id, {:error, :tunnel_disconnected})

  # Broadcast disconnect event
  Phoenix.PubSub.broadcast(
    Mydia.PubSub,
    "instance:#{instance_id}",
    {:tunnel_disconnected, instance_id}
  )
end
```

### Heartbeat Interval

30-second heartbeats prevent NAT/firewall timeouts:

```elixir
@heartbeat_interval :timer.seconds(30)
@heartbeat_timeout :timer.seconds(10)

def handle_info(:send_heartbeat, state) do
  send_heartbeat(state.socket)
  ref = Process.send_after(self(), :heartbeat_timeout, @heartbeat_timeout)
  {:noreply, %{state | heartbeat_ref: ref, pending_heartbeat: true}}
end
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `REMOTE_ACCESS_ENABLED` | Enable remote access | `false` |
| `RELAY_URL` | Metadata relay URL | - |
| `EXTERNAL_PORT` | Override auto-detected port | `4000` |
| `EXTERNAL_URL` | Manual external URL | - |
| `ADDITIONAL_DIRECT_URLS` | Extra URLs (comma-separated) | - |

### Runtime Configuration

```elixir
# config/runtime.exs
config :mydia,
  # Override auto-detected port if behind reverse proxy
  external_port: System.get_env("EXTERNAL_PORT") || 4000,

  # Manually specify external URL
  external_url: System.get_env("EXTERNAL_URL"),

  # Additional URLs (Tailscale, custom domains)
  additional_direct_urls: [
    System.get_env("TAILSCALE_URL"),
    System.get_env("CUSTOM_DOMAIN_URL")
  ] |> Enum.reject(&is_nil/1)
```

## Libraries

| Platform | Library | Purpose |
|----------|---------|---------|
| Elixir | `decibel` | Noise Protocol |
| Elixir | `absinthe` | GraphQL server |
| Flutter | `noise_protocol_framework` | Noise Protocol |
| Flutter | `graphql_flutter` | GraphQL client |
| Flutter | `phoenix_socket` | Phoenix WebSocket |
| Flutter | `flutter_secure_storage` | Key/token storage |

## References

- [sslip.io](https://sslip.io/) - Wildcard DNS for any IP
- [Noise Protocol Specification](https://noiseprotocol.org/noise.html)
- [Noise Explorer](https://noiseexplorer.com/) - Interactive pattern explorer
- [Absinthe GraphQL](https://hexdocs.pm/absinthe) - Elixir GraphQL

# Relay Service Integration

The Relay Service provides NAT traversal capabilities for Mydia instances that cannot be accessed directly from the internet.

## Architecture

```
Client (Flutter App)
    |
    v
Relay Service (metadata-relay)
    |
    v
Mydia Instance (behind NAT)
```

## How It Works

1. **Registration**: When remote access is enabled, the Mydia instance connects to the relay service via WebSocket and registers itself with its instance ID and public key.

2. **Heartbeat**: The instance maintains the connection with periodic heartbeat messages (every 30 seconds).

3. **Connection Requests**: When a client wants to connect:
   - Client connects to relay service
   - Client requests connection to specific instance_id
   - Relay forwards the request to the Mydia instance
   - Noise protocol handshake proceeds over the relayed WebSocket connection

4. **Auto-Reconnect**: If the connection to the relay is lost, the instance automatically reconnects with exponential backoff (1s → 2s → 4s → ... → 60s max).

## Protocol

The relay service uses JSON messages over WebSocket:

### Registration (Instance → Relay)
```json
{
  "type": "register",
  "instance_id": "uuid-v4",
  "public_key": "base64-encoded-32-bytes"
}
```

### Registration Confirmation (Relay → Instance)
```json
{
  "type": "registered"
}
```

### Heartbeat (Instance ↔ Relay)
```json
{
  "type": "ping"
}
```
```json
{
  "type": "pong"
}
```

### Incoming Connection (Relay → Instance)
```json
{
  "type": "connection",
  "session_id": "uuid-v4",
  "client_public_key": "base64-encoded-32-bytes"
}
```

### Error Messages (Relay → Instance)
```json
{
  "type": "error",
  "message": "error description"
}
```

## Configuration

The relay service URL is stored in the `remote_access_config` table:

```elixir
# Default relay URL (set during initialization)
relay_url: "https://relay.mydia.app"
```

The URL is automatically converted to WebSocket format (https:// → wss://).

## Lifecycle Management

The relay GenServer is managed by the application supervision tree:

- **Started**: When `remote_access_config.enabled = true` at application startup
- **Not Started**: When remote access is disabled or not configured
- **Auto-Restart**: Supervisor restarts the process if it crashes
- **Auto-Reconnect**: Process handles WebSocket disconnections with exponential backoff

## Status Checking

```elixir
# Check if relay is connected and registered
RemoteAccess.relay_available?()
# => true | false

# Get detailed status
RemoteAccess.relay_status()
# => {:ok, %{connected: true, registered: true, instance_id: "..."}}
# => {:error, :not_running}
```

## Testing

The relay service is **not started** in test environment to avoid:
- Attempting real WebSocket connections during tests
- Interfering with test database transactions
- Slowing down test suite

Tests verify:
- Configuration requirements
- URL normalization
- Module structure and API
- Integration with RemoteAccess context

## Future Enhancements

1. **Dynamic Start/Stop**: Implement dynamic supervisor to start/stop relay when remote access is toggled without requiring app restart.

2. **Connection Handling**: Integrate relay-based connections with the Noise handshake flow (implemented in later tasks).

3. **Metrics**: Track relay connection uptime, reconnection count, and message statistics.

4. **Fallback Strategy**: Automatically fall back to relay if direct connection attempts fail.

## Security Considerations

- The relay service only sees encrypted Noise protocol messages
- Instance public keys are safe to share with the relay
- The relay cannot decrypt or modify Noise handshake messages
- Client authentication still happens via claim codes (not relay-dependent)

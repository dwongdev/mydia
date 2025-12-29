# Mock Services for E2E Testing

This directory contains mock implementations of external services used by Mydia for end-to-end testing.

## Services

### Mock Prowlarr

A lightweight Node.js/Express server that mimics the Prowlarr API.

**Endpoints:**

- `GET /health` - Health check
- `GET /api/v1/indexer` - List all indexers
- `GET /api/v1/indexer/:id` - Get specific indexer
- `GET /api/v1/search?query=...&categories=...` - Search indexers
- `GET /api/v1/test` - Test connection
- `GET /api/v1/system/status` - System status

**Authentication:**

- Uses API key via `X-Api-Key` header or `apikey` query parameter
- Default API key: `test-api-key`

**Test Data:**

- 2 mock indexers (1 torrent, 1 usenet)
- 3 mock search results with various formats

### Mock qBittorrent

A lightweight Node.js/Express server that mimics the qBittorrent Web API.

**Endpoints:**

- `GET /health` - Health check
- `POST /api/v2/auth/login` - Login (sets session cookie)
- `POST /api/v2/auth/logout` - Logout
- `GET /api/v2/app/version` - Get version
- `GET /api/v2/app/preferences` - Get preferences
- `GET /api/v2/torrents/info` - List torrents
- `POST /api/v2/torrents/add` - Add torrent
- `POST /api/v2/torrents/delete` - Delete torrents
- `POST /api/v2/torrents/pause` - Pause torrents
- `POST /api/v2/torrents/resume` - Resume torrents
- `GET /api/v2/torrents/properties` - Get torrent properties

**Authentication:**

- Cookie-based session management
- Default credentials: `admin` / `adminpass`

**Features:**

- In-memory torrent storage
- Simulated download progress (5% every 5 seconds)
- Automatic state transitions (downloading → uploading)
- Dynamic speed and ratio calculations

## Running the E2E Environment

Mock services are controlled via the `e2e` profile in `compose.test.yml`.

### Start all services (including mocks):

```bash
docker compose -f compose.test.yml --profile e2e up -d
```

### View logs:

```bash
docker compose -f compose.test.yml --profile e2e logs -f
```

### Stop all services:

```bash
docker compose -f compose.test.yml --profile e2e down
```

### Rebuild mock services after changes:

```bash
docker compose -f compose.test.yml --profile e2e build mock-prowlarr mock-qbittorrent
```

## Service URLs (from host)

- **Mydia App**: http://localhost:4000
- **Mock OAuth2**: http://localhost:8080
- **Mock Prowlarr**: http://localhost:19696 (mapped from internal 9696 to avoid conflicts)
- **Mock qBittorrent**: http://localhost:8082

## Service URLs (from containers)

- **Mock Prowlarr**: http://mock-prowlarr:9696
- **Mock qBittorrent**: http://mock-qbittorrent:8080
- **Mock OAuth2**: http://mock-oauth2:8080

## Environment Variables

The app service is configured to use mock services via environment variables in `compose.test.yml`:

```yaml
PROWLARR_URL: "http://mock-prowlarr:9696"
PROWLARR_API_KEY: "test-api-key"
QBITTORRENT_URL: "http://mock-qbittorrent:8080"
QBITTORRENT_USERNAME: "admin"
QBITTORRENT_PASSWORD: "adminpass"
```

## Extending Mock Services

### Adding new Prowlarr endpoints:

Edit `test/mock_services/prowlarr/server.js` and add new Express routes.

### Adding new qBittorrent endpoints:

Edit `test/mock_services/qbittorrent/server.js` and add new Express routes.

### Adding test data:

Modify the `mockIndexers` and `mockSearchResults` arrays in the Prowlarr server, or add initial torrents in the qBittorrent server.

## Troubleshooting

### Services fail to start:

Check service health with:

```bash
docker compose -f compose.test.yml --profile e2e ps
```

### Mock service crashes:

View logs to debug:

```bash
docker compose -f compose.test.yml --profile e2e logs mock-prowlarr
docker compose -f compose.test.yml --profile e2e logs mock-qbittorrent
```

### App can't connect to mock services:

Verify network connectivity from app container:

```bash
docker compose -f compose.test.yml --profile e2e exec app curl http://mock-prowlarr:9696/health
docker compose -f compose.test.yml --profile e2e exec app curl http://mock-qbittorrent:8080/health
```

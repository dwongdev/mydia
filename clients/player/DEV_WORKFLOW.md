# Flutter Player Development Workflow

This document describes how to develop and build the Flutter web player for Mydia.

## Prerequisites

- Docker and Docker Compose installed
- Project set up: `./dev up -d` starts all services automatically

## Development Mode (Automatic Hot Reload)

### Starting Everything

From the project root, just run:

```bash
./dev up -d
```

This starts both Phoenix AND the Flutter dev server with hot reload enabled. That's it!

### Accessing the Player

Navigate to `http://localhost:4000/player` in your browser.

The Phoenix endpoint automatically:
- Proxies requests to the Flutter dev server
- Handles authentication via Phoenix's auth system
- Injects auth tokens so the Flutter app auto-authenticates

### Auto-Rebuild with Live Reload

Edit files in `clients/player/lib/` and the browser will automatically refresh when the build completes. No manual refresh needed!

**How it works:**
1. File watcher detects changes in `lib/`
2. Flutter rebuilds the web app (~40 seconds)
3. Built files sync to `priv/static/player/` (Phoenix static folder)
4. Browser automatically refreshes via Server-Sent Events

**Note:** This is a full rebuild, not Flutter's hot reload (which requires an interactive terminal). The trade-off for Docker-based development is slightly longer rebuild times but zero manual steps.

### Useful Commands

```bash
./dev player logs      # Follow Flutter dev server output
./dev player restart   # Force restart the Flutter dev server
./dev player shell     # Open shell in Flutter container
```

## Building for Production

### Build the Flutter Web Assets

From the project root:

```bash
./dev player build
```

This command will:
1. Build the Flutter web app with `--base-href /player/`
2. Copy the built assets to `priv/static/player/`
3. Make them available for Phoenix to serve as static files

### What Gets Built

The build process creates:
- `index.html` - The main HTML file
- `flutter.js` - Flutter web engine
- `main.dart.js` - Your compiled Dart code
- `assets/` - Fonts, images, and other assets
- `canvaskit/` - CanvasKit WASM files for rendering

All files are copied to `priv/static/player/` and served by Phoenix at `/player/*`.

## How It Works

### Development Mode

1. **Flutter Dev Server**: Runs on `localhost:3000` with hot reload enabled
2. **Phoenix Proxy**: `MydiaWeb.Plugs.FlutterDevProxy` intercepts `/player/*` requests
3. **Request Flow**:
   - User visits `http://localhost:4000/player`
   - Phoenix proxy forwards to `http://localhost:3000/`
   - Flutter dev server responds with live-reloading content
   - Proxy forwards response back to user

### Production Mode

1. **Static Files**: Built Flutter assets in `priv/static/player/`
2. **Phoenix Routes**: `MydiaWeb.Router` routes `/player/*` to `PlayerController`
3. **Request Flow**:
   - User visits `http://yourserver.com/player`
   - Phoenix router matches route to `PlayerController.index/2`
   - Controller serves `priv/static/player/index.html`
   - Flutter's hash-based routing takes over on the client

## Common Commands

### Run Flutter commands directly

```bash
./dev flutter <command>
```

Examples:
- `./dev flutter doctor` - Check Flutter installation
- `./dev flutter pub get` - Install dependencies
- `./dev flutter analyze` - Run static analysis
- `./dev flutter test` - Run unit tests

### Development workflow

```bash
# Start everything (Phoenix + Flutter dev server)
./dev up -d

# Open the player in browser
open http://localhost:4000/player

# Make changes to Flutter code - hot reload happens automatically!

# Watch Flutter logs to see rebuild status
./dev player logs

# When ready, build for production
./dev player build
```

## Troubleshooting

### Flutter dev server not starting

- Check if port 3000 is already in use: `lsof -i :3000`
- Check Flutter container logs: `./dev player logs`
- Restart the Flutter container: `./dev player restart`

### Changes not reflecting

- **Development**: Check Flutter logs for build errors: `./dev player logs`
- **Production**: Rebuild the assets with `./dev player build`
- Clear browser cache (Cmd+Shift+R / Ctrl+Shift+R)

### 404 errors in production

- Ensure you've run `./dev player build` before deploying
- Check that `priv/static/player/` contains the built files
- Verify the routes in `lib/mydia_web/router.ex` are correct

### Proxy not working in development

- Check if the Flutter dev server is running: `docker compose ps flutter`
- Check Flutter logs for errors: `./dev player logs`
- Verify Phoenix is in dev mode (code reloading enabled)

## Architecture Notes

### Authentication

The Flutter player requires authentication. All `/player/*` routes go through Phoenix's `:auth` and `:require_authenticated` pipelines, ensuring users are logged in before accessing the player.

### Routing Strategy

Flutter uses **hash-based routing** (`/player/#/movies/123`) which allows:
- All routes to be served by the same `index.html`
- Client-side navigation without server round-trips
- Deep linking support (users can bookmark specific player views)

### Static Asset Serving

Phoenix's `Plug.Static` is configured to serve the `player` directory, which is defined in `MydiaWeb.static_paths/0`. This ensures efficient caching and delivery of Flutter's compiled assets.

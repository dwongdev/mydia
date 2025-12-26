# Quick Start: CI/CD Multi-Platform Builds

This is a quick reference for the CI/CD system. For detailed documentation, see:
- `CICD_FLUTTER_SETUP.md` - Complete CI/CD documentation
- `GITHUB_SECRETS_REFERENCE.md` - GitHub Secrets setup
- `clients/player/PLATFORM_SETUP_GUIDE.md` - Platform-by-platform setup

## TL;DR - What Works Now

✅ **Web builds** are fully integrated and working
✅ **Docker releases** include Flutter web player automatically
✅ **Version syncing** works for all platforms
✅ **GitHub releases** created automatically on tag push

⚠️ **Native platforms** (Android, iOS, macOS, Windows, Linux) require platform setup first

## Creating a Release

### 1. Update Version

Edit `mix.exs`:
```elixir
version: "1.2.3",
```

### 2. Commit and Tag

```bash
git add mix.exs
git commit -m "chore: bump version to 1.2.3"
git tag v1.2.3
git push origin v1.2.3
```

### 3. Wait for CI/CD

GitHub Actions will automatically:
- Build Flutter web (active now)
- Build native platforms (when configured)
- Create GitHub release with artifacts
- Push Docker images to GHCR

## Local Development

### Build Flutter Web

```bash
# Quick build
./scripts/build-flutter-web.sh

# Or manually
cd clients/player
flutter pub get
flutter pub run build_runner build --delete-conflicting-outputs
flutter build web --release --web-renderer canvaskit --base-href /player/
cp -r build/web/* ../../priv/static/player/
```

### Using ./dev Wrapper

```bash
./dev flutter pub get        # Install Flutter dependencies
./dev flutter build web      # Build Flutter web
./dev player run            # Run Flutter dev server
./dev player build          # Build Flutter web release
```

## Adding Native Platforms

### Quick Setup Commands

```bash
cd clients/player

# Add platforms
flutter create --platforms=android .
flutter create --platforms=ios .
flutter create --platforms=macos,windows,linux .
```

After adding platforms, follow `PLATFORM_SETUP_GUIDE.md` for detailed configuration.

## Version Syncing

Version is automatically extracted from Git tags:

- Tag: `v1.2.3`
- Version: `1.2.3`
- Version code: `10203`
- Applied to: pubspec.yaml, Android, iOS, all platforms

## Pre-releases

For beta/RC versions:

```bash
git tag v1.2.3-beta.1
git push origin v1.2.3-beta.1
```

This will:
- Mark GitHub release as pre-release
- Tag Docker image as `beta` instead of `latest`

## Platform Status

| Platform | Status | Next Steps |
|----------|--------|------------|
| Web | ✅ Active | None - fully working |
| Android | ⚠️ Setup needed | Run `flutter create --platforms=android .` |
| iOS | ⚠️ Setup needed | Run `flutter create --platforms=ios .` |
| macOS | ⚠️ Setup needed | Run `flutter create --platforms=macos .` |
| Windows | ⚠️ Setup needed | Run `flutter create --platforms=windows .` |
| Linux | ⚠️ Setup needed | Run `flutter create --platforms=linux .` |

## GitHub Secrets Needed

Only required when setting up native platforms:

### Android
- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

### iOS
- `IOS_BUILD_CERTIFICATE_BASE64`
- `IOS_P12_PASSWORD`
- `IOS_BUILD_PROVISION_PROFILE_BASE64`
- `KEYCHAIN_PASSWORD`
- `APPLE_ID`
- `APPLE_APP_PASSWORD`
- `APPLE_TEAM_ID`

### Windows
- `WINDOWS_CERTIFICATE_BASE64`
- `WINDOWS_CERTIFICATE_PASSWORD`

See `GITHUB_SECRETS_REFERENCE.md` for generation instructions.

## Troubleshooting

### "Platform not configured" in workflow

This is expected. The workflow checks for platform directories and skips builds if not found. Add platforms as needed.

### Web build not in Docker image

Check Dockerfile includes Flutter SDK installation and web build step (lines 35-44 and 75-83).

### Version not updating

Verify Git tag format is `vX.Y.Z` (with 'v' prefix).

### Build fails

Check GitHub Actions logs for specific errors. Most common issues:
- Missing platform directory
- Missing GitHub Secrets
- Flutter version mismatch

## Testing

### Test Workflow Locally

```bash
# Install act
brew install act  # macOS
# or: curl https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash

# Run workflow
act push -e test-event.json
```

### Test Docker Build

```bash
docker build -t mydia-test .
docker run -p 4000:4000 mydia-test
```

Visit `http://localhost:4000/player` to verify web player.

## Next Steps

1. **For Web** (already working):
   - Just create tags and releases
   - Web builds happen automatically

2. **For Native Platforms**:
   1. Add platform: `flutter create --platforms=<name> .`
   2. Configure platform (see `PLATFORM_SETUP_GUIDE.md`)
   3. Set up GitHub Secrets (see `GITHUB_SECRETS_REFERENCE.md`)
   4. Uncomment signing steps in workflow
   5. Create test tag to verify

## Support

For detailed help:
- Full documentation: `CICD_FLUTTER_SETUP.md`
- Platform setup: `clients/player/PLATFORM_SETUP_GUIDE.md`
- Secrets reference: `GITHUB_SECRETS_REFERENCE.md`
- Implementation details: `TASK_1.22_CICD_IMPLEMENTATION_REPORT.md`

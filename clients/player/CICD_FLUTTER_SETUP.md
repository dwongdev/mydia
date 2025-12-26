# CI/CD Multi-Platform Flutter Builds

This document describes the automated build and release process for the Mydia Flutter player across all platforms.

## Overview

The CI/CD system automatically builds and releases the Flutter player for multiple platforms when version tags are pushed to the repository.

### Platforms Supported

- **Web**: Integrated into Phoenix server release
- **Android**: APK (Google Play and sideloading)
- **iOS**: TestFlight distribution via Fastlane
- **macOS**: DMG installer
- **Windows**: MSIX package
- **Linux**: AppImage

## Workflow Files

### Primary Workflow: `flutter-player-release.yml`

Location: `.github/workflows/flutter-player-release.yml`

**Triggers:**
- Push to version tags matching `v*` (e.g., `v1.0.0`)
- Manual workflow dispatch with version input

**Jobs:**

1. **prepare**: Extracts version number and calculates version code
2. **build-web**: Builds web version (uploads artifact for later use)
3. **build-android**: Builds Android APK (requires Android platform setup)
4. **build-ios**: Builds iOS and uploads to TestFlight (requires iOS platform setup)
5. **build-macos**: Builds macOS DMG (requires macOS platform setup)
6. **build-windows**: Builds Windows MSIX (requires Windows platform setup)
7. **build-linux**: Builds Linux AppImage (requires Linux platform setup)
8. **create-release**: Creates GitHub release with all platform artifacts

### Integration with Phoenix Release

The web build is integrated into the main Phoenix Docker release via the `Dockerfile`:

1. Flutter SDK is installed during Docker build
2. Flutter web app is built before Phoenix assets
3. Built web files are copied to `priv/static/player/`
4. Phoenix release includes the Flutter web player

## Version Syncing

The Flutter player version is automatically synced with the Mydia release version:

1. Tags follow semantic versioning: `vMAJOR.MINOR.PATCH` (e.g., `v0.7.5`)
2. Version number is extracted from the tag
3. `pubspec.yaml` is updated automatically during build
4. Version code is calculated: `MAJOR * 10000 + MINOR * 100 + PATCH`

Example:
- Tag: `v1.2.3`
- Version: `1.2.3`
- Version code: `10203`
- pubspec.yaml: `version: 1.2.3+10203`

## Platform Setup Status

### ✅ Web (Fully Configured)

**Status**: Production ready

**Build Process**:
- Builds with `flutter build web --release --web-renderer canvaskit --base-href /player/`
- Outputs to `build/web/`
- Integrated into Phoenix at `/player` route

**Artifacts**: Included in Docker image, no separate artifact

### ⚠️ Android (Requires Setup)

**Status**: Workflow ready, platform not configured

**Prerequisites**:
1. Add Android platform to Flutter project:
   ```bash
   cd clients/player
   flutter create --platforms=android .
   ```

2. Configure signing in GitHub Secrets:
   - `ANDROID_KEYSTORE_BASE64`: Base64-encoded keystore file
   - `ANDROID_KEYSTORE_PASSWORD`: Keystore password
   - `ANDROID_KEY_ALIAS`: Key alias
   - `ANDROID_KEY_PASSWORD`: Key password

3. Uncomment signing configuration in workflow

**Output**: `player-android-vX.Y.Z.apk` as GitHub release asset

### ⚠️ iOS (Requires Setup)

**Status**: Workflow ready, platform not configured

**Prerequisites**:
1. Add iOS platform to Flutter project:
   ```bash
   cd clients/player
   flutter create --platforms=ios .
   ```

2. Set up Fastlane for TestFlight:
   ```bash
   cd clients/player/ios
   bundle init
   bundle add fastlane
   fastlane init
   ```

3. Configure GitHub Secrets:
   - `IOS_BUILD_CERTIFICATE_BASE64`: Base64-encoded signing certificate
   - `IOS_P12_PASSWORD`: Certificate password
   - `IOS_BUILD_PROVISION_PROFILE_BASE64`: Base64-encoded provisioning profile
   - `KEYCHAIN_PASSWORD`: Temporary keychain password
   - `APPLE_ID`: Apple Developer account email
   - `APPLE_APP_PASSWORD`: App-specific password
   - `APPLE_TEAM_ID`: Apple Developer Team ID

4. Uncomment certificate setup and Fastlane steps in workflow

**Output**: Uploaded to TestFlight automatically

### ⚠️ macOS (Requires Setup)

**Status**: Workflow ready, platform not configured

**Prerequisites**:
1. Add macOS platform to Flutter project:
   ```bash
   cd clients/player
   flutter create --platforms=macos .
   ```

2. Set up DMG creation (consider using `create-dmg` tool)

3. Configure notarization with Apple:
   - `APPLE_ID`: Apple Developer account email
   - `APPLE_APP_PASSWORD`: App-specific password
   - `APPLE_TEAM_ID`: Apple Developer Team ID

4. Uncomment DMG creation and notarization steps in workflow

**Output**: `player-macos-vX.Y.Z.tar.gz` as GitHub release asset

### ⚠️ Windows (Requires Setup)

**Status**: Workflow ready, platform not configured

**Prerequisites**:
1. Add Windows platform to Flutter project:
   ```bash
   cd clients/player
   flutter create --platforms=windows .
   ```

2. Configure MSIX packaging in `pubspec.yaml`:
   ```yaml
   msix_config:
     display_name: Mydia Player
     publisher_display_name: Mydia
     identity_name: com.mydia.player
     msix_version: 1.0.0.0
     logo_path: assets/logo.png
   ```

3. Add `msix` package to dev dependencies

4. Configure signing secrets:
   - `WINDOWS_CERTIFICATE_BASE64`: Base64-encoded signing certificate
   - `WINDOWS_CERTIFICATE_PASSWORD`: Certificate password

5. Uncomment MSIX creation and signing steps in workflow

**Output**: `player-windows-vX.Y.Z.zip` as GitHub release asset

### ⚠️ Linux (Requires Setup)

**Status**: Workflow ready, platform not configured

**Prerequisites**:
1. Add Linux platform to Flutter project:
   ```bash
   cd clients/player
   flutter create --platforms=linux .
   ```

2. Set up AppImage creation:
   - Download `appimagetool`
   - Create AppDir structure
   - Add `.desktop` file and icon

3. Uncomment AppImage creation steps in workflow

**Output**: `player-linux-vX.Y.Z.tar.gz` as GitHub release asset

## Local Development

### Building Flutter Web Locally

Use the provided script:

```bash
./scripts/build-flutter-web.sh
```

This will:
1. Install Flutter dependencies
2. Run code generation
3. Build web release
4. Copy output to `priv/static/player/`

### Manual Build Commands

```bash
cd clients/player

# Install dependencies
flutter pub get

# Run code generation
flutter pub run build_runner build --delete-conflicting-outputs

# Build web
flutter build web --release --web-renderer canvaskit --base-href /player/

# Copy to Phoenix
mkdir -p ../../priv/static/player
cp -r build/web/* ../../priv/static/player/
```

### Using Docker Wrapper

The `./dev` wrapper supports Flutter commands:

```bash
./dev flutter pub get
./dev flutter build web
./dev player run    # Run Flutter web dev server
./dev player build  # Build Flutter web release
```

## Release Process

### Creating a New Release

1. Update version in `mix.exs`:
   ```elixir
   version: "1.2.3",
   ```

2. Commit the version change:
   ```bash
   git add mix.exs
   git commit -m "chore: bump version to 1.2.3"
   ```

3. Create and push version tag:
   ```bash
   git tag v1.2.3
   git push origin v1.2.3
   ```

4. GitHub Actions will automatically:
   - Build all platform variants (where configured)
   - Create GitHub release with artifacts
   - Push Docker images to GHCR
   - Upload iOS build to TestFlight (if configured)

### Pre-release Versions

For beta or release candidate versions:

```bash
git tag v1.2.3-beta.1
git push origin v1.2.3-beta.1
```

The workflow automatically detects pre-release tags and:
- Marks GitHub release as pre-release
- Tags Docker image as `beta` instead of `latest`
- Does not create semver aliases for Docker images

## Troubleshooting

### Build Failures

**Flutter SDK Download Fails**:
- Check Flutter version is available for Linux
- Verify network connectivity in GitHub Actions

**Code Generation Fails**:
- Ensure `build_runner` is in dev dependencies
- Check GraphQL schema files are present
- Verify no syntax errors in `.graphql` files

**Web Build Fails**:
- Check Flutter version compatibility
- Verify all dependencies support web platform
- Review build logs for specific errors

### Platform-Specific Issues

**Android**:
- Verify keystore is correctly base64-encoded
- Check Gradle version compatibility
- Ensure signing configuration matches keystore

**iOS**:
- Verify certificates and provisioning profiles are valid
- Check Fastlane configuration is correct
- Ensure Apple Developer credentials have necessary permissions

**macOS**:
- Verify app is signed with Developer ID
- Check notarization credentials are correct
- Ensure all entitlements are properly configured

**Windows**:
- Verify MSIX configuration is correct
- Check certificate is valid for code signing
- Ensure publisher identity matches certificate

**Linux**:
- Verify all system dependencies are included in AppImage
- Check desktop integration files are correct
- Ensure AppImage is executable

## Security Considerations

### Secrets Management

All sensitive credentials are stored as GitHub Secrets:

- Never commit certificates, keys, or passwords
- Rotate credentials regularly
- Use app-specific passwords where supported
- Limit secret access to necessary workflows

### Code Signing

All platform builds should be signed:

- **Android**: Use upload key for Google Play, release key for sideloading
- **iOS**: Use Developer ID certificate
- **macOS**: Sign and notarize with Developer ID
- **Windows**: Use code signing certificate

### Supply Chain Security

- Pin GitHub Actions versions to specific commits
- Verify integrity of downloaded SDKs
- Use official Flutter releases only
- Review dependency updates before merging

## Future Improvements

1. **Automated Testing**: Add integration tests to workflows
2. **App Store Distribution**: Automate Google Play and App Store uploads
3. **Code Signing Automation**: Use GitHub-hosted signing
4. **Performance Monitoring**: Add build time and size tracking
5. **Artifact Signing**: Sign all release artifacts with GPG
6. **Release Notes**: Auto-generate from commit messages

## References

- [Flutter CI/CD Best Practices](https://docs.flutter.dev/deployment/cd)
- [GitHub Actions for Flutter](https://github.com/marketplace/actions/flutter-action)
- [Fastlane for iOS](https://docs.fastlane.tools/)
- [Android App Signing](https://developer.android.com/studio/publish/app-signing)

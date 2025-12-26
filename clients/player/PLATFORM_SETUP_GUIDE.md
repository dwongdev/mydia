# Platform Setup Guide

This guide walks through setting up each native platform for the Mydia Player Flutter app.

## Current Status

- ✅ **Web**: Fully configured and integrated with Phoenix
- ⚠️ **Android**: Not yet configured
- ⚠️ **iOS**: Not yet configured
- ⚠️ **macOS**: Not yet configured
- ⚠️ **Windows**: Not yet configured
- ⚠️ **Linux**: Not yet configured

## Prerequisites

- Flutter SDK 3.24.0 or higher
- Platform-specific development tools (see each section)

---

## Android Setup

### 1. Add Android Platform

```bash
cd clients/player
flutter create --platforms=android .
```

This creates the `android/` directory with necessary configuration files.

### 2. Configure App Identity

Edit `android/app/build.gradle`:

```gradle
android {
    defaultConfig {
        applicationId "com.mydia.player"
        minSdkVersion 21
        targetSdkVersion 34
        versionCode flutterVersionCode.toInteger()
        versionName flutterVersionName
    }
}
```

### 3. Set Up App Signing

Generate a keystore:

```bash
keytool -genkey -v -keystore ~/mydia-release-key.jks -keyalg RSA -keysize 2048 -validity 10000 -alias mydia
```

Create `android/key.properties`:

```properties
storeFile=/path/to/mydia-release-key.jks
storePassword=YOUR_KEYSTORE_PASSWORD
keyAlias=mydia
keyPassword=YOUR_KEY_PASSWORD
```

Update `android/app/build.gradle` to use signing config:

```gradle
def keystoreProperties = new Properties()
def keystorePropertiesFile = rootProject.file('key.properties')
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}

android {
    signingConfigs {
        release {
            keyAlias keystoreProperties['keyAlias']
            keyPassword keystoreProperties['keyPassword']
            storeFile keystoreProperties['storeFile'] ? file(keystoreProperties['storeFile']) : null
            storePassword keystoreProperties['storePassword']
        }
    }
    buildTypes {
        release {
            signingConfig signingConfigs.release
        }
    }
}
```

### 4. Configure GitHub Secrets

Convert keystore to base64 and add to GitHub Secrets:

```bash
base64 -i ~/mydia-release-key.jks | pbcopy
```

Add these secrets to GitHub repository:
- `ANDROID_KEYSTORE_BASE64`: The base64-encoded keystore
- `ANDROID_KEYSTORE_PASSWORD`: Keystore password
- `ANDROID_KEY_ALIAS`: `mydia`
- `ANDROID_KEY_PASSWORD`: Key password

### 5. Update CI/CD Workflow

Uncomment the signing configuration section in `.github/workflows/flutter-player-release.yml`.

### 6. Test Build

```bash
flutter build apk --release
```

---

## iOS Setup

### 1. Add iOS Platform

```bash
cd clients/player
flutter create --platforms=ios .
```

### 2. Configure App Identity

Edit `ios/Runner/Info.plist`:

```xml
<key>CFBundleIdentifier</key>
<string>com.mydia.player</string>
<key>CFBundleDisplayName</key>
<string>Mydia Player</string>
```

### 3. Set Up Xcode Project

Open `ios/Runner.xcworkspace` in Xcode:

1. Select the Runner project
2. Set Team to your Apple Developer team
3. Set Bundle Identifier to `com.mydia.player`
4. Configure signing certificates

### 4. Install Fastlane

```bash
cd ios
bundle init
bundle add fastlane cocoapods
bundle install
fastlane init
```

Copy the Fastlane template:

```bash
cp ../ios-setup-templates/Fastfile.template fastlane/Fastfile
cp ../ios-setup-templates/Gemfile.template Gemfile
```

### 5. Configure App Store Connect

1. Create app in App Store Connect
2. Set bundle ID to `com.mydia.player`
3. Enable TestFlight

### 6. Export Certificates

Export signing certificate and provisioning profile:

```bash
# Export certificate from Keychain as .p12
# Export provisioning profile from Xcode

# Convert to base64
base64 -i certificate.p12 | pbcopy
base64 -i profile.mobileprovision | pbcopy
```

### 7. Configure GitHub Secrets

Add these secrets to GitHub repository:
- `IOS_BUILD_CERTIFICATE_BASE64`: Base64-encoded .p12 certificate
- `IOS_P12_PASSWORD`: Certificate password
- `IOS_BUILD_PROVISION_PROFILE_BASE64`: Base64-encoded provisioning profile
- `KEYCHAIN_PASSWORD`: Temporary keychain password (generate random)
- `APPLE_ID`: Apple Developer account email
- `APPLE_APP_PASSWORD`: App-specific password from appleid.apple.com
- `APPLE_TEAM_ID`: Team ID from Apple Developer account

### 8. Update CI/CD Workflow

Uncomment the iOS signing and Fastlane sections in `.github/workflows/flutter-player-release.yml`.

### 9. Test Build

```bash
flutter build ios --release
cd ios
bundle exec fastlane local
```

---

## macOS Setup

### 1. Add macOS Platform

```bash
cd clients/player
flutter create --platforms=macos .
```

### 2. Configure App Identity

Edit `macos/Runner/Info.plist`:

```xml
<key>CFBundleIdentifier</key>
<string>com.mydia.player</string>
<key>CFBundleDisplayName</key>
<string>Mydia Player</string>
```

### 3. Enable Required Entitlements

Edit `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`:

```xml
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.network.server</key>
<true/>
```

### 4. Configure Signing

Open `macos/Runner.xcworkspace` in Xcode and configure signing with Developer ID.

### 5. Install DMG Creation Tool

```bash
npm install -g appdmg
# or
brew install create-dmg
```

Create `macos/dmg-config.json`:

```json
{
  "title": "Mydia Player",
  "icon": "AppIcon.icns",
  "background": "background.png",
  "contents": [
    { "x": 448, "y": 344, "type": "link", "path": "/Applications" },
    { "x": 192, "y": 344, "type": "file", "path": "player.app" }
  ]
}
```

### 6. Set Up Notarization

Configure GitHub Secrets:
- `APPLE_ID`: Apple Developer account email
- `APPLE_APP_PASSWORD`: App-specific password
- `APPLE_TEAM_ID`: Team ID

### 7. Update CI/CD Workflow

Uncomment the DMG creation and notarization sections in the workflow.

### 8. Test Build

```bash
flutter build macos --release
```

---

## Windows Setup

### 1. Add Windows Platform

```bash
cd clients/player
flutter create --platforms=windows .
```

### 2. Configure MSIX Package

Add to `pubspec.yaml`:

```yaml
msix_config:
  display_name: Mydia Player
  publisher_display_name: Mydia
  identity_name: com.mydia.player
  msix_version: 1.0.0.0
  logo_path: assets/logo.png
  capabilities: internetClient, privateNetworkClientServer
```

Add dependency:

```yaml
dev_dependencies:
  msix: ^3.16.0
```

### 3. Generate Signing Certificate

On Windows (or use existing certificate):

```powershell
New-SelfSignedCertificate -Type Custom -Subject "CN=Mydia" -KeyUsage DigitalSignature -FriendlyName "Mydia Code Signing" -CertStoreLocation "Cert:\CurrentUser\My"
```

Export the certificate with private key as .pfx file.

### 4. Configure GitHub Secrets

```bash
# Convert certificate to base64 (on Linux/Mac)
base64 -i certificate.pfx | pbcopy
```

Add secrets:
- `WINDOWS_CERTIFICATE_BASE64`: Base64-encoded .pfx certificate
- `WINDOWS_CERTIFICATE_PASSWORD`: Certificate password

### 5. Update CI/CD Workflow

Uncomment the MSIX signing section in the workflow.

### 6. Test Build

```bash
flutter build windows --release
flutter pub run msix:create
```

---

## Linux Setup

### 1. Add Linux Platform

```bash
cd clients/player
flutter create --platforms=linux .
```

### 2. Install Build Dependencies

```bash
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev
```

### 3. Create Desktop Entry

Create `linux/player.desktop`:

```desktop
[Desktop Entry]
Name=Mydia Player
Comment=Cross-platform media player
Exec=player
Icon=player
Terminal=false
Type=Application
Categories=AudioVideo;Player;
```

### 4. Set Up AppImage

Install AppImage tools:

```bash
wget https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x appimagetool-x86_64.AppImage
```

Create AppImage build script (`linux/build-appimage.sh`):

```bash
#!/bin/bash
set -e

APP_NAME="MydiaPlayer"
BUILD_DIR="build/linux/x64/release/bundle"
APPDIR="AppDir"

# Create AppDir structure
mkdir -p "$APPDIR/usr/bin"
mkdir -p "$APPDIR/usr/lib"
mkdir -p "$APPDIR/usr/share/applications"
mkdir -p "$APPDIR/usr/share/icons/hicolor/256x256/apps"

# Copy build output
cp -r "$BUILD_DIR"/* "$APPDIR/usr/bin/"

# Copy desktop file
cp linux/player.desktop "$APPDIR/usr/share/applications/"

# Copy icon
cp linux/icon.png "$APPDIR/usr/share/icons/hicolor/256x256/apps/player.png"

# Create AppRun
cat > "$APPDIR/AppRun" << 'EOF'
#!/bin/bash
SELF=$(readlink -f "$0")
HERE=${SELF%/*}
export PATH="${HERE}/usr/bin/:${HERE}/usr/sbin/:${PATH}"
export LD_LIBRARY_PATH="${HERE}/usr/lib/:${LD_LIBRARY_PATH}"
exec "${HERE}/usr/bin/player" "$@"
EOF
chmod +x "$APPDIR/AppRun"

# Build AppImage
./appimagetool-x86_64.AppImage "$APPDIR" "$APP_NAME-x86_64.AppImage"
```

### 5. Update CI/CD Workflow

Uncomment the AppImage creation section in the workflow.

### 6. Test Build

```bash
flutter build linux --release
cd linux
./build-appimage.sh
```

---

## Verification Checklist

After setting up each platform, verify:

### Android
- [ ] `flutter build apk` succeeds
- [ ] APK installs and runs on device
- [ ] CI/CD workflow builds and publishes APK
- [ ] App signing works in release builds

### iOS
- [ ] `flutter build ios` succeeds
- [ ] App runs on simulator and device
- [ ] Fastlane uploads to TestFlight
- [ ] CI/CD workflow completes successfully

### macOS
- [ ] `flutter build macos` succeeds
- [ ] App runs on macOS
- [ ] DMG is created correctly
- [ ] App is properly signed and notarized

### Windows
- [ ] `flutter build windows` succeeds
- [ ] MSIX package is created
- [ ] MSIX installs and runs
- [ ] Package is properly signed

### Linux
- [ ] `flutter build linux` succeeds
- [ ] AppImage is created
- [ ] AppImage runs on target distributions
- [ ] Desktop integration works

---

## Troubleshooting

### Common Issues

**"Platform not enabled"**:
- Run `flutter create --platforms=<platform> .` in the player directory

**Signing errors**:
- Verify certificates are valid and not expired
- Check secret names match exactly in workflow
- Ensure base64 encoding/decoding is correct

**Build failures**:
- Update Flutter SDK to latest stable
- Run `flutter clean && flutter pub get`
- Check platform-specific SDK versions

### Getting Help

- Flutter documentation: https://docs.flutter.dev/deployment
- Platform-specific guides in Flutter docs
- Check GitHub Actions logs for detailed error messages

---

## Next Steps

Once platforms are set up:

1. Test each platform build locally
2. Configure GitHub Secrets
3. Update CI/CD workflow (uncomment relevant sections)
4. Create a test release to verify automation
5. Document any platform-specific issues

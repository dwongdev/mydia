# GitHub Secrets Reference

This document lists all GitHub Secrets required for the multi-platform Flutter build CI/CD pipeline.

## Overview

Secrets are used to securely store sensitive information like signing certificates, API keys, and passwords needed for building and releasing the Mydia Player across all platforms.

## How to Add Secrets

1. Navigate to your GitHub repository
2. Go to Settings > Secrets and variables > Actions
3. Click "New repository secret"
4. Enter the name and value
5. Click "Add secret"

## Required Secrets by Platform

### Android

| Secret Name | Description | How to Generate |
|------------|-------------|-----------------|
| `ANDROID_KEYSTORE_BASE64` | Base64-encoded keystore file | `base64 -i mydia-release-key.jks \| pbcopy` |
| `ANDROID_KEYSTORE_PASSWORD` | Password for the keystore | Set when creating keystore |
| `ANDROID_KEY_ALIAS` | Key alias in keystore | Usually `mydia` or similar |
| `ANDROID_KEY_PASSWORD` | Password for the specific key | Set when creating keystore |

**Setup Steps**:
```bash
# Generate keystore
keytool -genkey -v -keystore mydia-release-key.jks -keyalg RSA -keysize 2048 -validity 10000 -alias mydia

# Convert to base64 for GitHub Secret
base64 -i mydia-release-key.jks | pbcopy  # macOS
base64 -w 0 mydia-release-key.jks | xclip -selection clipboard  # Linux
```

### iOS

| Secret Name | Description | How to Generate |
|------------|-------------|-----------------|
| `IOS_BUILD_CERTIFICATE_BASE64` | Base64-encoded .p12 signing certificate | Export from Keychain, then base64 encode |
| `IOS_P12_PASSWORD` | Password for .p12 certificate | Set when exporting from Keychain |
| `IOS_BUILD_PROVISION_PROFILE_BASE64` | Base64-encoded provisioning profile | Download from Apple Developer, then base64 encode |
| `KEYCHAIN_PASSWORD` | Temporary keychain password for CI | Generate random string: `openssl rand -base64 32` |
| `APPLE_ID` | Apple Developer account email | Your Apple ID email |
| `APPLE_APP_PASSWORD` | App-specific password | Generate at appleid.apple.com |
| `APPLE_TEAM_ID` | Apple Developer Team ID | Found in Apple Developer account |

**Setup Steps**:
```bash
# Export certificate from Keychain (do this on macOS)
# 1. Open Keychain Access
# 2. Find your Developer ID certificate
# 3. Right-click > Export
# 4. Save as .p12 with password

# Convert to base64
base64 -i certificate.p12 | pbcopy

# Download provisioning profile from Apple Developer
# Convert to base64
base64 -i profile.mobileprovision | pbcopy

# Generate random keychain password
openssl rand -base64 32

# Create app-specific password
# 1. Go to appleid.apple.com
# 2. Security > App-Specific Passwords
# 3. Generate new password
```

### macOS

| Secret Name | Description | How to Generate |
|------------|-------------|-----------------|
| `APPLE_ID` | Apple Developer account email | Your Apple ID email (same as iOS) |
| `APPLE_APP_PASSWORD` | App-specific password | Generate at appleid.apple.com (same as iOS) |
| `APPLE_TEAM_ID` | Apple Developer Team ID | Found in Apple Developer account (same as iOS) |

**Note**: macOS uses the same Apple Developer credentials as iOS.

### Windows

| Secret Name | Description | How to Generate |
|------------|-------------|-----------------|
| `WINDOWS_CERTIFICATE_BASE64` | Base64-encoded .pfx code signing certificate | Export certificate with private key, then base64 encode |
| `WINDOWS_CERTIFICATE_PASSWORD` | Password for .pfx certificate | Set when exporting certificate |

**Setup Steps**:
```powershell
# On Windows, create self-signed certificate (for testing)
New-SelfSignedCertificate -Type Custom -Subject "CN=Mydia" -KeyUsage DigitalSignature -FriendlyName "Mydia Code Signing" -CertStoreLocation "Cert:\CurrentUser\My"

# Export from Certificate Manager (certmgr.msc)
# 1. Find certificate in Personal > Certificates
# 2. Right-click > All Tasks > Export
# 3. Export private key as .pfx with password

# Convert to base64 (on Linux/macOS)
base64 -i certificate.pfx | pbcopy

# Or on Windows with PowerShell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("certificate.pfx")) | Set-Clipboard
```

### Linux

**No secrets required** - Linux builds use AppImage which doesn't require signing.

## Optional Secrets

These secrets are useful but not required for basic builds:

| Secret Name | Description | Platform | Purpose |
|------------|-------------|----------|---------|
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | Service account for Google Play publishing | Android | Automatic Play Store uploads |
| `FIREBASE_TOKEN` | Firebase token for app distribution | Android/iOS | Beta distribution via Firebase |

## Secret Validation

Use these commands to verify your secrets are correctly formatted:

### Android Keystore
```bash
# Decode and verify
echo "$ANDROID_KEYSTORE_BASE64" | base64 -d > test.jks
keytool -list -v -keystore test.jks -storepass "$ANDROID_KEYSTORE_PASSWORD"
rm test.jks
```

### iOS Certificate
```bash
# Decode and verify
echo "$IOS_BUILD_CERTIFICATE_BASE64" | base64 -d > test.p12
openssl pkcs12 -info -in test.p12 -passin pass:"$IOS_P12_PASSWORD"
rm test.p12
```

### Windows Certificate
```bash
# Decode and verify
echo "$WINDOWS_CERTIFICATE_BASE64" | base64 -d > test.pfx
openssl pkcs12 -info -in test.pfx -passin pass:"$WINDOWS_CERTIFICATE_PASSWORD"
rm test.pfx
```

## Security Best Practices

### Certificate Management

1. **Keep certificates secure**: Never commit certificates to git
2. **Use strong passwords**: Generate random passwords for certificates
3. **Rotate regularly**: Update certificates before expiration
4. **Limit access**: Only grant access to necessary team members

### Secret Rotation

Create a schedule for rotating secrets:

- **Keystore passwords**: Rotate annually
- **Apple app passwords**: Rotate every 6 months
- **Signing certificates**: Update before expiration
- **CI keychain password**: Can be rotated anytime

### Backup Strategy

1. Store original certificates in secure vault (1Password, LastPass, etc.)
2. Keep backup of keystore files offline
3. Document certificate creation process
4. Store certificate passwords separately from certificates

## Troubleshooting

### Common Issues

**"Invalid certificate" errors**:
- Verify base64 encoding is correct (no line breaks)
- Check certificate hasn't expired
- Ensure password matches certificate

**"Secret not found" errors**:
- Check secret name matches exactly (case-sensitive)
- Verify secret is added to repository, not organization
- Ensure workflow has correct permissions

**Base64 encoding issues**:
- Use `-w 0` flag on Linux to prevent line wrapping
- On macOS, base64 doesn't wrap by default
- On Windows, ensure no extra whitespace

### Testing Secrets Locally

You can test the workflow locally using [act](https://github.com/nektos/act):

```bash
# Install act
brew install act

# Run workflow with secrets
act -s ANDROID_KEYSTORE_BASE64="$(cat mydia-release-key.jks | base64)" \
    -s ANDROID_KEYSTORE_PASSWORD="password123" \
    -s ANDROID_KEY_ALIAS="mydia" \
    -s ANDROID_KEY_PASSWORD="password123"
```

## CI/CD Workflow Integration

Secrets are accessed in workflows using the `secrets` context:

```yaml
env:
  KEYSTORE_PASSWORD: ${{ secrets.ANDROID_KEYSTORE_PASSWORD }}

- name: Decode keystore
  run: echo "${{ secrets.ANDROID_KEYSTORE_BASE64 }}" | base64 -d > keystore.jks
```

## Checklist

Use this checklist when setting up secrets for the first time:

### Android
- [ ] Generate release keystore
- [ ] Export keystore to base64
- [ ] Add `ANDROID_KEYSTORE_BASE64` secret
- [ ] Add `ANDROID_KEYSTORE_PASSWORD` secret
- [ ] Add `ANDROID_KEY_ALIAS` secret
- [ ] Add `ANDROID_KEY_PASSWORD` secret
- [ ] Test build with secrets

### iOS
- [ ] Export signing certificate as .p12
- [ ] Convert certificate to base64
- [ ] Export provisioning profile
- [ ] Convert profile to base64
- [ ] Generate keychain password
- [ ] Generate app-specific password
- [ ] Add all iOS secrets
- [ ] Test build with secrets

### macOS
- [ ] Verify Apple ID credentials (same as iOS)
- [ ] Test notarization credentials
- [ ] Test build with secrets

### Windows
- [ ] Generate or obtain code signing certificate
- [ ] Export as .pfx with password
- [ ] Convert to base64
- [ ] Add secrets
- [ ] Test build with secrets

## Support

If you encounter issues with secrets:

1. Verify secret values are correct
2. Check workflow logs for specific errors
3. Test certificate locally before uploading
4. Ensure all required secrets are present
5. Verify base64 encoding is correct

For platform-specific issues, consult the Platform Setup Guide.

# Noise Protocol Implementation Note

## Decision: Manual Implementation vs noise_protocol_framework

### Context

Task 13.4 originally specified using the `noise_protocol_framework` package (v1.1.0) from pub.dev for implementing Noise protocol handshakes compatible with the backend Decibel library.

### Issue Encountered

After adding `noise_protocol_framework` to dependencies and attempting to use it, we encountered:

1. **Lack of API Documentation**: The package's pub.dev page and GitHub repository lack detailed API documentation or working examples for the main classes and methods needed
2. **Unknown API Surface**: Could not determine the correct class names, method signatures, or usage patterns through:
   - Web searches
   - Package source code examination (Docker container access issues)
   - API documentation pages
3. **Compilation Errors**: Initial implementation based on standard Noise protocol patterns resulted in undefined class errors (`NoiseHandshakeState`, `MessageBuffer`, `Role` not found)

### Decision

**Removed `noise_protocol_framework` from dependencies** and implemented Noise protocol handshakes manually using:

- **cryptography** package (already in use): Provides X25519 (Curve25519) key exchange and ChaCha20-Poly1305 AEAD cipher
- **pointycastle** package (already in use): Additional cryptographic primitives if needed

### Current Implementation Status

The `noise_service.dart` currently provides:

1. ✅ Keypair generation using X25519
2. ✅ Secure key storage via flutter_secure_storage
3. ✅ Session scaffolding for NK and IK patterns
4. ✅ **Handshake implementation**: Fully implemented using manual approach with PointyCastle for BLAKE2b

### Implementation Approach (Completed)

**Option B: Manual Implementation** - COMPLETED

- ✅ Implemented full Noise Protocol state machine manually
- ✅ Follows Noise Protocol specification for NK and IK patterns
- ✅ Uses cryptography package for X25519 and ChaCha20-Poly1305
- ✅ Uses PointyCastle for BLAKE2b hashing and HMAC
- ✅ Proper handshake message parsing and generation
- ✅ Transport encryption/decryption after handshake
- ✅ All tests passing

### Backend Compatibility Requirements

Any implementation must be compatible with backend Decibel library (Elixir):

- **Protocol Names**: `Noise_NK_25519_ChaChaPoly_BLAKE2b`, `Noise_IK_25519_ChaChaPoly_BLAKE2b`
- **Key Exchange**: Curve25519 (X25519)
- **Cipher**: ChaCha20-Poly1305
- **Hash**: BLAKE2b
- **Message Format**: Must match Decibel's wire format expectations

### References

- Backend implementation: `/lib/mydia/remote_access/pairing.ex`
- Noise Protocol spec: https://noiseprotocol.org/noise.html
- Decibel library: https://hex.pm/packages/decibel

---

**Status**: Implementation complete using manual approach with PointyCastle
**Date**: 2025-12-26

# Security Model - Metadata Relay Service

This document describes the security model for the metadata-relay service,
particularly focusing on the claim code system used for device pairing.

## Trust Assumptions

### What the Relay Service Protects

1. **Metadata API Keys**: TMDB and TVDB API keys are centralized on the relay,
   not exposed to clients
2. **Rate Limiting**: Prevents abuse of external metadata APIs
3. **Claim Code Distribution**: Ensures codes are cryptographically random and
   short-lived

### What Happens if Relay is Compromised

If an attacker gains control of the metadata-relay service:

#### What They CAN Do

1. **Intercept claim codes**: See generated claim codes during device pairing
2. **View instance metadata**: See instance IDs, public keys, direct URLs
3. **Interrupt service**: Deny access to metadata and pairing functionality
4. **MITM pairing attempts**: Potentially redirect devices to attacker-controlled
   instances (though devices verify instance public keys)

#### What They CANNOT Do

1. **Decrypt tunnel traffic**: All tunnel traffic between Flutter app and Mydia
   uses end-to-end encryption (Curve25519 key exchange). The relay only stores
   public keys and cannot decrypt traffic.
2. **Access user data**: The relay never sees user credentials, media files,
   watch history, or any content from the Mydia instance
3. **Impersonate instances**: The relay doesn't have instance secret keys.
   Instances authenticate to the relay, not vice versa.
4. **Retroactively decrypt**: Past communications remain secure (forward secrecy
   provided by the tunnel encryption)

### Security Boundaries

```
[Flutter App] <--claim code--> [Relay Service] <--claim code--> [Mydia Instance]
                                      |
                              Knows: public keys, direct URLs
                              Cannot: decrypt E2E tunnel traffic

[Flutter App] <========= E2E Encrypted Tunnel ==========> [Mydia Instance]
              (Relay cannot decrypt this even if compromised)
```

## Claim Code Security

### Cryptographic Properties

- **Entropy**: ~41 bits (8 characters, 31-character alphabet)
- **RNG**: `:crypto.strong_rand_bytes()` (CSPRNG via OpenSSL)
- **Expiration**: 5 minutes (300 seconds)
- **Single-use**: Marked as consumed after successful pairing

### Attack Surface Analysis

| Attack | Mitigation |
|--------|------------|
| Brute Force | Rate limited to 5 attempts/min per IP. At this rate, trying all ~852 billion codes would take ~324,000 years |
| Timing Attacks | Generic error responses prevent distinguishing between "code not found" vs "code expired" vs "code used" |
| Code Prediction | Cryptographically secure RNG (`:crypto.strong_rand_bytes`) prevents prediction |
| Replay | Single-use codes cannot be redeemed twice |
| Interception | HTTPS in transit; codes expire in 5 minutes limiting window |

### Alphabet Design

The claim code alphabet excludes ambiguous characters:
- Excluded: `O` (looks like `0`), `I` (looks like `1`), `0`, `1`
- Included: `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (31 characters)

This makes codes easier to read and type correctly on the Flutter app.

## Deployment Recommendations

1. **Always use HTTPS**: Deploy relay with TLS/SSL termination
2. **Monitor logs**: Watch for repeated failed claim attempts from same IP
3. **Keep dependencies updated**: Regularly update Elixir, OTP, and dependencies
4. **Backup strategy**: Consider running redundant relay instances
5. **Rate limit configuration**: Current defaults (5 redeems/min, 10 registers/min)
   are conservative; adjust based on expected traffic

## Audit Logging

The relay logs security-relevant events:

- **Successful redemptions**: Logged at INFO level with code prefix and instance ID
- **Failed redemptions**: Logged at WARNING level with code prefix and failure reason

Code prefixes (first 2 characters) are logged instead of full codes to enable
pattern detection while limiting exposure of sensitive data.

## Incident Response

If relay compromise is suspected:

1. **Rotate API keys**: Update TMDB_API_KEY and TVDB_API_KEY environment variables
2. **Existing claims expire**: All claim codes expire within 5 minutes automatically
3. **Notify users**: Inform users to re-pair devices if concerned
4. **Review logs**: Check ErrorTracker and application logs for suspicious activity
5. **Rebuild service**: Deploy from clean source after investigation

**Note**: End-to-end encrypted tunnels between Flutter apps and Mydia instances
remain secure even if the relay is compromised. The relay cannot decrypt this
traffic.

## Version History

- **2026-01-07**: Initial security documentation
- **2026-01-07**: Upgraded claim code RNG to use `:crypto.strong_rand_bytes()`
- **2026-01-07**: Increased default code length from 6 to 8 characters
- **2026-01-07**: Added generic error responses to mitigate timing attacks

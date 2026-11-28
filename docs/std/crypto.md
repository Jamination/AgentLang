# std.crypto

`use std.crypto`. Pure-AL SHA-256, HMAC-SHA256, constant-time comparison, Hex and Base64 /
Base64URL codecs, and operating-system cryptographic random bytes. Static and libc-free on Linux.

## SHA-256 & HMAC-SHA256

| Declaration | Description |
|---|---|
| `sha256(data: []u8) -> [32]u8` | 32-byte SHA-256 digest (FIPS 180-4). |
| `sha256_hex(data: []u8) -> str` | Lowercase 64-character hex SHA-256 digest. |
| `sha256_new() -> Sha256` | Starts an incremental SHA-256 hasher. |
| `sha256_update(s: *Sha256, data: []u8)` | Feeds more bytes into `s`. |
| `sha256_final(s: *Sha256) -> [32]u8` | Finalizes `s` and returns its 32-byte digest. |
| `hmac_sha256(key: []u8, msg: []u8) -> [32]u8` | 32-byte HMAC-SHA256 (RFC 2104). |
| `hmac_sha256_hex(key: []u8, msg: []u8) -> str` | Lowercase hex HMAC-SHA256. |
| `const_time_eq(a: []u8, b: []u8) -> bool` | Constant-time equality over equal-length byte slices. |

## Hex & Base64

| Declaration | Description |
|---|---|
| `hex_encode(data: []u8) -> str` | Lowercase hexadecimal encoding of bytes. |
| `hex_decode(s: str) -> ([]u8, bool)` | Decodes even-length upper/lower hex; `(nil, false)` on bad input. |
| `base64_encode(data: []u8) -> str` | Standard Base64 (RFC 4648) with `=` padding. |
| `base64_decode(s: str) -> ([]u8, bool)` | Decodes standard Base64 (with or without `=`). |
| `base64url_encode(data: []u8) -> str` | URL-safe Base64 (`-`, `_`) without padding. |
| `base64url_decode(s: str) -> ([]u8, bool)` | Decodes URL-safe Base64 (with or without `=`). |

## Cryptographic randomness

| Declaration | Description |
|---|---|
| `random_bytes(out: []u8) -> bool` | Fills `out` from the OS CSPRNG (`getrandom` on Linux x86-64/arm64, `RtlGenRandom` on Windows, `arc4random_buf` on macOS). |
| `random_u64() -> (u64, bool)` | Returns a cryptographically random `u64`. |

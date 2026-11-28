// std.crypto: SHA-256, HMAC-SHA256, constant-time eq, Hex, Base64/Base64URL, OS random_bytes.
use std.crypto

fn main() {
    // FIPS 180-4 SHA-256 vectors
    print("sha_empty:", sha256_hex(""))
    print("sha_abc:", sha256_hex("abc"))
    // Streaming multi-chunk SHA-256 matches one-shot
    s := sha256_new()
    sha256_update(&s, "abcdbcdecdefdefgefghfghighij")
    sha256_update(&s, "hijkijkljklmklmnlmnomnopnopq")
    d := sha256_final(&s)
    print("sha_stream:", hex_encode(d[..]) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")

    // RFC 4231 HMAC-SHA256 Test Case 2 (key = "Jefe", data = "what do ya want for nothing?")
    h := hmac_sha256_hex("Jefe", "what do ya want for nothing?")
    print("hmac_rfc4231:", h == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")

    // Constant-time equality
    print("ct_eq:", const_time_eq("secret", "secret"), const_time_eq("secret", "secreT"), const_time_eq("a", "ab"))

    // Hex encode / decode
    hb, hok := hex_decode("48656c6C6F")
    _, hbad1 := hex_decode("abc")
    _, hbad2 := hex_decode("zz")
    print("hex:", hok, hb, hex_encode(hb), hbad1, hbad2)

    // RFC 4648 Base64 & Base64URL vectors
    print("b64:", base64_encode(""), base64_encode("f"), base64_encode("fo"), base64_encode("foo"), base64_encode("foobar"))
    b1, ok1 := base64_decode("Zm9vYmFy")
    b2, ok2 := base64_decode("Zm8=")
    b3, ok3 := base64_decode("Zm8")
    _, ok4 := base64_decode("!!!")
    print("b64_dec:", ok1, b1, ok2, b2, ok3, b3, ok4)

    raw := []u8{0xfb, 0xff, 0xfe}
    uenc := base64url_encode(raw)
    udec, uok := base64url_decode(uenc)
    print("b64url:", uenc, uok, udec == raw)

    // OS CSPRNG sanity
    r1, rok1 := random_u64()
    r2, rok2 := random_u64()
    buf: [32]u8
    bok := random_bytes(buf[..])
    any_nz := false
    for x in buf {
        if x != 0 {
            any_nz = true
        }
    }
    print("rng:", rok1, rok2, bok, r1 != r2, any_nz)
}

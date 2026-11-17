// std.net addresses: parse_addr, fmt_ip, fmt_addr (RFC 5952 for IPv6), the constructors, and
// the error texts of the network error numbers. No sockets.
use std.net

fn show(text: str) {
    a, ok := parse_addr(text)
    if !ok {
        print(text, "-> bad")
        return
    }
    print(text, "->", fmt_addr(a), fmt_ip(a), a.v6, a.port, a.scope)
}

fn main() {
    for t in []str{
        "1.2.3.4", "1.2.3.4:80", "0.0.0.0:0", "255.255.255.255:65535", "127.0.0.1:8080",
        "::", "::1", "[::1]:443", "[::1]", "1::", "1:2:3:4:5:6:7:8", "2001:db8::1",
        "2001:DB8:0:0:1:0:0:1", "2001:db8:0:1:1:1:1:1", "2001:0:0:1:0:0:0:1", "fe80::1%2",
        "[fe80::abcd%15]:9000", "::ffff:192.0.2.1", "[::ffff:10.0.0.1]:53", "64:ff9b::1.2.3.4",
        "0:0:0:0:0:0:0:1", "1:0:0:2:0:0:0:3",
    } {
        show(t)
    }
    for t in []str{
        "", "1.2.3", "1.2.3.4.5", "256.1.1.1", "01.2.3.4", "1.2.3.4:", "1.2.3.4:65536",
        "1.2.3.4:x", "1.2.3.-4", " 1.2.3.4", "1:2:3:4:5:6:7:8:9", "1::2::3", ":::", "12345::",
        "g::1", "[::1", "[::1]80", "[::1]:", "::1%", "::1%x", "1:2:3:4:5:6:7", "1.2.3.4::",
        "::1.2.3", "[1.2.3.4]:80", "example.com", "1:2:3:4:5:6:7::8:9",
    } {
        show(t)
    }
    print(fmt_addr(ipv4(10, 0, 0, 1, 7)), fmt_addr(localhost4(1)), fmt_addr(localhost6(2)),
        fmt_addr(any4(3)), fmt_addr(any6(4)), fmt_addr(with_port(localhost6(2), 99)))
    a, _ := parse_addr("::1")
    print(a == localhost6(0), with_port(a, 5) == localhost6(5))
    for e in []i64{NET_WOULD_BLOCK, NET_RESET, NET_TIMED_OUT, NET_REFUSED, NET_IN_PROGRESS, 98,
            99, 101, 113, 32, NET_HOST_NOT_FOUND, NET_DNS_FAILURE, NET_DNS_TRY_AGAIN} {
        print(e, error_text(e))
    }
}

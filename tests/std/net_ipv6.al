// std.net over IPv6 loopback (::1): TCP and UDP, addresses as the system reports them, and
// IPv6-only sockets (a listener at :: takes no IPv4 connection). Skipped (status 77) where the
// machine has no IPv6 loopback address.
use std.net

const SEC = 1_000_000_000

fn main() -> i64 {
    u, ok := udp_bind(localhost6(0))
    if !ok {
        print("no IPv6 loopback:", error_text(io_error()))
        return 77
    }
    ua, _ := local_addr(u)
    print("udp:", fmt_ip(ua), ua.v6, ua.port > 0)
    v, _ := udp_bind(localhost6(0))
    va, _ := local_addr(v)
    send_to(u, "six", va)
    buf := alloc[u8](100)
    n, from := recv_from(v, buf, 5 * SEC)
    print("datagram:", n, buf[..n], from == ua, fmt_ip(from))
    print("to IPv4:", send_to(u, "x", localhost4(va.port)) < 0)

    l, okl := tcp_listen(any6(0))
    la, _ := local_addr(l)
    print("listen:", okl, fmt_ip(la), la.v6)
    c, okc := tcp_connect(localhost6(la.port), 10 * SEC)
    s, peer, oka := accept(l)
    print("connect:", okc, oka, fmt_ip(peer), peer.v6)
    send_all(c, "over six")
    n = recv_exact(s, buf[..8])
    print("tcp:", n, buf[..n])
    pa, _ := peer_addr(c)
    print("peer:", fmt_addr(pa) == fmt("[::1]:", la.port))
    close(c)
    close(s)

    // IPv6 only: the same port over IPv4 finds nothing
    _, ok4 := tcp_connect(localhost4(la.port), 10 * SEC)
    print("v6 only:", ok4, io_error())
    // by name: "localhost" has both families; IPv4 comes first
    list, okr := resolve("localhost", 7)
    print("localhost:", okr, len(list) > 0 && list[0] == localhost4(7))
    close(l)
    return 0
}

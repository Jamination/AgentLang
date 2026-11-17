// std.net UDP on the loopback interface: a round trip, the sender's address, datagrams cut
// to the buffer, empty and large datagrams, time limits, non-blocking receive, poll, and a
// datagram to a port where nobody listens (no error later, also on Windows).
use std.net

const SEC = 1_000_000_000

fn main() {
    a, oka := udp_bind(localhost4(0))
    b, okb := udp_bind(localhost4(0))
    aa, _ := local_addr(a)
    ba, _ := local_addr(b)
    print("bind:", oka, okb, fmt_ip(aa), aa.port > 0, aa.port != ba.port)
    buf := alloc[u8](2000)
    print("send_to:", send_to(a, "ping", ba))
    n, from := recv_from(b, buf, 5 * SEC)
    print("recv_from:", n, buf[..n], from == aa)
    send_to(b, "pong", from)
    n, from = recv_from(a, buf, 5 * SEC)
    print("reply:", n, buf[..n], from == ba)

    // cut to the buffer; empty; large
    big := alloc[u8](60000)
    for i in 0..len(big) { big[i] = u8(i % 251) }
    send_to(a, big[..100], ba)
    small := alloc[u8](10)
    n, _ = recv_from(b, small, 5 * SEC)
    print("cut:", n, small[9])
    print("empty:", send_to(a, "", ba), recv_from(b, buf, 5 * SEC).0)
    print("large:", send_to(a, big, ba), io_error())
    whole := alloc[u8](65536)
    n, _ = recv_from(b, whole, 5 * SEC)
    print("large back:", n, whole[..n] == big)

    // time limit, non-blocking, poll
    t0 := clock_ns()
    n, from = recv_from(b, buf, 150_000_000)
    print("limit:", n, io_error(), fmt_addr(from), clock_ns() - t0 >= 100_000_000)
    print("nonblocking:", set_nonblocking(b, true), recv_from(b, buf).0, io_error(), recv(b, buf), io_error())
    send_to(a, "x", ba)
    print("poll:", poll(b, POLL_READ, 5 * SEC), recv_from(b, buf).0)

    // nobody at that port: the datagram is lost, and nothing is reported later
    c, _ := udp_bind(localhost4(0))
    ca, _ := local_addr(c)
    close(c)
    print("to nobody:", send_to(a, "lost", ca))
    sleep_ms(50)
    n, _ = recv_from(a, buf, 200_000_000)
    print("after:", n, io_error())
    send_to(b, "still", aa)
    n, _ = recv_from(a, buf, 5 * SEC)
    print("still works:", n, buf[..n])

    // an IPv6 address on an IPv4 socket
    print("other family:", send_to(a, "x", localhost6(ba.port)) < 0, io_error() != 0)
    close(a)
    close(b)
    print("closed:", send_to(a, "x", ba), io_error())
}

// std.net: TCP and UDP over IPv4 and IPv6, a poll over several sockets for a game loop, and
// name resolution. `use std.net`. docs/std/net.md describes it.
// Failures are reported as by the file functions: a result that says so (false, -1) and
// `io_error()`, a Linux error number on every system (111 connection refused, 110 timed out,
// 11 would block, ...), with `error_text` for its text.
// The parts that differ per system are std/net_linux.al (raw system calls, no libc: a program
// stays static; names resolved from /etc/hosts and by DNS queries of its own) and
// std/net_windows.al (ws2_32.dll; names through getaddrinfo). Each defines the __net_*
// functions used below. Sockets are never inherited by programs started with std.os.

when TARGET_OS == Windows {
    use std.net_windows
} else {
    use std.net_linux
}

// ---------- error numbers ----------
const NET_WOULD_BLOCK = 11          // a non-blocking socket has nothing to give / take now
const NET_RESET = 104               // the peer reset the connection
const NET_TIMED_OUT = 110           // a time limit ran out
const NET_REFUSED = 111             // nothing listens at that address
const NET_IN_PROGRESS = 115         // a connection of tcp_connect_start is still being made
const NET_HOST_NOT_FOUND = 0x20001  // the name has no address (also: no such name)
const NET_DNS_FAILURE = 0x20002     // the name servers failed or answered nonsense
const NET_DNS_TRY_AGAIN = 0x20003   // (Windows) a temporary failure of the system's resolver

// ---------- addresses ----------
// An IPv4 or IPv6 address with a port. IPv4 uses the first 4 bytes of `ip`. `scope` is the
// interface number of an IPv6 link-local address (fe80::1%2), else 0.
struct Addr {
    ip: [16]u8
    v6: bool
    port: i64
    scope: i64
}

fn ipv4(a: i64, b: i64, c: i64, d: i64, port: i64) -> Addr {
    r := Addr{port: port}
    r.ip[0] = u8(a)
    r.ip[1] = u8(b)
    r.ip[2] = u8(c)
    r.ip[3] = u8(d)
    r
}

// 127.0.0.1, ::1, 0.0.0.0 (every interface), :: (every interface)
fn localhost4(port: i64) -> Addr { ipv4(127, 0, 0, 1, port) }
fn any4(port: i64) -> Addr { ipv4(0, 0, 0, 0, port) }
fn localhost6(port: i64) -> Addr {
    r := Addr{v6: true, port: port}
    r.ip[15] = 1
    r
}
fn any6(port: i64) -> Addr { Addr{v6: true, port: port} }

// the same address with another port
fn with_port(a: Addr, port: i64) -> Addr {
    a.port = port
    a
}

// Reads "1.2.3.4", "1.2.3.4:80", "::1", "fe80::1%2", "[::1]:80", "[::1]" (no port: 0). Only
// numbers: names are looked up with `resolve`.
fn parse_addr(text: str) -> (Addr, bool) {
    none: Addr
    if len(text) == 0 {
        return (none, false)
    }
    if text[0] == '[' {
        close := find(text, "]")
        if close < 0 {
            return (none, false)
        }
        a, ok := parse_ip6(text[1..close])
        rest := text[close + 1..]
        if !ok {
            return (none, false)
        }
        if len(rest) == 0 {
            return (a, true)
        }
        if rest[0] != ':' {
            return (none, false)
        }
        p, okp := parse_port(rest[1..])
        if !okp {
            return (none, false)
        }
        a.port = p
        return (a, true)
    }
    colons := count(text, ":")
    if colons == 0 {
        return parse_ip4(text)
    }
    if colons == 1 {
        at := find(text, ":")
        a, ok := parse_ip4(text[..at])
        p, okp := parse_port(text[at + 1..])
        if !ok || !okp {
            return (none, false)
        }
        a.port = p
        return (a, true)
    }
    return parse_ip6(text)
}

priv fn parse_port(s: str) -> (i64, bool) {
    if len(s) == 0 || len(s) > 5 {
        return (0, false)
    }
    for c in s {
        if !is_digit(c) {
            return (0, false)
        }
    }
    p, ok := parse_i64(s)
    return (p, ok && p <= 65535)
}

priv fn parse_ip4(s: str) -> (Addr, bool) {
    none: Addr
    parts := split(s, '.')
    if len(parts) != 4 {
        return (none, false)
    }
    a: Addr
    for i, part in parts {
        if len(part) == 0 || len(part) > 3 || (len(part) > 1 && part[0] == '0') {
            return (none, false)
        }
        for c in part {
            if !is_digit(c) {
                return (none, false)
            }
        }
        v, _ := parse_i64(part)
        if v > 255 {
            return (none, false)
        }
        a.ip[i] = u8(v)
    }
    return (a, true)
}

priv fn hex_val(c: u8) -> i64 {
    if c >= '0' && c <= '9' { return i64(c - '0') }
    if c >= 'a' && c <= 'f' { return i64(c - 'a') + 10 }
    if c >= 'A' && c <= 'F' { return i64(c - 'A') + 10 }
    return -1
}

// the 16-bit groups of one side of "::": (groups, true); the last group may be a dotted IPv4
// address when v4_last (two groups)
priv fn ip6_groups(s: str, v4_last: bool, out: *Vec[i64]) -> bool {
    if len(s) == 0 {
        return true
    }
    parts := split(s, ':')
    for i, g in parts {
        if i == len(parts) - 1 && v4_last && find(g, ".") >= 0 {
            a, ok := parse_ip4(g)
            if !ok {
                return false
            }
            out.push(i64(a.ip[0]) << 8 | i64(a.ip[1]))
            out.push(i64(a.ip[2]) << 8 | i64(a.ip[3]))
            continue
        }
        if len(g) == 0 || len(g) > 4 {
            return false
        }
        v := 0
        for c in g {
            h := hex_val(c)
            if h < 0 {
                return false
            }
            v = v * 16 + h
        }
        out.push(v)
    }
    return true
}

priv fn parse_ip6(text: str) -> (Addr, bool) {
    none: Addr
    s := text
    scope := 0
    pct := find(s, "%")
    if pct >= 0 {
        z := s[pct + 1..]
        if len(z) == 0 || len(z) > 10 {
            return (none, false)
        }
        for c in z {
            if !is_digit(c) {
                return (none, false)
            }
        }
        scope, _ = parse_i64(z)
        if scope > 0xFFFFFFFF {
            return (none, false)
        }
        s = s[..pct]
    }
    head := vec[i64]()
    tail := vec[i64]()
    dbl := find(s, "::")
    if dbl >= 0 {
        if find(s, "::", dbl + 1) >= 0 {
            return (none, false)
        }
        if !ip6_groups(s[..dbl], false, &head) || !ip6_groups(s[dbl + 2..], true, &tail) {
            return (none, false)
        }
        if head.len + tail.len > 7 {
            return (none, false)
        }
    } else {
        if !ip6_groups(s, true, &head) || head.len != 8 {
            return (none, false)
        }
    }
    a := Addr{v6: true, scope: scope}
    for i, g in head {
        a.ip[2 * i] = u8(g >> 8)
        a.ip[2 * i + 1] = u8(g)
    }
    base := 8 - tail.len
    for i, g in tail {
        a.ip[2 * (base + i)] = u8(g >> 8)
        a.ip[2 * (base + i) + 1] = u8(g)
    }
    return (a, true)
}

// the address without the port: "1.2.3.4", "::1", "::ffff:1.2.3.4", "fe80::1%2" (IPv6 as
// RFC 5952 writes it: lower case, the longest run of zero groups as "::")
fn fmt_ip(a: Addr) -> str {
    if !a.v6 {
        return fmt(a.ip[0], ".", a.ip[1], ".", a.ip[2], ".", a.ip[3])
    }
    b := vec[u8]()
    mapped := a.ip[10] == 0xff && a.ip[11] == 0xff
    for i in 0..10 {
        if a.ip[i] != 0 { mapped = false }
    }
    if mapped {
        b.extend(fmt("::ffff:", a.ip[12], ".", a.ip[13], ".", a.ip[14], ".", a.ip[15]))
    } else {
        g: [8]i64
        for i in 0..8 {
            g[i] = i64(a.ip[2 * i]) << 8 | i64(a.ip[2 * i + 1])
        }
        best := -1
        best_len := 1
        i := 0
        while i < 8 {
            if g[i] != 0 {
                i += 1
                continue
            }
            j := i
            while j < 8 && g[j] == 0 { j += 1 }
            if j - i > best_len {
                best = i
                best_len = j - i
            }
            i = j
        }
        i = 0
        while i < 8 {
            if i == best {
                b.extend("::")
                i += best_len
                continue
            }
            if i > 0 && i != best + best_len {
                b.push(':')
            }
            b.extend(hex(u64(g[i])))
            i += 1
        }
    }
    if a.scope != 0 {
        b.extend(fmt("%", a.scope))
    }
    b.items()
}

// "1.2.3.4:80", "[::1]:80"
fn fmt_addr(a: Addr) -> str {
    if a.v6 {
        return fmt("[", fmt_ip(a), "]:", a.port)
    }
    return fmt(fmt_ip(a), ":", a.port)
}

// sockaddr_in / sockaddr_in6 (the same layout on both systems; AF_INET6 differs): its length
priv fn to_sockaddr(a: Addr, sa: *[32]u8) -> i64 {
    for i in 0..32 { sa[i] = 0 }
    port := a.port & 0xFFFF
    sa[2] = u8(port >> 8)
    sa[3] = u8(port)
    if !a.v6 {
        sa[0] = 2
        for i in 0..4 { sa[4 + i] = a.ip[i] }
        return 16
    }
    sa[0] = u8(__NET_AF_INET6)
    for i in 0..16 { sa[8 + i] = a.ip[i] }
    s := a.scope
    sa[24] = u8(s)
    sa[25] = u8(s >> 8)
    sa[26] = u8(s >> 16)
    sa[27] = u8(s >> 24)
    return 28
}

priv fn from_sockaddr(sa: *[32]u8) -> (Addr, bool) {
    a: Addr
    fam := i64(sa[0]) | i64(sa[1]) << 8
    a.port = i64(sa[2]) << 8 | i64(sa[3])
    if fam == 2 {
        for i in 0..4 { a.ip[i] = sa[4 + i] }
        return (a, true)
    }
    if fam == __NET_AF_INET6 {
        a.v6 = true
        for i in 0..16 { a.ip[i] = sa[8 + i] }
        a.scope = i64(sa[24]) | i64(sa[25]) << 8 | i64(sa[26]) << 16 | i64(sa[27]) << 24
        return (a, true)
    }
    return (a, false)
}

// ---------- sockets ----------
// A TCP or UDP socket. Copies of a Socket are the same socket; Socket{} is not open (every
// call on it fails with io_error() 9).
struct Socket {
    fd: i64                 // the system's descriptor (Windows: the SOCKET)
    state: *SocketState
}

priv struct SocketState {
    open: bool
    nonblocking: bool
    v6: bool
    udp: bool
    connecting: bool        // tcp_connect_start, not yet seen connected
    failed: i64             // the error tcp_connect_check found (reported again)
}

// what poll waits for and reports
const POLL_READ = 1         // recv / recv_from / accept would not block (data, the end, an error)
const POLL_WRITE = 2        // send would not block; a connection has been made (or failed)
const POLL_ERROR = 4        // (reported only) an error is pending, or the socket is not open

// one socket for poll: `want` is POLL_READ and / or POLL_WRITE, `ready` is set by poll
struct PollItem {
    sock: Socket
    want: i64
    ready: i64
}

// the socket options of __net_option
const __NET_OPT_NODELAY = 1
const __NET_OPT_V6ONLY = 2
const __NET_OPT_REUSEADDR = 3
const __NET_OPT_BROADCAST = 4

const SHUT_READ = 0
const SHUT_WRITE = 1
const SHUT_BOTH = 2

priv fn fd_of(s: Socket) -> i64 {
    if s.state == nil || !s.state.open {
        __io_result(-9)
        return -1
    }
    return s.fd
}

// waits until fd is ready for `want`: the ready bits, 0 when the time ran out, or -errno
priv fn wait_fd(fd: i64, want: i64, timeout_ns: i64) -> i64 {
    fds := [1]i64{fd}
    w := [1]i64{want}
    r: [1]i64
    n := __net_poll(fds[..], w[..], r[..], timeout_ns)
    if n < 0 {
        return n
    }
    return r[0]
}

priv fn new_socket(fd: i64, v6: bool, udp: bool, nonblocking: bool) -> Socket {
    st := new[SocketState]()
    st.open = true
    st.v6 = v6
    st.udp = udp
    st.nonblocking = nonblocking
    return Socket{fd: fd, state: st}
}

// Closes the socket (also a copy of it); false with io_error() 9 if it was not open.
fn close(s: Socket) -> bool {
    fd := fd_of(s)
    if fd < 0 {
        return false
    }
    s.state.open = false
    return __io_result(__net_close(fd)) >= 0
}

// Makes recv, send, accept and recv_from return at once (-1 with io_error() 11) instead of
// waiting. A new socket waits (blocks), except one of tcp_connect_start.
fn set_nonblocking(s: Socket, on: bool) -> bool {
    fd := fd_of(s)
    if fd < 0 {
        return false
    }
    if __io_result(__net_set_nonblocking(fd, on)) < 0 {
        return false
    }
    s.state.nonblocking = on
    return true
}

// TCP_NODELAY: small writes go out at once instead of being gathered (for games)
fn set_nodelay(s: Socket, on: bool) -> bool {
    fd := fd_of(s)
    return fd >= 0 && __io_result(__net_option(fd, __NET_OPT_NODELAY, on)) >= 0
}

// SO_BROADCAST: a UDP socket may send to a broadcast address
fn set_broadcast(s: Socket, on: bool) -> bool {
    fd := fd_of(s)
    return fd >= 0 && __io_result(__net_option(fd, __NET_OPT_BROADCAST, on)) >= 0
}

// the address the socket is bound to (after tcp_listen / udp_bind with port 0: the port the
// system chose)
fn local_addr(s: Socket) -> (Addr, bool) {
    return sock_name(s, false)
}

// the address of the other end of a connection
fn peer_addr(s: Socket) -> (Addr, bool) {
    return sock_name(s, true)
}

priv fn sock_name(s: Socket, peer: bool) -> (Addr, bool) {
    none: Addr
    fd := fd_of(s)
    if fd < 0 {
        return (none, false)
    }
    sa: [32]u8
    r := __io_result(__net_sockname(fd, &sa[0], peer))
    if r < 0 {
        return (none, false)
    }
    return from_sockaddr(&sa)
}

// ---------- TCP ----------
// Connects to `to`, waiting at most timeout_ns nanoseconds (< 0: as long as the system tries):
// (a blocking socket, true), or (Socket{}, false) with io_error() 111 (refused), 110 (the time
// ran out), 101 / 113 (no route), ...
fn tcp_connect(to: Addr, timeout_ns: i64) -> (Socket, bool) {
    s, ok := tcp_connect_start(to)
    if !ok {
        return (Socket{}, false)
    }
    r := wait_fd(s.fd, POLL_WRITE, timeout_ns)
    if r <= 0 {
        close(s)
        __io_result(if r == 0 { -110 } else { r })
        return (Socket{}, false)
    }
    if !tcp_connect_check(s) {
        e := io_error()
        close(s)
        __io_result(-e)
        return (Socket{}, false)
    }
    set_nonblocking(s, false)
    __io_result(0)
    return (s, true)
}

// Connects to the addresses of `host` (a name or a number) one after the other until one
// accepts, all within timeout_ns (< 0: no limit of its own); the addresses come from resolve.
fn tcp_connect(host: str, port: i64, timeout_ns: i64) -> (Socket, bool) {
    end := if timeout_ns < 0 { 0x7FFF_FFFF_FFFF_FFFF } else { sat_add(clock_ns(), timeout_ns) }
    addrs, ok := resolve(host, port, if timeout_ns < 0 { DEFAULT_RESOLVE_NS } else { timeout_ns })
    if !ok {
        return (Socket{}, false)
    }
    e := 110
    for i, a in addrs {
        left := end - clock_ns()
        if left <= 0 {
            break
        }
        // a share of the time that is left, so one silent address does not use it all
        limit := if timeout_ns < 0 { -1 } else if i == len(addrs) - 1 { left } else { max(left / 2, 1) }
        s, okc := tcp_connect(a, limit)
        if okc {
            return (s, true)
        }
        e = io_error()
    }
    __io_result(-e)
    return (Socket{}, false)
}

// Starts a connection and returns at once with a non-blocking socket (for a game loop): poll
// it for POLL_WRITE, then tcp_connect_check tells how it went. (Socket{}, false) if it could
// not even be started (io_error()).
fn tcp_connect_start(to: Addr) -> (Socket, bool) {
    fd := __net_socket(to.v6, false)
    if fd < 0 {
        __io_result(fd)
        return (Socket{}, false)
    }
    __net_set_nonblocking(fd, true)
    sa: [32]u8
    n := to_sockaddr(to, &sa)
    r := __net_connect(fd, &sa[0], n)
    if r < 0 && r != -115 {
        __net_close(fd)
        __io_result(r)
        return (Socket{}, false)
    }
    s := new_socket(fd, to.v6, false, true)
    s.state.connecting = r == -115
    __io_result(0)
    return (s, true)
}

// true once the connection of tcp_connect_start is made; false with io_error() 115 while it is
// still being made, or the reason it failed (111 refused, ...). Never waits.
fn tcp_connect_check(s: Socket) -> bool {
    fd := fd_of(s)
    if fd < 0 {
        return false
    }
    if s.state.failed != 0 {
        __io_result(-s.state.failed)
        return false
    }
    if !s.state.connecting {
        __io_result(0)
        return true
    }
    r := wait_fd(fd, POLL_WRITE, 0)
    if r < 0 {
        __io_result(r)
        return false
    }
    if r == 0 {
        __io_result(-115)
        return false
    }
    e := __net_socket_error(fd)
    if e == 0 {
        // (Linux reports a failure only once: see whether there is a peer)
        sa: [32]u8
        if __net_sockname(fd, &sa[0], true) < 0 {
            e = -107
        }
    }
    if e < 0 {
        s.state.failed = -e
        __io_result(e)
        return false
    }
    s.state.connecting = false
    __io_result(0)
    return true
}

// Listens for connections at `at` (port 0: the system picks one, see local_addr). An IPv6
// socket takes only IPv6 connections (also at any6). Linux: SO_REUSEADDR, so a server can be
// started again at once on the port it had.
fn tcp_listen(at: Addr) -> (Socket, bool) {
    fd := __net_socket(at.v6, false)
    if fd < 0 {
        __io_result(fd)
        return (Socket{}, false)
    }
    if at.v6 {
        __net_option(fd, __NET_OPT_V6ONLY, true)
    }
    __net_option(fd, __NET_OPT_REUSEADDR, true)
    sa: [32]u8
    n := to_sockaddr(at, &sa)
    r := __net_bind(fd, &sa[0], n)
    if r >= 0 {
        r = __net_listen(fd, 128)
    }
    if r < 0 {
        __net_close(fd)
        __io_result(r)
        return (Socket{}, false)
    }
    __io_result(0)
    return (new_socket(fd, at.v6, false, false), true)
}

// Takes the next connection of a listening socket: (the connection, its peer's address, true).
// The connection is a blocking socket. A non-blocking listener without a waiting connection
// returns false with io_error() 11.
fn accept(s: Socket) -> (Socket, Addr, bool) {
    none: Addr
    fd := fd_of(s)
    if fd < 0 {
        return (Socket{}, none, false)
    }
    sa: [32]u8
    c := __net_accept(fd, &sa[0], s.state.nonblocking)
    if c < 0 {
        __io_result(c)
        return (Socket{}, none, false)
    }
    a, _ := from_sockaddr(&sa)
    __io_result(0)
    return (new_socket(c, a.v6, false, false), a, true)
}

// Sends what it can of data: the number of bytes taken (a blocking socket takes all), or -1
// (io_error(): 11 a non-blocking socket can take nothing now; 32 / 104 the connection is
// closed or reset). Writing to a closed connection never ends the program (no SIGPIPE).
fn send(s: Socket, data: []u8) -> i64 {
    fd := fd_of(s)
    if fd < 0 {
        return -1
    }
    if len(data) == 0 {
        __io_result(0)
        return 0
    }
    r := __net_send(fd, ptr(data), len(data))
    if r < 0 {
        __io_result(r)
        return -1
    }
    __io_result(0)
    return r
}

// Sends all of data, waiting as needed (also on a non-blocking socket): false on an error.
fn send_all(s: Socket, data: []u8) -> bool {
    fd := fd_of(s)
    if fd < 0 {
        return false
    }
    at := 0
    while at < len(data) {
        r := __net_send(fd, ptr(data[at..]), len(data) - at)
        if r == -11 {
            w := wait_fd(fd, POLL_WRITE, -1)
            if w < 0 {
                __io_result(w)
                return false
            }
            continue
        }
        if r < 0 {
            __io_result(r)
            return false
        }
        at += r
    }
    __io_result(0)
    return true
}

// Receives into buf: the number of bytes (at least 1), 0 when the other side has ended the
// connection (and everything was read), -1 on an error (io_error(); 11: a non-blocking socket
// has nothing now). A UDP socket: one datagram, cut to len(buf).
fn recv(s: Socket, buf: []u8) -> i64 {
    fd := fd_of(s)
    if fd < 0 {
        return -1
    }
    if len(buf) == 0 {
        __io_result(0)
        return 0
    }
    r := __net_recv(fd, ptr(buf), len(buf))
    if r < 0 {
        __io_result(r)
        return -1
    }
    __io_result(0)
    return r
}

// the same, waiting at most timeout_ns (< 0: no limit; also on a non-blocking socket): -1 with
// io_error() 110 when the time runs out
fn recv(s: Socket, buf: []u8, timeout_ns: i64) -> i64 {
    fd := fd_of(s)
    if fd < 0 {
        return -1
    }
    loop {
        w := wait_fd(fd, POLL_READ, timeout_ns)
        if w < 0 {
            __io_result(w)
            return -1
        }
        if w == 0 {
            __io_result(-110)
            return -1
        }
        r := recv(s, buf)
        if r >= 0 || io_error() != 11 || timeout_ns == 0 {
            return r
        }
    }
}

// Receives until buf is full: len(buf), fewer if the connection ended first, -1 on an error.
// Waits as needed, also on a non-blocking socket.
fn recv_exact(s: Socket, buf: []u8) -> i64 {
    fd := fd_of(s)
    if fd < 0 {
        return -1
    }
    at := 0
    while at < len(buf) {
        r := __net_recv(fd, ptr(buf[at..]), len(buf) - at)
        if r == -11 {
            w := wait_fd(fd, POLL_READ, -1)
            if w < 0 {
                __io_result(w)
                return -1
            }
            continue
        }
        if r < 0 {
            __io_result(r)
            return -1
        }
        if r == 0 {
            break
        }
        at += r
    }
    __io_result(0)
    return at
}

// Ends one or both directions of a connection: SHUT_WRITE tells the peer that nothing more
// comes (its recv returns 0) while this side can still receive.
fn shutdown(s: Socket, what: i64) -> bool {
    fd := fd_of(s)
    if fd < 0 {
        return false
    }
    return __io_result(__net_shutdown(fd, what)) >= 0
}

// ---------- UDP ----------
// A UDP socket bound to `at` (port 0: the system picks one). An IPv6 socket is IPv6 only.
fn udp_bind(at: Addr) -> (Socket, bool) {
    fd := __net_socket(at.v6, true)
    if fd < 0 {
        __io_result(fd)
        return (Socket{}, false)
    }
    if at.v6 {
        __net_option(fd, __NET_OPT_V6ONLY, true)
    }
    sa: [32]u8
    n := to_sockaddr(at, &sa)
    r := __net_bind(fd, &sa[0], n)
    if r < 0 {
        __net_close(fd)
        __io_result(r)
        return (Socket{}, false)
    }
    __io_result(0)
    return (new_socket(fd, at.v6, true, false), true)
}

// Sends one datagram: len(data), or -1 (io_error(): 90 too long, 22 / 97 an address of the
// other family, ...)
fn send_to(s: Socket, data: []u8, to: Addr) -> i64 {
    fd := fd_of(s)
    if fd < 0 {
        return -1
    }
    sa: [32]u8
    n := to_sockaddr(to, &sa)
    r := __net_sendto(fd, if len(data) == 0 { nil } else { ptr(data) }, len(data), &sa[0], n)
    if r < 0 {
        __io_result(r)
        return -1
    }
    __io_result(0)
    return r
}

// Receives one datagram: (its length, the sender), the datagram cut to len(buf); (-1, Addr{})
// on an error (11: a non-blocking socket has none).
fn recv_from(s: Socket, buf: []u8) -> (i64, Addr) {
    none: Addr
    fd := fd_of(s)
    if fd < 0 {
        return (-1, none)
    }
    sa: [32]u8
    r := __net_recvfrom(fd, if len(buf) == 0 { nil } else { ptr(buf) }, len(buf), &sa[0])
    if r < 0 {
        __io_result(r)
        return (-1, none)
    }
    a, _ := from_sockaddr(&sa)
    __io_result(0)
    return (r, a)
}

// the same, waiting at most timeout_ns (< 0: no limit): (-1, Addr{}) with io_error() 110 when
// the time runs out
fn recv_from(s: Socket, buf: []u8, timeout_ns: i64) -> (i64, Addr) {
    none: Addr
    fd := fd_of(s)
    if fd < 0 {
        return (-1, none)
    }
    loop {
        w := wait_fd(fd, POLL_READ, timeout_ns)
        if w < 0 {
            __io_result(w)
            return (-1, none)
        }
        if w == 0 {
            __io_result(-110)
            return (-1, none)
        }
        n, a := recv_from(s, buf)
        if n >= 0 || io_error() != 11 || timeout_ns == 0 {
            return (n, a)
        }
    }
}

// ---------- poll ----------
// Waits until at least one item is ready for what it wants, at most timeout_ns (0: only looks,
// < 0: no limit). Sets every item's `ready` and returns how many are ready (0: the time ran
// out), or -1 (io_error()). An item whose socket is not open is ready with POLL_ERROR.
// Allocates nothing for up to 64 items (call it every frame).
fn poll(items: []PollItem, timeout_ns: i64) -> i64 {
    n := len(items)
    sf: [64]i64
    sw: [64]i64
    sr: [64]i64
    fds := sf[..]
    want := sw[..]
    ready := sr[..]
    if n > 64 {
        fds = alloc[i64](n)
        want = alloc[i64](n)
        ready = alloc[i64](n)
    }
    bad := 0
    k := 0
    for i in 0..n {
        items[i].ready = 0
        st := items[i].sock.state
        if st == nil || !st.open {
            items[i].ready = POLL_ERROR
            bad += 1
            continue
        }
        fds[k] = items[i].sock.fd
        want[k] = items[i].want & (POLL_READ | POLL_WRITE)
        k += 1
    }
    r := __net_poll(fds[..k], want[..k], ready[..k], if bad > 0 { 0 } else { timeout_ns })
    if r < 0 {
        __io_result(r)
        return -1
    }
    k = 0
    count := bad
    for i in 0..n {
        if items[i].ready != 0 {
            continue
        }
        items[i].ready = ready[k]
        if ready[k] != 0 {
            count += 1
        }
        k += 1
    }
    __io_result(0)
    return count
}

// one socket: the ready bits (POLL_READ / POLL_WRITE / POLL_ERROR), 0 when the time ran out,
// -1 on an error
fn poll(s: Socket, want: i64, timeout_ns: i64) -> i64 {
    fd := fd_of(s)
    if fd < 0 {
        return -1
    }
    r := wait_fd(fd, want & (POLL_READ | POLL_WRITE), timeout_ns)
    if r < 0 {
        __io_result(r)
        return -1
    }
    __io_result(0)
    return r
}

// ---------- names ----------
// the time limit of resolve without one, and of tcp_connect(host, ...) without one
const DEFAULT_RESOLVE_NS = 10_000_000_000

// The addresses of a host name (or a number, returned as it is), all with `port`: IPv4 ones
// first. ([], false) with io_error() NET_HOST_NOT_FOUND, NET_DNS_FAILURE, 110 (no answer in
// time), ... Linux: /etc/hosts, then DNS queries to the servers of /etc/resolv.conf (see
// resolve_dns); Windows: the system's resolver (getaddrinfo).
fn resolve(host: str, port: i64) -> ([]Addr, bool) {
    return resolve(host, port, DEFAULT_RESOLVE_NS)
}

fn resolve(host: str, port: i64, timeout_ns: i64) -> ([]Addr, bool) {
    a, num := parse_addr(host)
    if num && a.port == 0 {
        return ([]Addr{with_port(a, port)}, true)
    }
    name := host
    if len(name) > 0 && name[len(name) - 1] == '.' {
        name = name[..len(name) - 1]
    }
    if len(name) == 0 || len(name) > 253 || find_any(name, " \t\r\n/:", 0) >= 0 {
        __io_result(-NET_HOST_NOT_FOUND)
        return (nil, false)
    }
    list, e := __net_resolve(host, timeout_ns)
    if e != 0 {
        __io_result(-e)
        return (nil, false)
    }
    out := order(list, port)
    if len(out) == 0 {
        __io_result(-NET_HOST_NOT_FOUND)
        return (nil, false)
    }
    __io_result(0)
    return (out, true)
}

// IPv4 first, each address once, all with port
priv fn order(list: []Addr, port: i64) -> []Addr {
    out := vec[Addr]()
    for pass in 0..2 {
        for a in list {
            if a.v6 != (pass == 1) {
                continue
            }
            b := with_port(a, port)
            if !out.contains(b) {
                out.push(b)
            }
        }
    }
    out.items()
}

// The addresses that a hosts file (the text of /etc/hosts) gives `name` (case is ignored),
// in the order of the file, with `port`.
fn hosts_lookup(text: str, name: str, port: i64) -> []Addr {
    want := to_lower(trim_right(name, "."))
    out := vec[Addr]()
    for line in lines(text) {
        hash_at := find(line, "#")
        if hash_at >= 0 {
            line = line[..hash_at]
        }
        f := fields(line)
        if len(f) < 2 {
            continue
        }
        a, ok := parse_addr(f[0])
        if !ok || a.port != 0 || find(f[0], "[") >= 0 {
            continue
        }
        for nm in f[1..] {
            if to_lower(trim_right(nm, ".")) == want {
                out.push(with_port(a, port))
                break
            }
        }
    }
    out.items()
}

// ---------- DNS ----------
// What /etc/resolv.conf says, as resolve_dns uses it.
struct DnsConfig {
    servers: []Addr         // name servers (port 53), at most 3
    search: []str           // domains tried for a name with fewer than ndots dots
    ndots: i64
    timeout_ns: i64         // how long one server is waited for, per try
    attempts: i64           // how often the list of servers is tried
}

// Reads the text of a resolv.conf: `nameserver`, `search`, `domain`, `options ndots:n
// timeout:n attempts:n`. Defaults (as glibc): server 127.0.0.1, ndots 1, timeout 5 s,
// attempts 2.
fn dns_config(text: str) -> DnsConfig {
    servers := vec[Addr]()
    search := vec[str]()
    c := DnsConfig{ndots: 1, timeout_ns: 5_000_000_000, attempts: 2}
    for line in lines(text) {
        cut := find_any(line, "#;", 0)
        if cut >= 0 {
            line = line[..cut]
        }
        f := fields(line)
        if len(f) < 2 {
            continue
        }
        if f[0] == "nameserver" {
            a, ok := parse_addr(f[1])
            if ok && a.port == 0 && servers.len < 3 {
                servers.push(with_port(a, 53))
            }
        } else if f[0] == "search" || f[0] == "domain" {
            search.clear()
            for d in f[1..] {
                search.push(trim_right(d, "."))
            }
        } else if f[0] == "options" {
            for o in f[1..] {
                colon := find(o, ":")
                if colon < 0 {
                    continue
                }
                v, ok := parse_i64(o[colon + 1..])
                if !ok || v < 0 {
                    continue
                }
                key := o[..colon]
                if key == "ndots" {
                    c.ndots = min(v, 15)
                } else if key == "timeout" {
                    c.timeout_ns = max(min(v, 30), 1) * 1_000_000_000
                } else if key == "attempts" {
                    c.attempts = max(min(v, 5), 1)
                }
            }
        }
    }
    if servers.len == 0 {
        servers.push(localhost4(53))
    }
    c.servers = servers.items()
    c.search = search.items()
    c
}

// A DNS query for `name` and the record type qtype (1: A, 28: AAAA) with the id, recursion
// desired: the message, or false if the name cannot be put in one (an empty label, a label
// over 63 bytes, more than 253 bytes in all).
fn dns_encode_query(id: i64, name: str, qtype: i64) -> ([]u8, bool) {
    n := trim_right(name, ".")
    if len(n) == 0 || len(n) > 253 || len(n) < len(name) - 1 {
        return (nil, false)
    }
    b := vec[u8]()
    for v in [6]i64{id, 0x0100, 1, 0, 0, 0} {
        b.push(u8(v >> 8))
        b.push(u8(v))
    }
    for label in split(n, '.') {
        if len(label) == 0 || len(label) > 63 {
            return (nil, false)
        }
        b.push(u8(len(label)))
        b.extend(label)
    }
    b.push(0)
    b.push(u8(qtype >> 8))
    b.push(u8(qtype))
    b.push(0)
    b.push(1)
    return (b.items(), true)
}

// What a DNS reply says, as far as resolving goes.
struct DnsReply {
    id: i64
    rcode: i64              // 0 no error, 1 format error, 2 server failure, 3 no such name, 5 refused
    truncated: bool         // the TC bit: the reply did not fit in a datagram
    name: str               // the question's name, in lower case, without the last dot
    qtype: i64              // the question's type
    addrs: []Addr           // the A / AAAA records for the name (following CNAMEs), port 0
}

// Reads a DNS reply: false if it is no reply (QR bit clear), has no single question, or is
// cut short or malformed.
fn dns_decode_reply(msg: []u8) -> (DnsReply, bool) {
    r: DnsReply
    if len(msg) < 12 || msg[2] & 0x80 == 0 {
        return (r, false)
    }
    r.id = be16(msg, 0)
    r.truncated = msg[2] & 0x02 != 0
    r.rcode = i64(msg[3] & 0x0F)
    qd := be16(msg, 4)
    an := be16(msg, 6)
    if qd != 1 {
        return (r, false)
    }
    name, at, ok := dns_name(msg, 12)
    if !ok || at + 4 > len(msg) {
        return (r, false)
    }
    r.name = name
    r.qtype = be16(msg, at)
    at += 4
    names := vec_of([]str{name})
    addrs := vec[Addr]()
    for _ in 0..an {
        owner, next, okn := dns_name(msg, at)
        if !okn || next + 10 > len(msg) {
            // a reply cut short (TC): what was read is kept
            if r.truncated { break }
            return (r, false)
        }
        rtype := be16(msg, next)
        class := be16(msg, next + 2)
        rdlen := be16(msg, next + 8)
        data := next + 10
        if data + rdlen > len(msg) {
            if r.truncated { break }
            return (r, false)
        }
        at = data + rdlen
        if class != 1 || !names.contains(owner) {
            continue
        }
        if rtype == 1 && rdlen == 4 {
            addrs.push(ipv4(i64(msg[data]), i64(msg[data + 1]), i64(msg[data + 2]), i64(msg[data + 3]), 0))
        } else if rtype == 28 && rdlen == 16 {
            a := Addr{v6: true}
            for i in 0..16 { a.ip[i] = msg[data + i] }
            addrs.push(a)
        } else if rtype == 5 {
            target, _, okt := dns_name(msg, data)
            if okt {
                names.push(target)
            }
        }
    }
    r.addrs = addrs.items()
    return (r, true)
}

priv fn be16(m: []u8, at: i64) -> i64 {
    return i64(m[at]) << 8 | i64(m[at + 1])
}

// a (possibly compressed) name at `at`: (the name in lower case, where it ends in the
// message, true)
priv fn dns_name(m: []u8, start: i64) -> (str, i64, bool) {
    out := vec[u8]()
    at := start
    end := -1
    jumps := 0
    loop {
        if at >= len(m) {
            return ("", 0, false)
        }
        l := i64(m[at])
        if l == 0 {
            if end < 0 { end = at + 1 }
            break
        }
        if l & 0xC0 == 0xC0 {
            if at + 1 >= len(m) || jumps > 64 {
                return ("", 0, false)
            }
            if end < 0 { end = at + 2 }
            at = (l & 0x3F) << 8 | i64(m[at + 1])
            jumps += 1
            continue
        }
        if l & 0xC0 != 0 || at + 1 + l > len(m) {
            return ("", 0, false)
        }
        if out.len > 0 { out.push('.') }
        out.extend(m[at + 1..at + 1 + l])
        if out.len > 255 {
            return ("", 0, false)
        }
        at += 1 + l
    }
    return (to_lower(out.items()), end, true)
}

// Resolves `host` by asking the servers of `conf` (A and AAAA at once, over UDP), with the
// search domains of conf, within timeout_ns: what resolve does on Linux after /etc/hosts.
// Each server is tried in turn for conf.timeout_ns, the list conf.attempts times; a "no such
// name" answer is final. A reply cut short (TC) is used as far as it goes (no retry over TCP).
fn resolve_dns(host: str, port: i64, conf: DnsConfig, timeout_ns: i64) -> ([]Addr, bool) {
    a, num := parse_addr(host)
    if num && a.port == 0 {
        __io_result(0)
        return ([]Addr{with_port(a, port)}, true)
    }
    end := if timeout_ns < 0 { 0x7FFF_FFFF_FFFF_FFFF } else { sat_add(clock_ns(), timeout_ns) }
    absolute := len(host) > 0 && host[len(host) - 1] == '.'
    name := trim_right(host, ".")
    tries := vec[str]()
    dots := count(name, ".")
    if !absolute && dots < conf.ndots {
        for d in conf.search { tries.push(fmt(name, ".", d)) }
    }
    tries.push(name)
    if !absolute && dots >= conf.ndots {
        for d in conf.search { tries.push(fmt(name, ".", d)) }
    }
    err := NET_HOST_NOT_FOUND
    for t in tries {
        list, e := dns_query(t, conf, end)
        if e == 0 && len(list) > 0 {
            __io_result(0)
            return (order(list, port), true)
        }
        if e != 0 && e != NET_HOST_NOT_FOUND {
            err = e
        }
        if clock_ns() >= end {
            break
        }
    }
    __io_result(-err)
    return (nil, false)
}

priv dns_counter: i64

// the addresses of one name: (A records, then AAAA, 0) or ([], error)
priv fn dns_query(name: str, conf: DnsConfig, end: i64) -> ([]Addr, i64) {
    q4, ok := dns_encode_query(0, name, 1)
    q6, _ := dns_encode_query(0, name, 28)
    if !ok {
        return (nil, NET_HOST_NOT_FOUND)
    }
    socks: [2]Socket
    defer {
        close(socks[0])
        close(socks[1])
    }
    want := to_lower(name)
    failed := false
    buf: [1500]u8
    for _ in 0..max(conf.attempts, 1) {
        for srv in conf.servers {
            k := if srv.v6 { 1 } else { 0 }
            if socks[k].state == nil {
                s, okb := udp_bind(if srv.v6 { any6(0) } else { any4(0) })
                if !okb {
                    continue
                }
                socks[k] = s
            }
            s := socks[k]
            // two fresh ids (the source port is chosen by the system at random too)
            id := i64((__net_random() ^ u64(atomic_add(&dns_counter, 1))) & 0xFFFF)
            q4[0] = u8(id >> 8)
            q4[1] = u8(id)
            q6[0] = u8((id ^ 0x5A5A) >> 8)
            q6[1] = u8(id ^ 0x5A5A)
            if send_to(s, q4, srv) < 0 || send_to(s, q6, srv) < 0 {
                continue
            }
            got4 := false
            got6 := false
            found := vec[Addr]()
            stop := min(sat_add(clock_ns(), conf.timeout_ns), end)
            server_failed := false
            while !(got4 && got6) {
                left := stop - clock_ns()
                if left <= 0 {
                    break
                }
                n, from := recv_from(s, buf[..], left)
                if n < 0 {
                    if io_error() == 110 { break }
                    continue
                }
                if from.ip != srv.ip || from.port != srv.port {
                    continue
                }
                r, okr := dns_decode_reply(buf[..n])
                if !okr || r.name != want {
                    continue
                }
                is4 := r.id == id && r.qtype == 1 && !got4
                is6 := r.id == (id ^ 0x5A5A) && r.qtype == 28 && !got6
                if !is4 && !is6 {
                    continue
                }
                if r.rcode == 3 {
                    return (nil, NET_HOST_NOT_FOUND)
                }
                if r.rcode != 0 {
                    server_failed = true
                    break
                }
                if is4 { got4 = true } else { got6 = true }
                found.extend(r.addrs)
            }
            if got4 && got6 || found.len > 0 {
                if found.len == 0 {
                    return (nil, NET_HOST_NOT_FOUND)
                }
                return (found.items(), 0)
            }
            if server_failed {
                failed = true
            }
            if clock_ns() >= end {
                return (nil, if failed { NET_DNS_FAILURE } else { 110 })
            }
        }
    }
    return (nil, if failed { NET_DNS_FAILURE } else { 110 })
}

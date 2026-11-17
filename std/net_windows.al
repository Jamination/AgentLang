// std.net, Windows layer: ws2_32.dll (WSAStartup is called on the first socket or lookup).
// Loaded by `use std.net` for --target windows. Sockets are made with
// WSA_FLAG_NO_HANDLE_INHERIT (accepted connections take it from the listener), so programs
// started with std.os never inherit them, also not from another thread. Winsock
// error codes are mapped to the Linux errno of the same meaning (wsa_errno). Readiness is
// waited for with select(), which reports a failed connection in its exception set (WSAPoll
// of Windows 10 before 2004 did not). Every function returns -errno on failure.

priv extern "ws2_32.dll" fn WSAStartup(version: u16, data: *u8) -> i32
priv extern "ws2_32.dll" fn WSAGetLastError() -> i32
priv extern "ws2_32.dll" fn WSASocketW(af: i32, kind: i32, proto: i32, info: i64, group: u32, flags: u32) -> i64
priv extern "ws2_32.dll" fn closesocket(s: i64) -> i32
priv extern "ws2_32.dll" fn connect(s: i64, sa: *u8, n: i32) -> i32
priv extern "ws2_32.dll" fn bind(s: i64, sa: *u8, n: i32) -> i32
priv extern "ws2_32.dll" fn listen(s: i64, backlog: i32) -> i32
priv extern "ws2_32.dll" fn accept(s: i64, sa: *u8, n: *i32) -> i64
priv extern "ws2_32.dll" fn send(s: i64, p: *u8, n: i32, flags: i32) -> i32
priv extern "ws2_32.dll" fn recv(s: i64, p: *u8, n: i32, flags: i32) -> i32
priv extern "ws2_32.dll" fn sendto(s: i64, p: *u8, n: i32, flags: i32, sa: *u8, salen: i32) -> i32
priv extern "ws2_32.dll" fn recvfrom(s: i64, p: *u8, n: i32, flags: i32, sa: *u8, salen: *i32) -> i32
priv extern "ws2_32.dll" fn shutdown(s: i64, how: i32) -> i32
priv extern "ws2_32.dll" fn ioctlsocket(s: i64, cmd: u32, arg: *u32) -> i32
priv extern "ws2_32.dll" fn setsockopt(s: i64, level: i32, name: i32, v: *i32, n: i32) -> i32
priv extern "ws2_32.dll" fn getsockopt(s: i64, level: i32, name: i32, v: *i32, n: *i32) -> i32
priv extern "ws2_32.dll" fn getsockname(s: i64, sa: *u8, n: *i32) -> i32
priv extern "ws2_32.dll" fn getpeername(s: i64, sa: *u8, n: *i32) -> i32
priv extern "ws2_32.dll" fn select(nfds: i32, r: *i64, w: *i64, e: *i64, tv: *i32) -> i32
priv extern "ws2_32.dll" fn WSAIoctl(s: i64, code: u32, inb: *u32, inlen: u32, outb: *u8, outlen: u32, got: *u32, ov: i64, done: i64) -> i32
priv extern "ws2_32.dll" fn getaddrinfo(node: *u8, service: *u8, hints: *i32, res: *i64) -> i32
priv extern "ws2_32.dll" fn freeaddrinfo(ai: i64)
priv extern "kernel32.dll" fn SetHandleInformation(h: i64, mask: u32, flags: u32) -> i32
priv extern "kernel32.dll" fn Sleep(ms: u32)

const __NET_AF_INET6 = 23

priv const INVALID_SOCKET = -1
priv const FIONBIO: u32 = 0x8004667E

// ---------- start-up and errors ----------
// 0: not started, 1: being started, 2: started, 3: failed (wsa_error holds why)
priv wsa_state: i64
priv wsa_error: i64

// WSAStartup once per process: 0 or -errno
priv fn wsa() -> i64 {
    loop {
        s := atomic_load(&wsa_state)
        if s == 2 {
            return 0
        }
        if s == 3 {
            return -wsa_error
        }
        if s == 0 {
            _, ok := atomic_cas(&wsa_state, 0, 1)
            if ok {
                data: [512]u8
                r := WSAStartup(0x0202, &data[0])
                if r != 0 {
                    wsa_error = wsa_errno(i64(r))
                    atomic_store(&wsa_state, 3)
                } else {
                    atomic_store(&wsa_state, 2)
                }
            }
            continue
        }
        Sleep(0)
    }
}

// the Linux errno of a Winsock error code (0x10000 + the code if there is none)
priv fn wsa_errno(e: i64) -> i64 {
    return match e {
        6 => 9                       // invalid handle
        8 => 12                      // not enough memory
        87 => 22                     // invalid parameter
        995 => 4                     // operation aborted
        10004 => 4                   // WSAEINTR
        10009 => 9                   // WSAEBADF
        10013 => 13                  // WSAEACCES
        10014 => 14                  // WSAEFAULT
        10022 => 22                  // WSAEINVAL
        10024 => 24                  // WSAEMFILE
        10035 => 11                  // WSAEWOULDBLOCK
        10036 => 115                 // WSAEINPROGRESS
        10037 => 114                 // WSAEALREADY
        10038 => 88                  // WSAENOTSOCK
        10039 => 89                  // WSAEDESTADDRREQ
        10040 => 90                  // WSAEMSGSIZE
        10041 => 91                  // WSAEPROTOTYPE
        10042 => 92                  // WSAENOPROTOOPT
        10043 => 93                  // WSAEPROTONOSUPPORT
        10044 => 94                  // WSAESOCKTNOSUPPORT
        10045 => 95                  // WSAEOPNOTSUPP
        10046 => 96                  // WSAEPFNOSUPPORT
        10047 => 97                  // WSAEAFNOSUPPORT
        10048 => 98                  // WSAEADDRINUSE
        10049 => 99                  // WSAEADDRNOTAVAIL
        10050 => 100                 // WSAENETDOWN
        10051 => 101                 // WSAENETUNREACH
        10052 => 102                 // WSAENETRESET
        10053 => 103                 // WSAECONNABORTED
        10054 => 104                 // WSAECONNRESET
        10055 => 105                 // WSAENOBUFS
        10056 => 106                 // WSAEISCONN
        10057 => 107                 // WSAENOTCONN
        10058 => 108                 // WSAESHUTDOWN
        10060 => 110                 // WSAETIMEDOUT
        10061 => 111                 // WSAECONNREFUSED
        10063 => 36                  // WSAENAMETOOLONG
        10064 => 112                 // WSAEHOSTDOWN
        10065 => 113                 // WSAEHOSTUNREACH
        11001, 11004 => NET_HOST_NOT_FOUND   // WSAHOST_NOT_FOUND, WSANO_DATA
        11002 => NET_DNS_TRY_AGAIN   // WSATRY_AGAIN
        11003 => NET_DNS_FAILURE     // WSANO_RECOVERY
        _ => 0x10000 + e
    }
}

priv fn last() -> i64 {
    return -wsa_errno(i64(WSAGetLastError()))
}

// ---------- sockets ----------
fn __net_socket(v6: bool, udp: bool) -> i64 {
    e := wsa()
    if e < 0 {
        return e
    }
    // WSA_FLAG_OVERLAPPED (as socket() makes them) | WSA_FLAG_NO_HANDLE_INHERIT
    s := WSASocketW(if v6 { 23 } else { 2 }, if udp { 2 } else { 1 }, if udp { 17 } else { 6 }, 0, 0, 0x81)
    if s == INVALID_SOCKET {
        return last()
    }
    if udp {
        // SIO_UDP_CONNRESET off: an ICMP "port unreachable" for an earlier send_to would
        // otherwise fail the next recv_from with WSAECONNRESET (Linux reports nothing)
        off: u32 = 0
        got: u32 = 0
        WSAIoctl(s, 0x9800000C, &off, 4, nil, 0, &got, 0, 0)
    }
    return s
}

fn __net_close(fd: i64) -> i64 {
    if closesocket(fd) != 0 {
        return last()
    }
    return 0
}

fn __net_set_nonblocking(fd: i64, on: bool) -> i64 {
    v: u32 = if on { 1 } else { 0 }
    if ioctlsocket(fd, FIONBIO, &v) != 0 {
        return last()
    }
    return 0
}

fn __net_option(fd: i64, which: i64, on: bool) -> i64 {
    v: i32 = if on { 1 } else { 0 }
    r := match which {
        __NET_OPT_NODELAY => setsockopt(fd, 6, 1, &v, 4)            // IPPROTO_TCP, TCP_NODELAY
        __NET_OPT_V6ONLY => setsockopt(fd, 41, 27, &v, 4)           // IPPROTO_IPV6, IPV6_V6ONLY
        __NET_OPT_BROADCAST => setsockopt(fd, 0xFFFF, 0x20, &v, 4)  // SOL_SOCKET, SO_BROADCAST
        // (SO_REUSEADDR on Windows lets another socket take a port in use: left alone; Windows
        // binds a port whose old connections are in TIME_WAIT anyway)
        _ => 0
    }
    if r != 0 {
        return last()
    }
    return 0
}

fn __net_socket_error(fd: i64) -> i64 {
    v: i32 = 0
    n: i32 = 4
    if getsockopt(fd, 0xFFFF, 0x1007, &v, &n) != 0 {                 // SOL_SOCKET, SO_ERROR
        return last()
    }
    if v == 0 {
        return 0
    }
    return -wsa_errno(i64(v))
}

fn __net_connect(fd: i64, sa: *u8, n: i64) -> i64 {
    if connect(fd, sa, i32(n)) != 0 {
        e := WSAGetLastError()
        if e == 10035 || e == 10036 {
            return -115
        }
        return -wsa_errno(i64(e))
    }
    return 0
}

fn __net_bind(fd: i64, sa: *u8, n: i64) -> i64 {
    if bind(fd, sa, i32(n)) != 0 {
        return last()
    }
    return 0
}

fn __net_listen(fd: i64, backlog: i64) -> i64 {
    if listen(fd, i32(backlog)) != 0 {
        return last()
    }
    return 0
}

// A new connection, blocking. It takes the listener's attributes: not inheritable (the
// connections of a WSA_FLAG_NO_HANDLE_INHERIT socket are not: checked with
// GetHandleInformation), and its mode, which is reset here. (SetHandleInformation once more
// in case a layered service provider made it inheritable.)
fn __net_accept(fd: i64, sa: *u8, nonblocking: bool) -> i64 {
    n: i32 = 32
    s := accept(fd, sa, &n)
    if s == INVALID_SOCKET {
        return last()
    }
    SetHandleInformation(s, 1, 0)                        // HANDLE_FLAG_INHERIT off
    off: u32 = 0
    ioctlsocket(s, FIONBIO, &off)
    return s
}

// (at most 1 GiB per call: the lengths are i32)
fn __net_send(fd: i64, p: *u8, n: i64) -> i64 {
    r := send(fd, p, i32(min(n, 1 << 30)), 0)
    if r < 0 {
        return last()
    }
    return i64(r)
}

fn __net_recv(fd: i64, p: *u8, n: i64) -> i64 {
    r := recv(fd, p, i32(min(n, 1 << 30)), 0)
    if r < 0 {
        e := WSAGetLastError()
        if e == 10040 {
            return n                                     // a datagram cut short, as on Linux
        }
        return -wsa_errno(i64(e))
    }
    return i64(r)
}

fn __net_sendto(fd: i64, p: *u8, n: i64, sa: *u8, salen: i64) -> i64 {
    r := sendto(fd, p, i32(min(n, 1 << 30)), 0, sa, i32(salen))
    if r < 0 {
        return last()
    }
    return i64(r)
}

fn __net_recvfrom(fd: i64, p: *u8, n: i64, sa: *u8) -> i64 {
    len: i32 = 32
    r := recvfrom(fd, p, i32(min(n, 1 << 30)), 0, sa, &len)
    if r < 0 {
        e := WSAGetLastError()
        if e == 10040 {
            return n
        }
        return -wsa_errno(i64(e))
    }
    return i64(r)
}

fn __net_shutdown(fd: i64, how: i64) -> i64 {
    if shutdown(fd, i32(how)) != 0 {
        return last()
    }
    return 0
}

fn __net_sockname(fd: i64, sa: *u8, peer: bool) -> i64 {
    n: i32 = 32
    r := if peer { getpeername(fd, sa, &n) } else { getsockname(fd, sa, &n) }
    if r != 0 {
        return last()
    }
    return i64(n)
}

// select over the sockets (an fd_set is a count and an array of SOCKETs, of any length):
// reading in the read set, writing in the write and the exception set (a failed connection)
fn __net_poll(fds: []i64, want: []i64, ready: []i64, ns: i64) -> i64 {
    n := len(fds)
    sr: [65]i64
    sw: [65]i64
    se: [65]i64
    rs := sr[..]
    ws := sw[..]
    es := se[..]
    if n > 64 {
        rs = alloc[i64](n + 1)
        ws = alloc[i64](n + 1)
        es = alloc[i64](n + 1)
    }
    nr := 0
    nw := 0
    for i in 0..n {
        ready[i] = 0
        if want[i] & POLL_READ != 0 {
            nr += 1
            rs[nr] = fds[i]
        }
        if want[i] & POLL_WRITE != 0 {
            nw += 1
            ws[nw] = fds[i]
            es[nw] = fds[i]
        }
    }
    if nr == 0 && nw == 0 {
        // nothing to wait for: only the time passes
        if ns != 0 {
            __os_sleep_ns(if ns < 0 { 0x7FFF_FFFF_FFFF_FFFF } else { ns })
        }
        return 0
    }
    end := if ns < 0 { 0 } else { sat_add(clock_ns(), ns) }
    r := 0
    loop {
        rs[0] = nr
        ws[0] = nw
        es[0] = nw
        tv: [2]i32
        tp: *i32 = nil
        if ns >= 0 {
            left := max(end - clock_ns(), 0)
            us := (left + 999) / 1000
            tv[0] = i32(min(us / 1_000_000, 0x7FFFFFFF))
            tv[1] = i32(us % 1_000_000)
            tp = &tv[0]
        }
        // (rebuilt: select leaves only the ready sockets in each set)
        k := 0
        kw := 0
        for i in 0..n {
            if want[i] & POLL_READ != 0 {
                k += 1
                rs[k] = fds[i]
            }
            if want[i] & POLL_WRITE != 0 {
                kw += 1
                ws[kw] = fds[i]
                es[kw] = fds[i]
            }
        }
        r = i64(select(0,if nr > 0 { &rs[0] } else { nil }, if nw > 0 { &ws[0] } else { nil }, if nw > 0 { &es[0] } else { nil }, tp))
        if r < 0 {
            e := WSAGetLastError()
            if e == 10004 {
                continue
            }
            return -wsa_errno(i64(e))
        }
        break
    }
    if r == 0 {
        return 0
    }
    count := 0
    for i in 0..n {
        out := 0
        if want[i] & POLL_READ != 0 && in_set(rs, fds[i]) { out |= POLL_READ }
        if want[i] & POLL_WRITE != 0 {
            if in_set(ws, fds[i]) { out |= POLL_WRITE }
            if in_set(es, fds[i]) { out |= POLL_WRITE | POLL_ERROR }
        }
        ready[i] = out
        if out != 0 { count += 1 }
    }
    return count
}

priv fn in_set(set: []i64, s: i64) -> bool {
    c := set[0] & 0xFFFFFFFF
    for i in 1..c + 1 {
        if set[i] == s {
            return true
        }
    }
    return false
}

priv dns_seed: i64

fn __net_random() -> u64 {
    x: i64 = 0
    return hash((clock_ns(), atomic_add(&dns_seed, 1), cast[i64](&x)))
}

// the system's resolver: getaddrinfo (TCP addresses, any family)
fn __net_resolve(host: str, timeout_ns: i64) -> ([]Addr, i64) {
    e := wsa()
    if e < 0 {
        return (nil, -e)
    }
    // struct addrinfo hints: flags, family AF_UNSPEC, SOCK_STREAM, IPPROTO_TCP, rest 0
    hints: [12]i32
    hints[2] = 1
    hints[3] = 6
    res: i64 = 0
    r := getaddrinfo(cstr(host), nil, &hints[0], &res)
    if r != 0 {
        return (nil, wsa_errno(i64(r)))
    }
    out := vec[Addr]()
    p := res
    while p != 0 {
        // ai_addr at 32, ai_next at 40
        ai := mkslice[i64](cast[*i64](p), 6)
        if ai[4] != 0 {
            sa: [32]u8
            fam := i64(*cast[*u16](ai[4]))
            memcopy(&sa[0], cast[*u8](ai[4]), if fam == 23 { 28 } else { 16 })
            a, ok := from_sockaddr_win(&sa)
            if ok {
                out.push(a)
            }
        }
        p = ai[5]
    }
    freeaddrinfo(res)
    return (out.items(), 0)
}

priv fn from_sockaddr_win(sa: *[32]u8) -> (Addr, bool) {
    a: Addr
    fam := i64(sa[0])
    if fam == 2 {
        for i in 0..4 { a.ip[i] = sa[4 + i] }
        return (a, true)
    }
    if fam == 23 {
        a.v6 = true
        for i in 0..16 { a.ip[i] = sa[8 + i] }
        a.scope = i64(sa[24]) | i64(sa[25]) << 8 | i64(sa[26]) << 16 | i64(sa[27]) << 24
        return (a, true)
    }
    return (a, false)
}

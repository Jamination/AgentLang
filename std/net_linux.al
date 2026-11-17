// std.net, Linux layer: raw system calls, no libc (a program stays static). Loaded by
// `use std.net`. Sockets are made with SOCK_CLOEXEC (accept4 too), so programs started with
// std.os never inherit them; send uses MSG_NOSIGNAL, so writing to a closed connection is an
// error (32, broken pipe) and never SIGPIPE. Every function returns -errno on failure.

const __NET_AF_INET6 = 10

priv const SOCK_CLOEXEC = 0o2000000
priv const MSG_NOSIGNAL = 0x4000

// a socket of the family (IPv6 or IPv4) and kind (UDP or TCP), close-on-exec, blocking
fn __net_socket(v6: bool, udp: bool) -> i64 {
    return syscall(41, if v6 { 10 } else { 2 }, (if udp { 2 } else { 1 }) | SOCK_CLOEXEC, 0)
}

fn __net_close(fd: i64) -> i64 {
    return syscall(3, fd)
}

fn __net_set_nonblocking(fd: i64, on: bool) -> i64 {
    fl := syscall(72, fd, 3, 0)                 // F_GETFL
    if fl < 0 {
        return fl
    }
    fl = if on { fl | 0o4000 } else { fl & ~0o4000 }
    return syscall(72, fd, 4, fl)               // F_SETFL
}

fn __net_option(fd: i64, which: i64, on: bool) -> i64 {
    v: i32 = if on { 1 } else { 0 }
    return match which {
        __NET_OPT_NODELAY => syscall(54, fd, 6, 1, &v, 4)        // IPPROTO_TCP, TCP_NODELAY
        __NET_OPT_V6ONLY => syscall(54, fd, 41, 26, &v, 4)       // IPPROTO_IPV6, IPV6_V6ONLY
        __NET_OPT_REUSEADDR => syscall(54, fd, 1, 2, &v, 4)      // SOL_SOCKET, SO_REUSEADDR
        __NET_OPT_BROADCAST => syscall(54, fd, 1, 6, &v, 4)      // SOL_SOCKET, SO_BROADCAST
        _ => -22
    }
}

// the pending error of the socket (SO_ERROR), as -errno; 0 if none
fn __net_socket_error(fd: i64) -> i64 {
    v: i32 = 0
    n: i32 = 4
    r := syscall(55, fd, 1, 4, &v, &n)
    if r < 0 {
        return r
    }
    return -i64(v)
}

// 0, or -115 (EINPROGRESS) for a non-blocking socket
fn __net_connect(fd: i64, sa: *u8, n: i64) -> i64 {
    r := syscall(42, fd, sa, n)
    if r == -4 {
        // interrupted: the connection goes on being made
        return -115
    }
    return r
}

fn __net_bind(fd: i64, sa: *u8, n: i64) -> i64 {
    return syscall(49, fd, sa, n)
}

fn __net_listen(fd: i64, backlog: i64) -> i64 {
    return syscall(50, fd, backlog)
}

// a new connection (close-on-exec, blocking) with the peer's address in sa (32 bytes)
fn __net_accept(fd: i64, sa: *u8, nonblocking: bool) -> i64 {
    loop {
        n: i32 = 32
        r := syscall(288, fd, sa, &n, SOCK_CLOEXEC)
        if r != -4 {
            return r
        }
    }
}

fn __net_send(fd: i64, p: *u8, n: i64) -> i64 {
    loop {
        r := syscall(44, fd, p, n, MSG_NOSIGNAL, 0, 0)
        if r != -4 {
            return r
        }
    }
}

fn __net_recv(fd: i64, p: *u8, n: i64) -> i64 {
    loop {
        r := syscall(45, fd, p, n, 0, 0, 0)
        if r != -4 {
            return r
        }
    }
}

fn __net_sendto(fd: i64, p: *u8, n: i64, sa: *u8, salen: i64) -> i64 {
    loop {
        r := syscall(44, fd, p, n, MSG_NOSIGNAL, sa, salen)
        if r != -4 {
            return r
        }
    }
}

// one datagram (cut to n bytes) and the sender's address in sa (32 bytes)
fn __net_recvfrom(fd: i64, p: *u8, n: i64, sa: *u8) -> i64 {
    loop {
        len: i32 = 32
        r := syscall(45, fd, p, n, 0, sa, &len)
        if r != -4 {
            return r
        }
    }
}

fn __net_shutdown(fd: i64, how: i64) -> i64 {
    return syscall(48, fd, how)
}

// the local (or the peer's) address into sa (32 bytes): its length or -errno
fn __net_sockname(fd: i64, sa: *u8, peer: bool) -> i64 {
    n: i32 = 32
    r := syscall(if peer { 52 } else { 51 }, fd, sa, &n)
    if r < 0 {
        return r
    }
    return i64(n)
}

// ppoll over the descriptors: ready[i] gets POLL_READ / POLL_WRITE / POLL_ERROR; the number of
// ready ones, 0 when the time ran out (ns < 0: no limit), or -errno
fn __net_poll(fds: []i64, want: []i64, ready: []i64, ns: i64) -> i64 {
    n := len(fds)
    // struct pollfd { int fd; short events; short revents }: one i64 each
    small: [64]i64
    pf := small[..]
    if n > 64 {
        pf = alloc[i64](n)
    }
    for i in 0..n {
        ev := 0
        if want[i] & POLL_READ != 0 { ev |= 0x2001 }        // POLLIN | POLLRDHUP
        if want[i] & POLL_WRITE != 0 { ev |= 4 }            // POLLOUT
        pf[i] = (fds[i] & 0xFFFFFFFF) | ev << 32
    }
    end := if ns < 0 { 0 } else { sat_add(clock_ns(), ns) }
    r := 0
    loop {
        ts: [2]i64
        tp: *i64 = nil
        if ns >= 0 {
            left := max(end - clock_ns(), 0)
            ts[0] = left / 1_000_000_000
            ts[1] = left % 1_000_000_000
            tp = &ts[0]
        }
        r = syscall(271, ptr(pf), n, tp, 0, 8)
        if r != -4 {
            break
        }
    }
    if r < 0 {
        return r
    }
    count := 0
    for i in 0..n {
        rev := (pf[i] >> 48) & 0xFFFF
        out := 0
        if rev & 0x38 != 0 {                                 // POLLERR | POLLHUP | POLLNVAL
            out = if rev & 0x28 != 0 { POLL_ERROR } else { 0 }
            out |= want[i] & (POLL_READ | POLL_WRITE)
        }
        if rev & 0x2001 != 0 { out |= POLL_READ }
        if rev & 4 != 0 { out |= POLL_WRITE }
        ready[i] = out & (want[i] | POLL_ERROR)
        if ready[i] != 0 { count += 1 }
    }
    return count
}

// 64 random bits (getrandom; the clock if that fails)
fn __net_random() -> u64 {
    v: u64 = 0
    if syscall(318, &v, 8, 1) != 8 {
        v = hash(clock_ns())
    }
    return v
}

// the addresses of a name: /etc/hosts, "localhost", then DNS with /etc/resolv.conf;
// (addresses, 0) or (nil, error number)
fn __net_resolve(host: str, timeout_ns: i64) -> ([]Addr, i64) {
    name := to_lower(trim_right(host, "."))
    hosts, ok := read_file("/etc/hosts")
    if ok {
        list := hosts_lookup(hosts, name, 0)
        if len(list) > 0 {
            return (list, 0)
        }
    }
    if name == "localhost" || ends_with(name, ".localhost") {
        return ([]Addr{localhost4(0), localhost6(0)}, 0)
    }
    text, _ := read_file("/etc/resolv.conf")
    list, okd := resolve_dns(host, 0, dns_config(text), timeout_ns)
    if !okd {
        return (nil, io_error())
    }
    return (list, 0)
}

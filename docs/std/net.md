# std.net: TCP, UDP, polling, names, HTTP

`use std.net`. Source: `std/net.al`, with `std/net_linux.al` and `std/net_windows.al`. Sockets
for games and tools: TCP connections and servers, UDP datagrams, IPv4 and IPv6, a poll over
several sockets for a game loop, blocking calls with time limits for tools, name resolution,
and a small HTTP/1.1 client. Linux: raw system calls, no libc, so a program using this module
stays a static executable (names are resolved by the module itself: [Names](#names)).
Windows: `ws2_32.dll`; the differences are listed under [Windows](#windows).

**Errors** are reported as by the file functions: the result says so (`false`, `-1`) and
`io_error()` is a Linux error number, the same on both systems, with `error_text(io_error())`
its text. The common ones have names:

| Constant | Number | `error_text` | When |
|---|---|---|---|
| `NET_WOULD_BLOCK` | 11 | resource temporarily unavailable | a non-blocking socket has nothing to give or take now |
| `NET_RESET` | 104 | connection reset by peer | the other side reset the connection |
| `NET_TIMED_OUT` | 110 | connection timed out | a time limit ran out (connect, `recv(s, buf, limit)`, names) |
| `NET_REFUSED` | 111 | connection refused | nothing listens at that address |
| `NET_IN_PROGRESS` | 115 | operation now in progress | a connection of `tcp_connect_start` is still being made |
| `NET_HOST_NOT_FOUND` | 0x20001 | host not found | the name does not exist or has no address |
| `NET_DNS_FAILURE` | 0x20002 | name server failure | the name servers failed or answered nonsense |
| `NET_DNS_TRY_AGAIN` | 0x20003 | temporary failure in name resolution | (Windows) the system's resolver could not answer now |

Others: 32 `broken pipe` (writing to a connection the peer has closed), 98 `address already
in use`, 99 `cannot assign requested address`, 101 `network is unreachable`, 113 `no route to
host`, 9 `bad file descriptor` (a socket that is not open). No function panics.

## Addresses

| Declaration | Description |
|-------------|-------------|
| `struct Addr { ip: [16]u8, v6: bool, port: i64, scope: i64 }` | An IPv4 (the first 4 bytes of `ip`) or IPv6 address with a port. `scope` is the interface number of an IPv6 link-local address (`fe80::1%2`). `==` compares all of it. |
| `ipv4(a, b, c, d: i64, port: i64) -> Addr` | `ipv4(192, 168, 1, 10, 8080)` |
| `localhost4(port)`, `localhost6(port)`, `any4(port)`, `any6(port)` | `127.0.0.1`, `::1`, `0.0.0.0`, `::` (the last two: every interface, for listening) |
| `with_port(a: Addr, port: i64) -> Addr` | The same address with another port. |
| `parse_addr(text: str) -> (Addr, bool)` | Reads `1.2.3.4`, `1.2.3.4:80`, `::1`, `fe80::1%2`, `[::1]:80`, `[::1]` (port 0 when none is given). Numbers only, strictly (no leading zeros in IPv4, no spaces); names go through `resolve`. |
| `fmt_ip(a: Addr) -> str` | `1.2.3.4`, `2001:db8::1` (IPv6 as RFC 5952 writes it: lower case, the longest run of zero groups as `::`, an IPv4-mapped address as `::ffff:1.2.3.4`). |
| `fmt_addr(a: Addr) -> str` | `1.2.3.4:80`, `[2001:db8::1]:80`. (`print(a)` shows the struct.) |

## TCP

| Declaration | Description |
|-------------|-------------|
| `struct Socket` | A TCP or UDP socket. Copies are the same socket; `Socket{}` is not open. |
| `tcp_connect(to: Addr, timeout_ns: i64) -> (Socket, bool)` | Connects, waiting at most `timeout_ns` (`< 0`: as long as the system tries). A blocking socket, or `(Socket{}, false)` with `io_error()` 111, 110, 101, ... |
| `tcp_connect(host: str, port: i64, timeout_ns: i64) -> (Socket, bool)` | Resolves `host` (a name or a number) and tries its addresses in turn, IPv4 first, all within `timeout_ns` (each but the last gets half the time left). |
| `tcp_connect_start(to: Addr) -> (Socket, bool)` | Starts a connection and returns at once with a non-blocking socket; poll it for `POLL_WRITE`, then ask `tcp_connect_check`. `false` only if no socket can be made. |
| `tcp_connect_check(s: Socket) -> bool` | `true` once connected; `false` with `io_error()` 115 while still connecting, or the reason it failed (asked again, the same reason). Never waits. |
| `tcp_listen(at: Addr) -> (Socket, bool)` | A listening socket (backlog 128). Port 0: the system picks one, `local_addr` tells which. |
| `accept(s: Socket) -> (Socket, Addr, bool)` | The next connection and its peer's address; waits unless the listener is non-blocking (then `false` with 11 when none is waiting). The connection is blocking. |
| `send(s: Socket, data: []u8) -> i64` | Sends what the socket takes: the number of bytes (a blocking socket takes all), or -1 (11: a non-blocking socket is full). |
| `send_all(s: Socket, data: []u8) -> bool` | Sends everything, waiting as needed, also on a non-blocking socket. |
| `recv(s: Socket, buf: []u8) -> i64` | The bytes received (at least 1), **0 when the peer has ended the connection** and everything was read, -1 on an error (11: a non-blocking socket has nothing). |
| `recv(s: Socket, buf: []u8, timeout_ns: i64) -> i64` | The same, waiting at most `timeout_ns` (also on a non-blocking socket): -1 with 110 when the time runs out. |
| `recv_exact(s: Socket, buf: []u8) -> i64` | Receives until `buf` is full: `len(buf)`, fewer if the connection ended first, -1 on an error. |
| `shutdown(s: Socket, what: i64) -> bool` | `SHUT_WRITE`: the peer's `recv` returns 0 (end of the request) while this side still receives; `SHUT_READ`, `SHUT_BOTH`. |
| `close(s: Socket) -> bool` | Closes it (every copy). `false` with 9 if it was not open. |
| `local_addr(s)`, `peer_addr(s) -> (Addr, bool)` | The address of this end / the other end. |
| `set_nonblocking(s: Socket, on: bool) -> bool` | `recv`, `send`, `accept`, `recv_from` return at once with 11 instead of waiting. |
| `set_nodelay(s: Socket, on: bool) -> bool` | `TCP_NODELAY`: small messages go out at once instead of being gathered (games). |

- A stream has no messages: one `send` may arrive in several `recv`s and several in one.
  Frame the data (a length before each message and `recv_exact`, or lines).
- **Closed connections.** Writing to a connection the peer has closed fails (32 `broken pipe`,
  104, or 103 on Windows) and never ends the program: on Linux no SIGPIPE is raised. The
  first write after the peer closed may still succeed; the error comes with a later one.
- An IPv6 socket is IPv6 only (`IPV6_V6ONLY`, the same on both systems): a server for both
  families listens twice, on `any4(port)` and `any6(port)`.
- Linux listeners have `SO_REUSEADDR`, so a server can start again at once on its port while
  old connections linger in TIME_WAIT (Windows allows that without the option).
- Sockets are never inherited by programs started with [std.os](os.md) (Linux: close-on-exec;
  Windows: not inheritable), also when another thread starts one meanwhile.
- A socket may be used by two threads at once only for different directions (one sends, one
  receives); `close` must not race with other calls on it.

```
use std.net

fn main() -> i64 {
    l, _ := tcp_listen(localhost4(0))
    at, _ := local_addr(l)
    c, ok := tcp_connect(at, 5_000_000_000)              // 5 s
    if !ok {
        eprint(fmt("cannot connect: ", error_text(io_error())))
        return 1
    }
    s, peer, _ := accept(l)
    send_all(c, "ping")
    shutdown(c, SHUT_WRITE)
    buf := alloc[u8](100)
    n := recv_exact(s, buf)                               // 4: the stream ended after "ping"
    print(fmt_ip(peer), buf[..n], recv(s, buf))           // 127.0.0.1 ping 0
    close(c)
    close(s)
    close(l)
    0
}
```

## UDP

| Declaration | Description |
|-------------|-------------|
| `udp_bind(at: Addr) -> (Socket, bool)` | A UDP socket at `at` (port 0: any). Send from `any4(0)` / `any6(0)`, serve at a known port. |
| `send_to(s: Socket, data: []u8, to: Addr) -> i64` | Sends one datagram: `len(data)` or -1 (90: too long). |
| `recv_from(s: Socket, buf: []u8) -> (i64, Addr)` | One datagram and its sender: `(length, address)`, the datagram **cut to `len(buf)`** (the rest is lost); `(-1, Addr{})` on an error (11: none waiting on a non-blocking socket). |
| `recv_from(s: Socket, buf: []u8, timeout_ns: i64) -> (i64, Addr)` | The same, waiting at most `timeout_ns`: 110 when the time runs out. |
| `set_broadcast(s: Socket, on: bool) -> bool` | Allows sending to a broadcast address (`ipv4(255, 255, 255, 255, port)`). |

- Datagrams may be lost, duplicated or reordered; a game numbers them. Up to 65507 bytes
  (IPv4) fit in one, but keep them under about 1200 bytes across the internet.
- A datagram to a port where nobody listens is lost silently; no later call reports it (on
  Windows the module turns off the `WSAECONNRESET` that would otherwise fail the next
  `recv_from`).
- `recv` on a UDP socket receives one datagram without telling its sender. There are no
  connected UDP sockets: send with `send_to`.

## Polling (game loops)

| Declaration | Description |
|-------------|-------------|
| `struct PollItem { sock: Socket, want: i64, ready: i64 }` | One socket and what to wait for: `POLL_READ` and / or `POLL_WRITE`. `poll` sets `ready`. |
| `poll(items: []PollItem, timeout_ns: i64) -> i64` | Waits until at least one item is ready, at most `timeout_ns` (0: only looks; `< 0`: no limit): the number of ready items, 0 when the time ran out, -1 on an error. |
| `poll(s: Socket, want: i64, timeout_ns: i64) -> i64` | One socket: its ready bits, 0 when the time ran out, -1 on an error. |
| `POLL_READ`, `POLL_WRITE`, `POLL_ERROR` | `POLL_READ`: `recv` / `recv_from` / `accept` will not wait (data, the end of the stream, or an error to report). `POLL_WRITE`: `send` will not wait; a connection of `tcp_connect_start` has been made or has failed. `POLL_ERROR` (only in `ready`): an error is pending, the connection failed, or the socket is not open. |

`poll` allocates nothing for up to 64 items: call it every frame with a time limit of 0. A
typical frame with non-blocking sockets:

```
use std.net

struct Peer { sock: Socket, inbox: Vec[u8] }

fn frame(server: Socket, peers: *Vec[Peer], items: *Vec[PollItem]) {
    items.clear()
    items.push(PollItem{sock: server, want: POLL_READ})
    for p in peers.items() { items.push(PollItem{sock: p.sock, want: POLL_READ}) }
    if poll(items.items(), 0) <= 0 { return }
    if items[0].ready != 0 {
        c, _, ok := accept(server)
        if ok {
            set_nonblocking(c, true)
            set_nodelay(c, true)
            peers.push(Peer{sock: c})
        }
    }
    buf: [4096]u8
    for i in 1..items.len {
        if items[i].ready == 0 { continue }
        p := &peers[i - 1]
        n := recv(p.sock, buf[..])
        if n > 0 { p.inbox.extend(buf[..n]) }
        if n == 0 || (n < 0 && io_error() != NET_WOULD_BLOCK) { close(p.sock) }   // gone
    }
    // (remove closed peers after the loop; parse messages out of each inbox)
}
```

A connection that must not hold up the frame starts with `tcp_connect_start`; poll it for
`POLL_WRITE` each frame and call `tcp_connect_check` when it is ready.

## Names

| Declaration | Description |
|-------------|-------------|
| `resolve(host: str, port: i64) -> ([]Addr, bool)` | The addresses of a host name, all with `port`, IPv4 first, each once. A number (`"10.0.0.2"`, `"::1"`, `"[::1]"`) is returned as it is. Time limit: `DEFAULT_RESOLVE_NS` (10 s). `([], false)` with `NET_HOST_NOT_FOUND`, `NET_DNS_FAILURE`, 110, ... |
| `resolve(host: str, port: i64, timeout_ns: i64) -> ([]Addr, bool)` | The same within `timeout_ns`. |
| `hosts_lookup(text: str, name: str, port: i64) -> []Addr` | The addresses a hosts file (its text) gives `name`, in file order; case and a final dot are ignored. |
| `struct DnsConfig { servers: []Addr, search: []str, ndots: i64, timeout_ns: i64, attempts: i64 }` | What `resolve_dns` uses. |
| `dns_config(text: str) -> DnsConfig` | Reads a `resolv.conf`: `nameserver` (up to 3), `search`, `domain`, `options ndots:n timeout:n attempts:n`. Defaults as glibc: server 127.0.0.1, ndots 1, 5 s, 2 attempts. |
| `resolve_dns(host: str, port: i64, conf: DnsConfig, timeout_ns: i64) -> ([]Addr, bool)` | Resolves by asking `conf.servers` directly (also on Windows, for a particular server). |
| `dns_encode_query(id: i64, name: str, qtype: i64) -> ([]u8, bool)`, `dns_decode_reply(msg: []u8) -> (DnsReply, bool)`, `struct DnsReply { id, rcode, truncated, name, qtype, addrs }` | The DNS messages it uses (qtype 1: A, 28: AAAA; rcode 3: no such name), for tools and tests. |

**Linux.** No libc, so no glibc resolver: `resolve` reads `/etc/hosts` (on every call; a
match ends the search), answers `localhost` and `*.localhost` with `127.0.0.1` and `::1` if
the hosts file does not name them, and otherwise sends its own DNS queries over UDP to the
servers of `/etc/resolv.conf` (127.0.0.1 if it names none): A and AAAA at once, each server
for `timeout:` seconds, the list `attempts:` times, the search domains for names with fewer
than `ndots` dots (and after the name itself for the others), a "no such name" answer is
final. Replies must come from the server asked, carry the query's id (random, from
`getrandom`) and question; CNAME chains in the answer are followed. Compared with glibc's
`getaddrinfo` it does **not**: consult `/etc/nsswitch.conf` or NSS modules (mDNS `.local`
names, LDAP, `nss-myhostname`, `nss-resolve`: systemd-resolved still works through the stub
server `127.0.0.53` that its resolv.conf names), retry over TCP when a reply is truncated
(what the truncated reply holds is used), use EDNS0 or DNSSEC, rotate servers (`options
rotate`), honour `sortlist`, `single-request` or `RES_OPTIONS` / `LOCALDOMAIN`, sort IPv6
addresses by RFC 6724, cache anything, or know the machine's own host name unless it is in
`/etc/hosts`.

**Windows.** `resolve` asks the system (`getaddrinfo`: hosts file, DNS, the system's cache,
NetBIOS, ...); the time limit is not applied to that call (the system's own limits are);
its failures map to `NET_HOST_NOT_FOUND` (no such host, no address), `NET_DNS_TRY_AGAIN` and
`NET_DNS_FAILURE`.

## HTTP

A minimal HTTP/1.1 client over plain TCP, for tools (fetching a file from a local server,
posting results). **No TLS: `https://` URLs fail** with a message; use a program like `curl`
through [std.os](os.md) for those.

| Declaration | Description |
|-------------|-------------|
| `struct HttpResponse { status: i64, reason: str, headers: [](str, str), body: str }` | A response; any status counts (404 too). |
| `http_get(url: str, timeout_ns: i64) -> (HttpResponse, str)` | `GET http://host[:port]/path?query`: `(response, "")` or `(HttpResponse{}, message)`. |
| `http_post(url: str, content_type: str, body: str, timeout_ns: i64) -> (HttpResponse, str)` | `POST` with that body. |
| `http_request(method: str, url: str, headers: [](str, str), body: str, timeout_ns: i64) -> (HttpResponse, str)` | Any method and further headers. `Host`, `User-Agent`, `Connection: close` and `Content-Length` are added unless given. |
| `http_header(r: HttpResponse, name: str) -> str` | The first header of that name, case ignored (`""` if none). |

- The whole exchange (resolving, connecting, sending, receiving) takes at most `timeout_ns`;
  past it the message says so and `io_error()` is 110.
- Bodies with `Content-Length`, with `Transfer-Encoding: chunked` (extensions and trailers
  are skipped) and bodies that end with the connection are read; interim `1xx` responses are
  skipped; `HEAD`, 204 and 304 have no body.
- Not done: redirects (the 3xx response is returned: follow `http_header(r, "Location")`
  yourself), compression (no `Accept-Encoding` is sent), keep-alive (one connection per
  request), proxies, user names in URLs, cookies, request bodies streamed from files.

```
use std.net

fn main() {
    r, err := http_get("http://127.0.0.1:8000/scores.json", 5_000_000_000)
    if err != "" {
        eprint(err)                     // cannot connect to 127.0.0.1:8000: connection refused
        return
    }
    print(r.status, http_header(r, "Content-Type"), len(r.body))
}
```

## Windows

With `--target windows` the module calls `ws2_32.dll` (and `WSAStartup` on the first socket
or lookup, once per process); everything above behaves the same except:

- **Error numbers** are the Winsock codes mapped to the Linux errno of the same meaning (above);
  a code without one is `0x10000 +` the code (`windows error N`). Writing to a connection the
  peer has closed or reset gives 103 (`software caused connection abort`) or 104 more often
  than 32.
- **A refused connection takes about 2 s** to be reported (Windows retries the connection
  attempt before it gives up), also on the loopback interface: give `tcp_connect` a time
  limit above that where a refusal must be told from a time-out.
- **Waiting** is done with `select` (the exception set reports a failed connection, which
  `WSAPoll` before Windows 10 2004 did not). `poll` over many sockets costs time proportional
  to their number squared; fine for tens of sockets.
- **Inheritance**: sockets are made with `WSA_FLAG_NO_HANDLE_INHERIT`; accepted connections
  take that from the listener.
- `set_nodelay`, `set_broadcast` and IPv6-only sockets work as on Linux; there is no
  `SO_REUSEADDR` (on Windows it would let another program take the port).
- **Names**: see [Names](#names): the system's resolver, without the time limit.

// std.net name resolution without the internet: DNS messages encoded and decoded against fixed
// bytes, resolv.conf and hosts files read, and resolve_dns (what resolve does on Linux after
// /etc/hosts) against a name server on the loopback interface: this program serves, a child
// process (this program again) resolves. Retries, time limits, CNAMEs, search domains,
// "no such name", server failures and replies with the wrong id. The same on every target.
use std.os
use std.net

const SEC = 1_000_000_000

fn hexs(b: []u8) -> str {
    out := vec[str]()
    for x in b { out.push(hex(u64(x), 2)) }
    join(out.items(), " ")
}

fn addrs(list: []Addr) -> str {
    out := vec[str]()
    for a in list { out.push(fmt_addr(a)) }
    fmt("[", join(out.items(), ", "), "]")
}

// ---------- the child: resolves names with the server at 127.0.0.1:port ----------
fn resolver(port: i64) -> i64 {
    conf := dns_config("search test\noptions timeout:1 attempts:2\n")
    conf.servers = []Addr{localhost4(port)}
    conf.timeout_ns = 300_000_000
    for name in []str{"a.test", "a.test.", "cname.test", "drop.test", "wrongid.test", "only4.test",
            "none.test", "nodata.test", "fail.test", "host", "1.2.3.4", "[::1]"} {
        list, ok := resolve_dns(name, 80, conf, 5 * SEC)
        print(name, ok, addrs(list), if ok { "" } else { error_text(io_error()) })
    }
    t0 := clock_ns()
    _, ok := resolve_dns("silent.test", 80, conf, 5 * SEC)
    dt := clock_ns() - t0
    // two attempts of 0.3 s each
    print("silent.test", ok, io_error(), dt >= 500_000_000 && dt < 3 * SEC)
    t0 = clock_ns()
    _, ok = resolve_dns("silent.test", 80, conf, 200_000_000)
    dt = clock_ns() - t0
    print("silent.test, 0.2 s", ok, io_error(), dt >= 150_000_000 && dt < 2 * SEC)
    return 0
}

// ---------- the server ----------
fn put16(b: *Vec[u8], v: i64) {
    b.push(u8(v >> 8))
    b.push(u8(v))
}

// a reply to the query q: rcode, records (type, data) for the question's name; cname: a
// CNAME record first, its target named in full, and the records for the target
fn reply(q: []u8, id: i64, rcode: i64, recs: [](i64, []u8), cname: str) -> []u8 {
    // the question ends after the name and type / class
    at := 12
    while q[at] != 0 { at += i64(q[at]) + 1 }
    qend := at + 5
    b := vec[u8]()
    put16(&b, id)
    put16(&b, 0x8180 | rcode)
    put16(&b, 1)
    put16(&b, len(recs) + (if cname != "" { 1 } else { 0 }))
    put16(&b, 0)
    put16(&b, 0)
    b.extend(q[12..qend])
    owner := 0xC00C
    if cname != "" {
        put16(&b, 0xC00C)
        put16(&b, 5)
        put16(&b, 1)
        put16(&b, 0)
        put16(&b, 60)
        enc, _ := dns_encode_query(0, cname, 1)
        target := enc[12..len(enc) - 4]
        put16(&b, len(target))
        owner = 0xC000 | b.len
        b.extend(target)
    }
    for r in recs {
        put16(&b, owner)
        put16(&b, r.0)
        put16(&b, 1)
        put16(&b, 0)
        put16(&b, 60)
        put16(&b, len(r.1))
        b.extend(r.1)
    }
    b.items()
}

priv seen: Map[str, i64]

fn answer(s: Socket, q: []u8, from: Addr) {
    at := 12
    labels := vec[str]()
    while q[at] != 0 {
        labels.push(q[at + 1..at + 1 + i64(q[at])])
        at += i64(q[at]) + 1
    }
    name := join(labels.items(), ".")
    qtype := i64(q[at + 1]) << 8 | i64(q[at + 2])
    id := i64(q[0]) << 8 | i64(q[1])
    key := fmt(name, "/", qtype)
    n := seen.get_or(key, 0)
    seen.set(key, n + 1)
    a4 := []u8{10, 0, 0, 1}
    a6 := []u8{0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}
    recs := if qtype == 1 { [](i64, []u8){(1, a4)} } else { [](i64, []u8){(28, a6)} }
    none: [](i64, []u8)
    out := match name {
        "a.test" => reply(q, id, 0, recs, "")
        "cname.test" => reply(q, id, 0, recs, "a.test")
        "drop.test" => if n == 0 { nil } else { reply(q, id, 0, recs, "") }
        "wrongid.test" => {
            send_to(s, reply(q, id ^ 1, 0, [](i64, []u8){(1, []u8{6, 6, 6, 6})}, ""), from)
            reply(q, id, 0, recs, "")
        }
        "only4.test" => reply(q, id, 0, if qtype == 1 { recs } else { none }, "")
        "nodata.test" => reply(q, id, 0, none, "")
        "none.test", "host" => reply(q, id, 3, none, "")
        "fail.test" => reply(q, id, 2, none, "")
        "host.test" => reply(q, id, 0, if qtype == 1 { [](i64, []u8){(1, []u8{10, 0, 0, 9})} } else { none }, "")
        "silent.test" => nil
        _ => reply(q, id, 3, none, "")
    }
    if len(out) > 0 {
        send_to(s, out, from)
    }
}

fn main() -> i64 {
    if len(args()) > 2 && args()[1] == "child" {
        n, _ := parse_i64(args()[2])
        return resolver(n)
    }
    // ---------- messages ----------
    q, ok := dns_encode_query(0x1234, "example.com", 1)
    want := []u8{0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0, 0x00, 0x01, 0x00, 0x01}
    print("query:", ok, q == want, hexs(q))
    q6, _ := dns_encode_query(0xBEEF, "ipv6.example.", 28)
    print("query AAAA:", hexs(q6))
    long := repeat("a", 63)
    for name in []str{"", ".", "a..b", "a.", "a..", concat(long, "a"), long, join([]str{long, long, long, repeat("b", 61)}, "."),
            join([]str{long, long, long, repeat("b", 62)}, ".")} {
        _, okn := dns_encode_query(1, name, 1)
        put(okn, " ")
    }
    print()

    rep := []u8{0x12, 0x34, 0x81, 0x80, 0, 1, 0, 4, 0, 0, 0, 0,
        3, 'w', 'w', 'w', 7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0, 0, 1, 0, 1,
        // CNAME www.example.com -> example.com (a pointer to offset 16)
        0xC0, 0x0C, 0, 5, 0, 1, 0, 0, 0x0E, 0x10, 0, 2, 0xC0, 0x10,
        // A example.com 93.184.216.34
        0xC0, 0x10, 0, 1, 0, 1, 0, 0, 0x0E, 0x10, 0, 4, 93, 184, 216, 34,
        // A other.org 1.2.3.4: not for this name
        5, 'o', 't', 'h', 'e', 'r', 3, 'o', 'r', 'g', 0, 0, 1, 0, 1, 0, 0, 0x0E, 0x10, 0, 4, 1, 2, 3, 4,
        // AAAA example.com 2001:db8::1
        0xC0, 0x10, 0, 28, 0, 1, 0, 0, 0x0E, 0x10, 0, 16, 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}
    r, okr := dns_decode_reply(rep)
    print("reply:", okr, hex(u64(r.id)), r.rcode, r.truncated, r.name, r.qtype, addrs(r.addrs))
    nx := clone(rep[..33])
    nx[3] = 0x83
    nx[7] = 0
    r, okr = dns_decode_reply(nx)
    print("no such name:", okr, r.rcode, r.name, len(r.addrs))
    _, okr = dns_decode_reply(rep[..60])
    print("cut short:", okr)
    tc := clone(rep[..63])
    tc[2] |= 0x02
    r, okr = dns_decode_reply(tc)
    print("truncated:", okr, r.truncated, addrs(r.addrs))
    loop_ := []u8{0, 1, 0x81, 0x80, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 0x0C, 0, 1, 0, 1}
    _, okr = dns_decode_reply(loop_)
    print("pointer loop:", okr)
    _, okr = dns_decode_reply(q)
    print("a query is no reply:", okr)
    bad_ptr := clone(rep)
    bad_ptr[47] = 0xF0
    _, okr = dns_decode_reply(bad_ptr)
    print("pointer outside:", okr)

    // ---------- configuration files ----------
    c := dns_config(fmt("# comment\nnameserver 192.0.2.53\nnameserver ::1 ; trailing\nnameserver bad\n",
        "domain old.example\nsearch corp.example. lab.example\noptions ndots:2 timeout:3 attempts:9 rotate\n",
        "nameserver 192.0.2.54\nnameserver 192.0.2.55\n"))
    print("conf:", addrs(c.servers), c.search, c.ndots, c.timeout_ns / SEC, c.attempts)
    d := dns_config("")
    print("default:", addrs(d.servers), len(d.search), d.ndots, d.timeout_ns / SEC, d.attempts)
    hosts := concat("127.0.0.1\tlocalhost\n::1 localhost ip6-localhost # loopback\n# 10.0.0.1 commented\n",
        "10.1.2.3 Game.Server.  game\n10.1.2.4 game\nnot-an-ip game\n")
    print("hosts:", addrs(hosts_lookup(hosts, "localhost", 1)), addrs(hosts_lookup(hosts, "GAME.server", 2)),
        addrs(hosts_lookup(hosts, "game", 3)), addrs(hosts_lookup(hosts, "commented", 4)))

    // ---------- a name server here, a resolver in a child ----------
    s, oks := udp_bind(localhost4(0))
    at, _ := local_addr(s)
    p, okp := spawn([]str{args()[0], "child", fmt(at.port)})
    if !oks || !okp {
        print("FAILED: server or child", error_text(io_error()))
        return 1
    }
    buf := alloc[u8](600)
    status := 0
    loop {
        st, ended := try_wait(p)
        if ended {
            status = st
            break
        }
        n, from := recv_from(s, buf, 20_000_000)
        if n > 12 {
            answer(s, buf[..n], from)
        }
    }
    print("child:", status)
    return 0
}

// std.net TCP on the loopback interface: an echo peer (this program, started again as a child
// process), a large transfer in both directions at once with non-blocking sockets and poll,
// shutdown, connection refused, non-blocking connect, time limits, sockets that a started
// program does not inherit, writing to a closed connection (no SIGPIPE), and the failures of
// a socket that is not open. The same output on every target.
use std.os
use std.net

const SEC = 1_000_000_000

fn num(s: str) -> i64 {
    n, _ := parse_i64(s)
    n
}

fn me(what: []str) -> []str {
    argv := vec_of([]str{args()[0], "child"})
    argv.extend(what)
    argv.items()
}

// the child: `echo PORT` connects and sends back what it gets until the end; `sleep MS`
fn child(a: []str) -> i64 {
    if a[0] == "sleep" {
        sleep_ms(num(a[1]))
        return 0
    }
    if a[0] == "echo" {
        s, ok := tcp_connect(localhost4(num(a[1])), 10 * SEC)
        if !ok {
            eprint(fmt("child: cannot connect: ", error_text(io_error())))
            return 1
        }
        buf := alloc[u8](65536)
        loop {
            n := recv(s, buf)
            if n < 0 {
                eprint(fmt("child: recv: ", error_text(io_error())))
                return 1
            }
            if n == 0 {
                break
            }
            if !send_all(s, buf[..n]) {
                eprint(fmt("child: send: ", error_text(io_error())))
                return 1
            }
        }
        close(s)
        return 0
    }
    return 99
}

// accepts one connection, waiting at most 10 s
fn take(l: Socket) -> Socket {
    if poll(l, POLL_READ, 10 * SEC) != POLL_READ {
        print("FAILED: no connection to accept", error_text(io_error()))
        exit(1)
    }
    c, _, ok := accept(l)
    if !ok {
        print("FAILED: accept:", error_text(io_error()))
        exit(1)
    }
    c
}

// a connected pair on the loopback interface (client, server side)
fn pair(l: Socket) -> (Socket, Socket) {
    at, _ := local_addr(l)
    c, ok := tcp_connect(at, 10 * SEC)
    if !ok {
        print("FAILED: connect:", error_text(io_error()))
        exit(1)
    }
    return (c, take(l))
}

fn main() -> i64 {
    if len(args()) > 2 && args()[1] == "child" {
        return child(args()[2..])
    }
    l, ok := tcp_listen(localhost4(0))
    at, _ := local_addr(l)
    print("listen:", ok, fmt_ip(at), at.port > 0, io_error())

    // echo through a child process
    p, _ := spawn(me([]str{"echo", fmt(at.port)}))
    s := take(l)
    peer, _ := peer_addr(s)
    mine, _ := local_addr(s)
    print("peer:", fmt_ip(peer), mine == at)
    print("send:", send(s, "hello"), send_all(s, " world"))
    buf := alloc[u8](11)
    print("recv_exact:", recv_exact(s, buf), buf)
    print("shutdown:", shutdown(s, SHUT_WRITE))
    print("end:", recv(s, buf), io_error(), "child:", wait(p))
    close(s)

    // 4 MiB each way at once: non-blocking, poll for what can go on
    total := 4 << 20
    data := alloc[u8](total)
    for i in 0..total { data[i] = u8((i * 7 + i / 1000) & 0xFF) }
    p, _ = spawn(me([]str{"echo", fmt(at.port)}))
    s = take(l)
    set_nodelay(s, true)
    print("nonblocking:", set_nonblocking(s, true), recv(s, buf), io_error(), error_text(io_error()))
    back := alloc[u8](total)
    sent := 0
    got := 0
    rounds := 0
    items := []PollItem{PollItem{sock: s}}
    while got < total {
        items[0].want = POLL_READ | (if sent < total { POLL_WRITE } else { 0 })
        if poll(items, 20 * SEC) <= 0 {
            print("FAILED: poll", io_error())
            break
        }
        rounds += 1
        if items[0].ready & POLL_WRITE != 0 {
            n := send(s, data[sent..min(sent + 100_000, total)])
            if n > 0 {
                sent += n
                if sent == total { shutdown(s, SHUT_WRITE) }
            } else if io_error() != NET_WOULD_BLOCK {
                print("FAILED: send", error_text(io_error()))
                break
            }
        }
        if items[0].ready & POLL_READ != 0 {
            n := recv(s, back[got..])
            if n == 0 {
                print("FAILED: early end at", got)
                break
            }
            if n > 0 { got += n } else if io_error() != NET_WOULD_BLOCK {
                print("FAILED: recv", error_text(io_error()))
                break
            }
        }
    }
    print("large:", sent, got, back == data, rounds > 2, recv(s, buf, 10 * SEC), "child:", wait(p))
    close(s)

    // time limits: recv and poll with nothing coming, then data that comes in time
    c, d := pair(l)
    t0 := clock_ns()
    r := recv(d, buf, 200_000_000)
    dt := clock_ns() - t0
    print("recv limit:", r, io_error(), error_text(io_error()), dt >= 150_000_000, dt < 5 * SEC)
    t0 = clock_ns()
    print("poll limit:", poll(d, POLL_READ, 100_000_000), clock_ns() - t0 >= 50_000_000, poll(d, POLL_WRITE, 0))
    send(c, "x")
    print("recv in time:", recv(d, buf, 5 * SEC), buf[..1])

    // poll over several sockets: only the one with data is ready to read
    c2, d2 := pair(l)
    send(c2, "yz")
    ps := []PollItem{PollItem{sock: d, want: POLL_READ}, PollItem{sock: d2, want: POLL_READ}, PollItem{sock: c, want: POLL_WRITE}}
    n := poll(ps, 5 * SEC)
    print("poll several:", n, ps[0].ready, ps[1].ready, ps[2].ready)
    closed: Socket
    ps[0].sock = closed
    print("poll not open:", poll(ps, 0), ps[0].ready)
    close(c2)
    close(d2)

    // a program started meanwhile does not inherit the sockets: when this side closes, the
    // peer sees the end at once (not when the child ends 3 s later)
    k, _ := spawn(me([]str{"sleep", "3000"}))
    sleep_ms(100)
    close(d)
    t0 = clock_ns()
    print("not inherited:", recv(c, buf, 10 * SEC), clock_ns() - t0 < 2 * SEC)
    // writing to the closed connection fails (and does not end the program)
    fails := 0
    e := 0
    for _ in 0..200 {
        if send(c, "more data") < 0 {
            fails += 1
            e = io_error()
            break
        }
        sleep_ms(5)
    }
    print("send to closed:", fails, e == 32 || e == 103 || e == 104)
    close(c)
    wait(k)

    // the listener closed: nothing listens there any more
    close(l)
    _, okr := tcp_connect(at, 10 * SEC)
    print("refused:", okr, io_error(), error_text(io_error()))

    // non-blocking connect: to a listener, and to nothing
    l2, _ := tcp_listen(localhost4(0))
    at2, _ := local_addr(l2)
    nb, okn := tcp_connect_start(at2)
    state := poll(nb, POLL_WRITE, 10 * SEC)
    print("connect start:", okn, state & POLL_WRITE != 0, tcp_connect_check(nb), tcp_connect_check(nb))
    acc := take(l2)
    send(acc, "!")
    print("connected:", recv(nb, buf, 5 * SEC), buf[..1])
    close(acc)
    close(nb)
    close(l2)
    nb2, okn2 := tcp_connect_start(at2)
    state = poll(nb2, POLL_WRITE, 10 * SEC)
    print("connect start, refused:", okn2, state & POLL_WRITE != 0, tcp_connect_check(nb2), io_error(), tcp_connect_check(nb2), io_error())
    close(nb2)

    // a socket that is not open
    none: Socket
    print("not open:", send(none, "x"), io_error(), recv(none, buf), close(none), set_nonblocking(none, true), io_error())
    print("closed twice:", close(nb2), io_error(), error_text(io_error()))
    return 0
}

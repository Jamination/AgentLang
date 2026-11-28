// Regression tests for P0 std.net HTTP security fixes:
// - CRLF / control-character injection rejected in method, URL, and headers
// - chunked response signed-integer overflow and invalid chunk terminator rejected cleanly
use std.os
use std.net

const SEC = 1_000_000_000

fn client(port: i64) -> i64 {
    base := fmt("http://127.0.0.1:", port)
    _, e1 := http_request("GET / HTTP/1.1\r\nX: y", concat(base, "/ok"), nil, "", 5 * SEC)
    _, e2 := http_get(concat(base, "/a\r\nInjected: 1"), 5 * SEC)
    _, e3 := http_request("GET", concat(base, "/ok"), [](str, str){("Bad:Name", "1")}, "", 5 * SEC)
    _, e4 := http_request("GET", concat(base, "/ok"), [](str, str){("X-Test", "ok\r\nEvil: 1")}, "", 5 * SEC)
    print("inject:", e1 != "", e2 != "", e3 != "", e4 != "")

    _, e5 := http_get(concat(base, "/overflow"), 5 * SEC)
    print("overflow:", e5 != "")
    _, e6 := http_get(concat(base, "/badterm"), 5 * SEC)
    print("badterm:", e6)
    return 0
}

fn serve(c: Socket) {
    buf := alloc[u8](4096)
    n := recv(c, buf, 5 * SEC)
    if n > 0 {
        req := buf[..n]
        if find(req, "/overflow") >= 0 {
            send_all(c, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7fffffffffffffff\r\nhello\r\n0\r\n\r\n")
        } else if find(req, "/badterm") >= 0 {
            send_all(c, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWikiXX0\r\n\r\n")
        } else {
            send_all(c, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        }
    }
    close(c)
}

fn main() -> i64 {
    if len(args()) > 2 && args()[1] == "child" {
        n, _ := parse_i64(args()[2])
        return client(n)
    }
    l, _ := tcp_listen(localhost4(0))
    at, _ := local_addr(l)
    p, ok := spawn([]str{args()[0], "child", fmt(at.port)})
    if !ok {
        print("FAILED: child", error_text(io_error()))
        return 1
    }
    status := 0
    loop {
        st, ended := try_wait(p)
        if ended {
            status = st
            break
        }
        if poll(l, POLL_READ, 20_000_000) > 0 {
            c, _, oka := accept(l)
            if oka {
                serve(c)
            }
        }
    }
    close(l)
    return status
}

// std.net HTTP/1.1 client against a server on the loopback interface: this program serves, a
// child process (this program again) makes the requests. Content-Length, chunked bodies with
// extensions and trailers, a body that ends with the connection, an interim 100 response,
// POST, other statuses, HEAD, a time limit, and the URLs it refuses.
use std.os
use std.net

const SEC = 1_000_000_000

fn client(port: i64) -> i64 {
    base := fmt("http://127.0.0.1:", port)
    for path in []str{"/hello", "/chunked", "/until-close", "/interim", "/missing?x=1#frag", "/split"} {
        r, err := http_get(concat(base, path), 10 * SEC)
        print(path, err, r.status, r.reason, len(r.body), r.body, http_header(r, "x-path"))
    }
    r, err := http_post(concat(base, "/echo"), "text/plain", "posted body", 10 * SEC)
    print("post:", err, r.status, r.body)
    r, err = http_request("HEAD", concat(base, "/hello"), nil, "", 10 * SEC)
    print("head:", err, r.status, http_header(r, "Content-Length"), len(r.body))
    r, err = http_request("PUT", concat(base, "/echo"), [](str, str){("X-Extra", "1"), ("Host", "game.example")}, "", 10 * SEC)
    print("put:", err, r.body)
    t0 := clock_ns()
    _, err = http_get(concat(base, "/slow"), 300_000_000)
    print("slow:", err, io_error(), clock_ns() - t0 < 5 * SEC)
    _, err = http_get(fmt("http://localhost:", port, "/hello"), 10 * SEC)
    print("by name:", err)
    for u in []str{"https://example.com/", "ftp://x/", "http://", "http://h:99999/", "http://[::1/", "http://u@h/"} {
        _, e := http_get(u, SEC)
        print(u, "->", e)
    }
    return 0
}

// ---------- the server ----------
// the request on c: (method, path, headers text, body)
fn read_request(c: Socket) -> (str, str, str, str) {
    got := vec[u8]()
    buf := alloc[u8](4096)
    loop {
        h := find(got.items(), "\r\n\r\n")
        if h >= 0 {
            head := got.items()[..h]
            n := 0
            for l in lines(replace(head, "\r\n", "\n")) {
                if starts_with(to_lower(l), "content-length:") {
                    n, _ = parse_i64(trim(l[15..]))
                }
            }
            if got.len >= h + 4 + n {
                first := split(lines(replace(head, "\r\n", "\n"))[0], ' ')
                return (first[0], first[1], head, got.items()[h + 4..h + 4 + n])
            }
        }
        k := recv(c, buf, 5 * SEC)
        if k <= 0 {
            return ("", "", "", "")
        }
        got.extend(buf[..k])
    }
}

fn serve(c: Socket, slow: *Vec[Socket]) {
    method, path, head, body := read_request(c)
    hdr := fmt("X-Path: ", path, "\r\n")
    match path {
        "/hello" => send_all(c, fmt("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n", hdr, "\r\n", if method == "HEAD" { "" } else { "hello" }))
        "/chunked" => send_all(c, fmt("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n", hdr, "\r\n",
            "4\r\nWiki\r\n5;ext=1\r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\nTrailer: x\r\n\r\n"))
        "/until-close" => send_all(c, fmt("HTTP/1.0 200 Fine\r\n", hdr, "\r\nall of it"))
        "/interim" => send_all(c, fmt("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\nContent-Length: 2\r\n", hdr, "\r\nok"))
        "/missing?x=1" => send_all(c, fmt("HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n", hdr, "\r\nnot here."))
        "/split" => {
            set_nodelay(c, true)
            for part in []str{"HTTP/1.1 200 OK\r\nContent-", "Length: 6\r\n", hdr, "\r", "\nab", "cd", "ef"} {
                send_all(c, part)
                sleep_ms(20)
            }
        }
        "/echo" => {
            host := ""
            for l in lines(replace(head, "\r\n", "\n")) {
                if starts_with(to_lower(l), "host:") || starts_with(to_lower(l), "content-type:") || starts_with(l, "X-Extra:") {
                    host = fmt(host, replace(trim(l), fmt("127.0.0.1:", local_addr(c).0.port), "local"), ";")
                }
            }
            text := fmt(method, " ", host, " ", body)
            send_all(c, fmt("HTTP/1.1 200 OK\r\nContent-Length: ", len(text), "\r\n\r\n", text))
        }
        "/slow" => {
            slow.push(c)                 // never answered
            return
        }
        _ => send_all(c, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
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
    slow := vec[Socket]()
    status := 0
    loop {
        st, ended := try_wait(p)
        if ended {
            status = st
            break
        }
        if poll(l, POLL_READ, 20_000_000) > 0 {
            c, _, oka := accept(l)
            if oka { serve(c, &slow) }
        }
    }
    print("child:", status)
    return 0
}

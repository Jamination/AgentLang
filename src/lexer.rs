use crate::ast::{Diag, Pos};

#[derive(Clone, Debug, PartialEq)]
pub enum Tk {
    Id(String),
    Int(u64),
    Float(f64),
    Str(Vec<u8>),
    Kw(&'static str),
    P(&'static str),
    Nl,
    Eof,
}

#[derive(Clone, Debug)]
pub struct Token {
    pub t: Tk,
    pub pos: Pos,
}

const KEYWORDS: &[&str] = &[
    "fn", "struct", "enum", "const", "var", "test", "use", "if", "else", "while", "loop", "for",
    "in", "return", "break", "continue", "assert", "true", "false", "nil", "match", "by", "defer",
    "inline", "noinline",
];

const PUNCTS: &[&str] = &[
    "<<=", ">>=", "..=", ":=", "==", "!=", "<=", ">=", "&&", "||", "<<", ">>", "+=", "-=", "*=",
    "/=", "%=", "&=", "|=", "^=", "..", "=>", "+", "-", "*", "/", "%", "&", "|", "^", "~", "!",
    "<", ">", "=", "(", ")", "[", "]", "{", "}", ",", ".", ":", ";", "@",
];

pub fn lex(src: &str, file: u16, errs: &mut Vec<Diag>) -> Vec<Token> {
    let s = src.as_bytes();
    let mut i = 0usize;
    let mut line = 1u32;
    let mut line_start = 0usize;
    let mut out: Vec<Token> = Vec::new();
    // bracket stack: b'(' / b'[' suppress newlines, b'{' enables them
    let mut stack: Vec<u8> = Vec::new();
    macro_rules! pos {
        ($at:expr) => {
            Pos { file, line, col: ($at - line_start + 1) as u16 }
        };
    }
    while i < s.len() {
        let c = s[i];
        if c == b'\n' {
            let sig = match stack.last() {
                None | Some(b'{') => true,
                _ => false,
            };
            if sig {
                let term = match out.last().map(|t| &t.t) {
                    Some(Tk::Id(_)) | Some(Tk::Int(_)) | Some(Tk::Float(_)) | Some(Tk::Str(_)) => true,
                    Some(Tk::P(p)) => matches!(*p, ")" | "]" | "}"),
                    Some(Tk::Kw(k)) => matches!(*k, "return" | "break" | "continue" | "true" | "false" | "nil"),
                    _ => false,
                };
                if term {
                    out.push(Token { t: Tk::Nl, pos: pos!(i) });
                }
            }
            i += 1;
            line += 1;
            line_start = i;
            continue;
        }
        if c == b' ' || c == b'\t' || c == b'\r' {
            i += 1;
            continue;
        }
        if c == b'/' && i + 1 < s.len() && s[i + 1] == b'/' {
            while i < s.len() && s[i] != b'\n' {
                i += 1;
            }
            continue;
        }
        let p = pos!(i);
        if c.is_ascii_alphabetic() || c == b'_' {
            let st = i;
            while i < s.len() && (s[i].is_ascii_alphanumeric() || s[i] == b'_') {
                i += 1;
            }
            let w = &src[st..i];
            if let Some(k) = KEYWORDS.iter().find(|k| **k == w) {
                out.push(Token { t: Tk::Kw(k), pos: p });
            } else {
                out.push(Token { t: Tk::Id(w.to_string()), pos: p });
            }
            continue;
        }
        if c.is_ascii_digit() {
            let st = i;
            if c == b'0' && i + 1 < s.len() && (s[i + 1] == b'x' || s[i + 1] == b'b' || s[i + 1] == b'o') {
                let radix = match s[i + 1] {
                    b'x' => 16,
                    b'b' => 2,
                    _ => 8,
                };
                i += 2;
                let mut v: u64 = 0;
                let mut any = false;
                while i < s.len() && (s[i].is_ascii_alphanumeric() || s[i] == b'_') {
                    if s[i] != b'_' {
                        match (s[i] as char).to_digit(radix) {
                            Some(d) => {
                                v = v.wrapping_mul(radix as u64).wrapping_add(d as u64);
                                any = true;
                            }
                            None => {
                                errs.push(Diag { pos: p, msg: "invalid digit in integer literal".into() });
                            }
                        }
                    }
                    i += 1;
                }
                if !any {
                    errs.push(Diag { pos: p, msg: "empty integer literal".into() });
                }
                out.push(Token { t: Tk::Int(v), pos: p });
                continue;
            }
            while i < s.len() && (s[i].is_ascii_digit() || s[i] == b'_') {
                i += 1;
            }
            let mut is_float = false;
            if i + 1 < s.len() && s[i] == b'.' && s[i + 1].is_ascii_digit() {
                is_float = true;
                i += 1;
                while i < s.len() && (s[i].is_ascii_digit() || s[i] == b'_') {
                    i += 1;
                }
            }
            if i < s.len() && (s[i] == b'e' || s[i] == b'E') {
                let mut j = i + 1;
                if j < s.len() && (s[j] == b'+' || s[j] == b'-') {
                    j += 1;
                }
                if j < s.len() && s[j].is_ascii_digit() {
                    is_float = true;
                    i = j;
                    while i < s.len() && s[i].is_ascii_digit() {
                        i += 1;
                    }
                }
            }
            let text: String = src[st..i].chars().filter(|c| *c != '_').collect();
            if is_float {
                match text.parse::<f64>() {
                    Ok(v) => out.push(Token { t: Tk::Float(v), pos: p }),
                    Err(_) => {
                        errs.push(Diag { pos: p, msg: "invalid float literal".into() });
                        out.push(Token { t: Tk::Float(0.0), pos: p });
                    }
                }
            } else {
                match text.parse::<u64>() {
                    Ok(v) => out.push(Token { t: Tk::Int(v), pos: p }),
                    Err(_) => {
                        errs.push(Diag { pos: p, msg: "integer literal too large".into() });
                        out.push(Token { t: Tk::Int(0), pos: p });
                    }
                }
            }
            continue;
        }
        if c == b'"' || c == b'\'' {
            let q = c;
            i += 1;
            let mut buf: Vec<u8> = Vec::new();
            let mut closed = false;
            while i < s.len() {
                let d = s[i];
                if d == q {
                    closed = true;
                    i += 1;
                    break;
                }
                if d == b'\n' {
                    break;
                }
                if d == b'\\' && i + 1 < s.len() {
                    i += 1;
                    let e = s[i];
                    i += 1;
                    match e {
                        b'n' => buf.push(b'\n'),
                        b't' => buf.push(b'\t'),
                        b'r' => buf.push(b'\r'),
                        b'0' => buf.push(0),
                        b'\\' => buf.push(b'\\'),
                        b'"' => buf.push(b'"'),
                        b'\'' => buf.push(b'\''),
                        b'x' => {
                            let mut v = 0u32;
                            let mut n = 0;
                            while n < 2 && i < s.len() {
                                if let Some(dg) = (s[i] as char).to_digit(16) {
                                    v = v * 16 + dg;
                                    i += 1;
                                    n += 1;
                                } else {
                                    break;
                                }
                            }
                            if n != 2 {
                                errs.push(Diag { pos: p, msg: "\\x escape needs two hex digits".into() });
                            }
                            buf.push(v as u8);
                        }
                        _ => {
                            errs.push(Diag { pos: p, msg: format!("unknown escape \\{}", e as char) });
                        }
                    }
                    continue;
                }
                buf.push(d);
                i += 1;
            }
            if !closed {
                errs.push(Diag { pos: p, msg: "unterminated string/char literal".into() });
            }
            if q == b'"' {
                out.push(Token { t: Tk::Str(buf), pos: p });
            } else {
                if buf.len() != 1 {
                    errs.push(Diag { pos: p, msg: "char literal must be exactly one byte".into() });
                }
                out.push(Token { t: Tk::Int(*buf.first().unwrap_or(&0) as u64), pos: p });
            }
            continue;
        }
        let mut matched = false;
        for pp in PUNCTS {
            if s[i..].starts_with(pp.as_bytes()) {
                match *pp {
                    "(" | "[" | "{" => stack.push(c),
                    ")" | "]" | "}" => {
                        stack.pop();
                    }
                    _ => {}
                }
                out.push(Token { t: Tk::P(pp), pos: p });
                i += pp.len();
                matched = true;
                break;
            }
        }
        if !matched {
            errs.push(Diag { pos: p, msg: format!("unexpected character '{}'", c as char) });
            i += 1;
        }
    }
    let p = pos!(i);
    if matches!(out.last().map(|t| &t.t), Some(t) if *t != Tk::Nl) {
        out.push(Token { t: Tk::Nl, pos: p });
    }
    out.push(Token { t: Tk::Eof, pos: p });
    out
}

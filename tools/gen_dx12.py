#!/usr/bin/env python3
"""Generates the Direct3D 12 / DXGI bindings of AL from the mingw-w64 C headers.

    python3 tools/gen_dx12.py            writes std/dx12.al, tests/std/dx12.al, tests/std/dx12.out
    python3 tools/gen_dx12.py --verify   also cross-checks every layout, vtable slot and constant
                                         against the headers with a C compiler (static asserts)

Options: --include DIR (header directory), --quiet.

The headers are the widl-generated ones (d3d12.h, dxgi*.h, d3dcommon.h, ...); only their C
declarations are read: `typedef enum`, `typedef struct`, `typedef struct XVtbl`, `DEFINE_GUID`,
object-like `#define`s and the exported function prototypes. Mapping rules are described in
docs/std/dx12.md. Standard library only.
"""
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INCLUDE_DIRS = ['/usr/x86_64-w64-mingw32/include', '/usr/include/wine/windows']

# header, DLL of its exported functions
HEADERS = [
    ('d3dcommon.h', None), ('dxgiformat.h', None), ('dxgicommon.h', None), ('dxgitype.h', None),
    ('dxgi.h', 'dxgi.dll'), ('dxgi1_2.h', 'dxgi.dll'), ('dxgi1_3.h', 'dxgi.dll'), ('dxgi1_4.h', 'dxgi.dll'),
    ('dxgi1_5.h', 'dxgi.dll'), ('dxgi1_6.h', 'dxgi.dll'), ('dxgidebug.h', 'dxgidebug.dll'),
    ('d3d12.h', 'd3d12.dll'), ('d3d12sdklayers.h', None), ('d3dcompiler.h', 'd3dcompiler_47.dll'),
]
# HRESULT values taken from winerror.h
HRESULT_NAMES = re.compile(r'^(DXGI_ERROR_\w+|DXGI_STATUS_\w+|D3D12_ERROR_\w+|S_OK|S_FALSE|E_FAIL|E_INVALIDARG|'
                           r'E_OUTOFMEMORY|E_NOINTERFACE|E_NOTIMPL|E_POINTER|E_ABORT|E_ACCESSDENIED|E_UNEXPECTED)$')
DEFINE_NAMES = re.compile(r'^(D3D12_|DXGI_|D3D_|D3DCOMPILE_|D3DCOMPILER_)\w+$')
# enums whose (very long) enumerator lists are not emitted; the type itself stays usable
ENUMS_WITHOUT_CONSTANTS = {'D3D12_MESSAGE_ID'}
# interface names as used in application code
RENAMED_INTERFACES = {'ID3D10Blob': 'ID3DBlob'}
# constants built with function-like macros in the headers (checked by --verify like all others)
EXTRA_CONSTANTS = [('D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING', 0x1688)]
# the words src/lexer.al reserves (LEXER_KEYWORDS), and `self`, the receiver of the method wrappers
AL_KEYWORDS = set('fn struct enum const var test use if else while loop for in by return break continue assert match '
                  'defer inline noinline true false nil extern priv self'.split())

# Windows base types the D3D headers rely on, in C; they go through the same pipeline.
BASE_DECLS = '''
typedef struct GUID { ULONG Data1; USHORT Data2; USHORT Data3; UCHAR Data4[8];
} GUID;
typedef struct RECT { LONG left; LONG top; LONG right; LONG bottom;
} RECT;
typedef struct POINT { LONG x; LONG y;
} POINT;
typedef struct LUID { DWORD LowPart; LONG HighPart;
} LUID;
typedef struct SECURITY_ATTRIBUTES { DWORD nLength; void *lpSecurityDescriptor; WINBOOL bInheritHandle;
} SECURITY_ATTRIBUTES;
typedef struct MSG { HWND hwnd; UINT message; WPARAM wParam; LPARAM lParam; DWORD time; POINT pt;
} MSG;
typedef struct WNDCLASSEXW { UINT cbSize; UINT style; WNDPROC lpfnWndProc; int cbClsExtra; int cbWndExtra;
    HINSTANCE hInstance; HICON hIcon; HCURSOR hCursor; HBRUSH hbrBackground; LPCWSTR lpszMenuName;
    LPCWSTR lpszClassName; HICON hIconSm;
} WNDCLASSEXW;
typedef struct IUnknownVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(IUnknown *This, REFIID riid, void **ppvObject);
    ULONG (STDMETHODCALLTYPE *AddRef)(IUnknown *This);
    ULONG (STDMETHODCALLTYPE *Release)(IUnknown *This);
} IUnknownVtbl;
DEFINE_GUID(IID_IUnknown, 0x00000000, 0x0000, 0x0000, 0xc0,0x00, 0x00,0x00,0x00,0x00,0x00,0x46);
'''

PRIM = {}
for _al, _names in {
    'u8': 'char CHAR UCHAR BYTE UINT8 BOOLEAN|unsigned char', 'i8': 'INT8|signed char',
    'u16': 'WCHAR wchar_t USHORT UINT16 WORD ATOM|unsigned short', 'i16': 'short SHORT INT16',
    'i32': 'int INT long LONG INT32 HRESULT BOOL WINBOOL',
    'u32': 'unsigned UINT ULONG DWORD UINT32|unsigned int|unsigned long',
    'i64': 'INT64 LONGLONG __int64 LONG_PTR INT_PTR SSIZE_T LPARAM LRESULT LARGE_INTEGER|long long',
    'u64': 'UINT64 ULONGLONG SIZE_T ULONG_PTR UINT_PTR DWORD_PTR WPARAM ULARGE_INTEGER|unsigned __int64|unsigned long long',
    'f32': 'float FLOAT', 'f64': 'double DOUBLE',
}.items():
    _single, *_multi = _names.split('|')
    for _n in _single.split() + _multi:
        PRIM[_n] = _al
PRIM_SIZE = {'u8': 1, 'i8': 1, 'u16': 2, 'i16': 2, 'u32': 4, 'i32': 4, 'u64': 8, 'i64': 8, 'f32': 4, 'f64': 8}
VOID = ('void',)
PVOID = ('ptr', VOID)
POINTER_NAMES = {n: PVOID for n in 'HANDLE HWND HDC HMONITOR HMODULE HINSTANCE HICON HCURSOR HBRUSH HMENU LPVOID PVOID '
                 'LPCVOID'.split()}
POINTER_NAMES['WNDPROC'] = ('fn', 'fn(*u8, u32, u64, i64) -> i64')
POINTER_NAMES.update({n: ('ptr', ('prim', 'u8')) for n in ('LPCSTR', 'LPSTR')})
POINTER_NAMES.update({n: ('ptr', ('prim', 'u16')) for n in ('LPCWSTR', 'LPWSTR')})
POINTER_NAMES.update({n: ('ptr', ('struct', 'GUID')) for n in ('REFIID', 'REFGUID', 'REFCLSID')})
STRUCT_ALIASES = {'IID': 'GUID', 'CLSID': 'GUID'}
ANON = re.compile(r'^(__C89_NAMELESS\w*NAME\d*|DUMMY(UNION|STRUCT)NAME\d*)$')


class Field:
    """`ctype` is the C type name when it is a struct member declared with a named type."""
    def __init__(self, name, ty, ctype=None):
        self.name, self.ty, self.ctype = name, ty, ctype


class Struct:
    """A C struct or union. A type written inline inside another one has `outer` (the C name of the
    enclosing typedef) and `cpath` (member path from there); `anon` marks an unnamed union member."""
    def __init__(self, name, fields, union=False, outer=None, cpath='', anon=False):
        self.name, self.fields, self.union, self.outer, self.cpath, self.anon = name, fields, union, outer, cpath, anon
        self.bitfield = False


class Method:
    def __init__(self, name, origin, ret, params, cdecl):
        self.name, self.origin, self.ret, self.params, self.cdecl = name, origin, ret, params, cdecl


class Db:
    """Everything parsed from the headers, in declaration order."""
    def __init__(self):
        self.structs = {}      # name -> Struct
        self.tags = {}         # struct tag -> typedef name
        self.enums = {}        # name -> (al type, [(enumerator, value, hex?)])
        self.aliases = {}      # typedef name -> unresolved type
        self.consts = {}       # name -> value; for evaluating later expressions
        self.defines = []      # (name, literal text, value, typed i32?)
        self.guids = []        # (name, [11 ints])
        self.ifaces = {}       # name -> [Method]
        self.funcs = []        # (dll, name, ret, params, cdecl)
        self.skipped = []      # notes about declarations that were left out

    # ---- type resolution -------------------------------------------------------------------
    def named(self, name):
        """The type a C type name stands for."""
        name = RENAMED_INTERFACES.get(name, name)
        name = STRUCT_ALIASES.get(name, self.tags.get(name, name))
        if name == 'void':
            return VOID
        if name in PRIM:
            return ('prim', PRIM[name])
        if name in POINTER_NAMES:
            return POINTER_NAMES[name]
        if name in self.structs:
            return ('struct', name)
        if name in self.enums:
            return ('enum', name)
        if name in self.ifaces:
            return ('iface', name)
        if name in self.aliases:
            return self.resolve(self.aliases[name])
        return ('opaque', name)

    def resolve(self, raw):
        """('raw', base name, pointer depth, array dims) -> resolved type."""
        _, base, stars, dims = raw
        ty = self.named(base)
        for _ in range(stars):
            ty = ('ptr', ty)
        for n in reversed(dims):
            ty = ('arr', ty, n)
        return ty

    def layout(self, ty):
        """(size, alignment) under the Windows x64 C ABI."""
        kind = ty[0]
        if kind == 'prim':
            return PRIM_SIZE[ty[1]], PRIM_SIZE[ty[1]]
        if kind in ('ptr', 'fn'):
            return 8, 8
        if kind == 'enum':
            return 4, 4
        if kind == 'arr':
            size, align = self.layout(ty[1])
            return size * ty[2], align
        if kind == 'struct':
            s = self.structs[ty[1]]
            size = align = 0
            for f in s.fields:
                fs, fa = self.layout(f.ty)
                align = max(align, fa)
                if s.union:
                    size = max(size, fs)
                else:
                    size = (size + fa - 1) // fa * fa + fs
            return (size + align - 1) // align * align, align
        raise ValueError('no layout for %r' % (ty,))

    def offsets(self, s):
        """[(field, offset)] of a struct."""
        out, pos = [], 0
        for f in s.fields:
            fs, fa = self.layout(f.ty)
            if not s.union:
                pos = (pos + fa - 1) // fa * fa
            out.append((f, pos))
            if not s.union:
                pos += fs
        return out

    def al(self, ty):
        """AL spelling of a type."""
        kind = ty[0]
        if kind in ('prim', 'fn'):
            return ty[1]
        if kind == 'enum':
            return self.enums[ty[1]][0]
        if kind in ('struct', 'iface'):
            return ty[1]
        if kind == 'arr':
            return '[%d]%s' % (ty[2], self.al(ty[1]))
        if kind == 'ptr':
            inner = ty[1]
            if inner[0] in ('void', 'opaque') or (inner[0] == 'struct' and self.structs[inner[1]].bitfield):
                return '*u8'
            return '*' + self.al(inner)
        raise ValueError('no AL type for %r' % (ty,))

    # ---- expressions -----------------------------------------------------------------------
    def eval(self, text):
        """Value of a C constant expression, or None."""
        text = re.sub(r'\b(?:__MSABI_LONG|_HRESULT_TYPEDEF_)\b', '', text)
        text = re.sub(r'\(\s*(?:HRESULT|UINT|DWORD|int|unsigned int|UINT64|D3D\w*|DXGI\w*)\s*\)(?=\s*[\w(~-])', '', text)
        text = re.sub(r'\b(0[xX][0-9a-fA-F]+|\d+)[uUlL]*\b', lambda m: str(int(m.group(1), 0)), text)
        text = re.sub(r'\b(\d+\.\d*(?:[eE][+-]?\d+)?)[fF]?(?![\w.])', r'\1', text)

        def ident(m):
            v = self.consts.get(m.group(0))
            if v is None:
                raise KeyError(m.group(0))
            return '(%r)' % (v,)
        try:
            text = re.sub(r'\b[A-Za-z_]\w*\b', ident, text)
            if not re.fullmatch(r'[\d\s()|&^~<>+\-*/%.e]+', text):
                return None
            return eval(text.replace('/', '//') if '.' not in text else text, {'__builtins__': {}})
        except (KeyError, SyntaxError, ZeroDivisionError, TypeError):
            return None


# ---- parsing -------------------------------------------------------------------------------------

def tokens(text):
    return re.findall(r'[A-Za-z_]\w*|0[xX][0-9a-fA-F]+[uUlL]*|\d+[uUlL]*|[^\s\w]', text)


def parse_decl(db, toks):
    """`const TYPE *name[N]` -> (name, raw type, bitfield?). The name may be missing (None)."""
    bits = ':' in toks
    if bits:
        toks = toks[:toks.index(':')]
    dims = []
    while toks and toks[-1] == ']':
        i = len(toks) - 1 - toks[::-1].index('[')
        n = db.eval(' '.join(toks[i + 1:-1]))
        assert isinstance(n, int), toks
        dims.insert(0, n)
        toks = toks[:i]
    stars = toks.count('*')
    words = [t for t in toks if re.match(r'[A-Za-z_]', t) and t not in ('const', 'struct', 'union', 'enum', 'volatile')]
    assert words, toks
    name = None
    if len(words) > 1 and ' '.join(words) not in PRIM and toks[-1] == words[-1]:
        name = words.pop()
    return name, ('raw', ' '.join(words), stars, dims), bits


def parse_members(db, owner, toks, path=()):
    """Members of a struct/union body. Unnamed nested types become structs of their own."""
    fields, bitfield, i = [], False, 0
    while i < len(toks):
        j = i
        while toks[j] in ('__C89_NAMELESS', '__extension__', 'const'):
            j += 1
        if toks[j] in ('struct', 'union') and '{' in toks[j:j + 3]:
            union = toks[j] == 'union'
            open_ = toks.index('{', j)
            depth, close = 1, open_
            while depth:
                close += 1
                depth += {'{': 1, '}': -1}.get(toks[close], 0)
            end = toks.index(';', close)
            name = toks[close + 1] if end > close + 1 and not ANON.match(toks[close + 1]) else None
            assert name or union, 'anonymous struct in ' + owner
            if not name:   # the members of an anonymous union are addressed from the enclosing type in C
                name = 'u%s' % ('' if not any(f.name.startswith('u') and f.ctype is None for f in fields) else len(fields))
                sub, anon = path, True
            else:
                sub, anon = path + (name,), False
            inner, bf = parse_members(db, owner, toks[open_ + 1:close], sub)
            bitfield |= bf
            sname = '_'.join((owner,) + path + (name,))
            db.structs[sname] = Struct(sname, inner, union, owner, '.'.join(sub), anon)
            fields.append(Field(name, ('struct', sname)))
            i = end + 1
            continue
        end = toks.index(';', i)
        name, raw, bits = parse_decl(db, toks[i:end])
        bitfield |= bits
        fields.append(Field(name, raw, raw[1]))
        i = end + 1
    return fields, bitfield


def split_params(text):
    text = text.strip()
    return [] if text in ('', 'void') else [p.strip() for p in text.split(',')]


def parse_params(db, text):
    """[(name, raw type, C text)]; array parameters decay to pointers."""
    out = []
    for k, p in enumerate(split_params(text)):
        name, (_, base, stars, dims), _ = parse_decl(db, tokens(p))
        out.append((name or 'a%d' % k, ('raw', base, stars + (1 if dims else 0), []), ' '.join(p.split())))
    return out


def parse_header(db, text, dll, hresults_only=False):
    text = re.sub(r'/\*(?!\*\*)(.*?)\*/', '', text, flags=re.S)   # keep /*** X methods ***/ markers
    text = re.sub(r'//[^\n]*', '', text)
    text = re.sub(r'\\\n', ' ', text)
    # one pass over the top-level declarations, in file order
    pattern = re.compile(
        r'^typedef\s+enum\s+\w*\s*\{(?P<ebody>.*?)\}\s*(?P<ename>\w+)\s*;'
        r'|^typedef\s+struct\s+(?P<vtbl>\w+)Vtbl\s*\{(?P<vbody>.*?)^\}\s*\w+Vtbl\s*;'
        r'|^typedef\s+(?P<su>struct|union)\s+(?P<stag>\w+)\s*\{(?P<sbody>.*?)^\}\s*(?P<sname>\w+)\s*;'
        r'|^typedef\s+(?P<alias>[^;{}()]+);'
        r'|^typedef\s+[^;{}]*\(\s*(?:WINAPI|__stdcall|STDMETHODCALLTYPE)?\s*\*\s*(?P<fnptr>\w+)\s*\)\s*\([^;]*\)\s*;'
        r'|^DEFINE_GUID\s*\(\s*(?P<guid>\w+)\s*,(?P<gvals>[^)]*)\)'
        r'|^DEFINE_ENUM_FLAG_OPERATORS\s*\(\s*(?P<flags>\w+)\s*\)'
        r'|^#define[ \t]+(?P<dname>\w+)[ \t]+(?P<dbody>[^\n]+)'
        r'|^(?P<fret>\w+)\s+(?:WINAPI|__stdcall)\s+(?P<fname>\w+)\s*\((?P<fparams>[^;{}]*)\)\s*;',
        re.S | re.M)
    for m in pattern.finditer(text):
        if m.group('dname'):
            name, body = m.group('dname'), m.group('dbody').strip()
            wanted = HRESULT_NAMES.match(name) if hresults_only else DEFINE_NAMES.match(name)
            if not wanted or name in db.consts or name.endswith('_DEFINED__') or name.endswith('_H__'):
                continue
            value = db.eval(body)
            if value is None:
                if name not in dict(EXTRA_CONSTANTS):
                    db.skipped.append('#define %s %s' % (name, body))
                continue
            db.consts[name] = value
            literal = re.fullmatch(r'[\s(]*(?:__MSABI_LONG\()?(0[xX][0-9a-fA-F]+|\d+)[uUlL]*[\s)]*', body)
            typed = 'HRESULT' in body or hresults_only
            db.defines.append((name, literal.group(1).lower() if literal and not typed else None, value, typed))
        elif hresults_only:
            continue
        elif m.group('ename'):
            parse_enum(db, m.group('ename'), m.group('ebody'))
        elif m.group('vtbl'):
            parse_vtbl(db, m.group('vtbl'), m.group('vbody'))
        elif m.group('sname'):
            name = m.group('sname')
            db.tags[m.group('stag')] = name
            if name not in db.structs:
                db.structs[name] = None   # reserve the position: members may reference later types
                fields, bitfield = parse_members(db, name, tokens(m.group('sbody')))
                db.structs[name] = Struct(name, fields, m.group('su') == 'union')
                db.structs[name].bitfield = bitfield
        elif m.group('alias'):
            toks = tokens(m.group('alias'))
            if toks[0] in ('interface', 'struct', 'union', 'enum') and len(toks) == 3 and toks[1] == toks[2]:
                continue   # forward declaration
            name, raw, _ = parse_decl(db, toks)
            if not name or name in PRIM or name in POINTER_NAMES or name in db.aliases or name in db.structs:
                continue
            target = db.structs.get(db.tags.get(raw[1], raw[1]))
            if target and not raw[2] and not raw[3] and target.name != 'GUID':
                # AL has no type aliases: `typedef RECT D3D12_RECT` becomes a struct with the same members
                db.structs[name] = Struct(name, target.fields, target.union)
            else:
                db.aliases[name] = raw
        elif m.group('fnptr'):
            db.aliases.setdefault(m.group('fnptr'), ('raw', 'void', 1, []))
        elif m.group('guid'):
            vals = [int(v.strip(), 0) for v in m.group('gvals').split(',')]
            assert len(vals) == 11, m.group(0)
            db.guids.append((m.group('guid'), vals))
        elif m.group('flags'):
            name = m.group('flags')
            db.enums[name] = ('u32', db.enums[name][1])
        elif m.group('fname') and dll and not re.search(r'_(Proxy|Stub)$', m.group('fname')):
            params = parse_params(db, m.group('fparams'))
            cdecl = '%s %s(%s)' % (m.group('fret'), m.group('fname'), ', '.join(p[2] for p in params))
            db.funcs.append((dll, m.group('fname'), ('raw', m.group('fret'), 0, []), params, cdecl))


def parse_enum(db, name, body):
    items, nxt = [], 0
    for part in body.split(','):
        part = part.strip()
        if not part:
            continue
        ident, _, expr = part.partition('=')
        ident, expr = ident.strip(), expr.strip()
        value = db.eval(expr) if expr else nxt
        assert isinstance(value, int), (name, part)
        nxt = value + 1
        db.consts[ident] = value
        # size-forcing members and the D3D10/D3D11 spellings of D3D_ enumerators are not API
        if re.search(r'_FORCE_(UINT|DWORD)$', ident) or re.match(r'D3D1[01]_', ident):
            continue
        items.append((ident, value, bool(re.fullmatch(r'0[xX][0-9a-fA-F]+[uUlL]*', expr))))
    unsigned = bool(re.search(r'_FLAGS?$', name)) or any(v > 0x7fffffff for _, v, _ in items)
    db.enums[name] = ('u32' if unsigned else 'i32', items)


def parse_vtbl(db, name, body):
    name = RENAMED_INTERFACES.get(name, name)
    methods, origin = [], name
    body = re.sub(r'/\*\*\*\s*(\w+) methods\s*\*\*\*/', r'@\1;', body)
    pattern = re.compile(r'@(\w+);|([^;()@]+?)\(\s*STDMETHODCALLTYPE\s*\*\s*(\w+)\s*\)\s*\(([^;]*)\)\s*;')
    db.ifaces[name] = methods   # registered first: the methods refer to their own interface
    for m in pattern.finditer(body):
        if m.group(1):
            origin = RENAMED_INTERFACES.get(m.group(1), m.group(1))
            continue
        ret = ' '.join(m.group(2).split())
        _, raw, _ = parse_decl(db, tokens(ret) + ['_'])
        params = parse_params(db, m.group(4))
        assert params and params[0][0] == 'This', (name, m.group(3))
        cdecl = '%s %s::%s(%s)' % (ret, name, m.group(3), ', '.join(p[2] for p in params[1:]))
        methods.append(Method(m.group(3), origin, raw, params[1:], cdecl))


def load(include_dir):
    db = Db()
    parse_header(db, BASE_DECLS, None)
    for header, dll in HEADERS:
        with open(os.path.join(include_dir, header), encoding='latin-1') as f:
            parse_header(db, f.read(), dll)
    with open(os.path.join(include_dir, 'winerror.h'), encoding='latin-1') as f:
        parse_header(db, f.read(), None, hresults_only=True)
    for name, value in EXTRA_CONSTANTS:
        db.consts[name] = value
        db.defines.append((name, hex(value), value, False))
    # resolve member types now that every name is known
    for s in db.structs.values():
        for f in s.fields:
            if f.ty[0] == 'raw':
                f.ty = db.resolve(f.ty)
    for s in db.structs.values():
        s.bitfield |= any(by_value_bitfield(db, f.ty) for f in s.fields)
    return db


def by_value_bitfield(db, ty):
    if ty[0] == 'arr':
        return by_value_bitfield(db, ty[1])
    return ty[0] == 'struct' and db.structs[ty[1]].bitfield


# ---- emission ------------------------------------------------------------------------------------

def ident(name):
    return name + '_' if name in AL_KEYWORDS or name in PRIM_SIZE else name


def int_literal(value, hexa):
    return ('-0x%x' % -value if value < 0 else '0x%x' % value) if hexa else str(value)


def scalar_pack(db, ty, expr):
    """An 8-byte-or-smaller struct passed by value travels as one integer (Win64): build it."""
    size, _ = db.layout(ty)
    target = 'u%d' % (size * 8)
    parts = []
    for f, off in db.offsets(db.structs[ty[1]]):
        fs, _ = db.layout(f.ty)
        assert f.ty[0] in ('prim', 'enum') and db.al(f.ty)[0] in 'iu', (ty, f.name)
        part = '%s.%s' % (expr, ident(f.name))
        al = db.al(f.ty)
        if al != 'u%d' % (fs * 8):
            part = 'u%d(%s)' % (fs * 8, part)
        if fs != size:
            part = '%s(%s)' % (target, part)
        parts.append('(%s << %d)' % (part, off * 8) if off else part)
    return target, ' | '.join(parts)


def signature(db, m, self_ty):
    """(vtable field types, wrapper params, call arguments, wrapper result, struct result, type params)."""
    vt_types, params, args, tparams = ['*' + self_ty], ['self: *' + self_ty], ['self'], []
    sret = None
    prev_c = ''
    for name, raw, cdecl in m.params:
        ty = db.resolve(raw)
        name = ident(name)
        if name == '__ret':
            sret = db.al(ty[1])
            vt_types.append(db.al(ty))
            args.append('&r')
        elif ty[0] == 'struct':
            size, _ = db.layout(ty)
            if size in (1, 2, 4, 8):
                scalar, expr = scalar_pack(db, ty, name)
                vt_types.append(scalar)
                args.append(expr)
            else:
                vt_types.append('*' + db.al(ty))
                args.append('&' + name)
            params.append('%s: %s' % (name, db.al(ty)))
        elif ty == ('ptr', PVOID) and re.match(r'REFIID\b', prev_c):
            t = 'T%s' % (len(tparams) + 1 if tparams else '')
            tparams.append(t)
            vt_types.append('**u8')
            params.append('%s: **%s' % (name, t))
            args.append('cast[**u8](%s)' % name)
        else:
            vt_types.append(db.al(ty))
            params.append('%s: %s' % (name, db.al(ty)))
            args.append(name)
        prev_c = cdecl
    ret = db.resolve(m.ret)
    return vt_types, params, args, '' if ret == VOID else db.al(ret), sret, tparams


def emit_constants(db, out):
    out.append('// ---- constants (#define) ' + '-' * 70)
    for name, literal, value, typed in db.defines:
        if typed:
            out.append('const %s: i32 = 0x%08x' % (name, value & 0xffffffff))
        elif isinstance(value, float):
            out.append('const %s = %r' % (name, value))
        else:
            out.append('const %s = %s' % (name, literal or value))
    out.append('')
    out.append('// ---- enums: typed constants; struct fields and parameters use the enum\'s integer type ' + '-' * 8)
    for name, (al, items) in db.enums.items():
        if name in ENUMS_WITHOUT_CONSTANTS:
            out.append('// enum %s (%s): enumerators not listed' % (name, al))
            continue
        out.append('// enum %s' % name)
        for item, value, hexa in items:
            out.append('const %s: %s = %s' % (item, al, int_literal(value if al == 'i32' else value & 0xffffffff, hexa)))
    out.append('')


def emit_structs(db, out):
    out.append('// ---- structs (Windows x64 C layout) ' + '-' * 60)
    for s in db.structs.values():
        if s.union:
            continue   # appears as a block of bytes inside its owner
        if s.bitfield:
            out.append('// struct %s: skipped, it has bit-fields (pointers to it are *u8)' % s.name)
            continue
        size, align = db.layout(('struct', s.name))
        out.append('// %d bytes, alignment %d' % (size, align))
        out.append('struct %s {' % s.name)
        accessors = []
        for f in s.fields:
            if f.ty[0] == 'struct' and db.structs[f.ty[1]].union:
                u = db.structs[f.ty[1]]
                usize, ualign = db.layout(f.ty)
                block = 'u%d' % (ualign * 8)
                count = usize // ualign
                names = ', '.join('u_' + m.name for m in u.fields)
                out.append('    %s: %s // union: %s' % (ident(f.name), block if count == 1 else '[%d]%s' % (count, block), names))
                for m in u.fields:
                    accessors.append('// The `%s` member of the union in %s.' % (m.name, s.name))
                    accessors.append('inline fn u_%s(s: *%s) -> *%s { cast[*%s](&s.%s) }' % (
                        m.name, s.name, db.al(m.ty), db.al(m.ty), ident(f.name)))
            else:
                # an enum or a typedef of a number loses its name in AL: keep it as a remark
                lost = f.ctype in db.enums or f.ctype in db.aliases
                out.append('    %s: %s%s' % (ident(f.name), db.al(f.ty), ' // ' + f.ctype if lost else ''))
        out.append('}')
        out.extend(accessors)
    out.append('')


def emit_guids(db, out):
    out.append('// ---- GUIDs ' + '-' * 86)
    seen = set()
    for name, v in db.guids:
        name = re.sub(r'^IID_(\w+)$', lambda m: 'IID_' + RENAMED_INTERFACES.get(m.group(1), m.group(1)), name)
        if name in seen:
            continue
        seen.add(name)
        out.append('%s := GUID{0x%08x, 0x%04x, 0x%04x, [8]u8{%s}}' % (
            name, v[0], v[1], v[2], ', '.join('0x%02x' % b for b in v[3:])))
    out.append('')


def emit_interfaces(db, out):
    out.append('// ---- COM interfaces: object = { vt }, vtable = function pointers in header order ' + '-' * 14)
    for name, methods in db.ifaces.items():
        out.append('struct %s { vt: *%sVtbl }' % (name, name))
        sigs = [signature(db, m, name) for m in methods]
        out.append('struct %sVtbl {' % name)
        for m, (vt_types, _, _, ret, sret, _) in zip(methods, sigs):
            out.append('    %s: fn(%s)%s' % (m.name, ', '.join(vt_types), ' -> ' + ret if ret else ''))
        out.append('}')
        for slot, (m, (_, params, args, ret, sret, tparams)) in enumerate(zip(methods, sigs)):
            out.append('// [%d] %s' % (slot, m.cdecl))
            call = 'self.vt.%s(%s)' % (m.name, ', '.join(args))
            generic = '[%s]' % ', '.join(tparams) if tparams else ''
            if sret:
                out.append('inline fn %s%s(%s) -> %s { r: %s; %s; r }' % (
                    m.name, generic, ', '.join(params), sret, sret, call))
            else:
                out.append('inline fn %s%s(%s)%s { %s }' % (
                    m.name, generic, ', '.join(params), ' -> ' + ret if ret else '', call))
        out.append('')


def emit_functions(db, out):
    out.append('// ---- exported functions ' + '-' * 72)
    for dll, name, ret, params, cdecl in db.funcs:
        tys = [db.resolve(raw) for _, raw, _ in params]
        if any(t[0] == 'ptr' and t[1][0] == 'ptr' and t[1][1][0] == 'opaque' for t in tys):
            db.skipped.append(cdecl)   # hands out an interface this module does not describe
            continue
        r = db.resolve(ret)
        out.append('// %s' % cdecl)
        out.append('extern "%s" fn %s(%s)%s' % (dll, name, ', '.join('%s: %s' % (ident(n), db.al(t)) for (n, _, _), t in zip(params, tys)),
                                                 '' if r == VOID else ' -> ' + db.al(r)))
    out.append('')


PROLOGUE = r'''// std.dx12: Direct3D 12 and DXGI for AL. GENERATED by tools/gen_dx12.py from the mingw-w64
// headers (d3d12.h, dxgi*.h, d3dcommon.h, d3d12sdklayers.h, d3dcompiler.h); do not edit.
//
// AL has no Windows backend yet: programs using this module type-check (`alc check`) but
// cannot be built. See docs/std/dx12.md for the mapping rules and a walk-through.
//
//   device: *ID3D12Device
//   dx_check(D3D12CreateDevice(nil, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, ppv(&device)), "D3D12CreateDevice")
//   queue: *ID3D12CommandQueue
//   desc := D3D12_COMMAND_QUEUE_DESC{Type: D3D12_COMMAND_LIST_TYPE_DIRECT}
//   dx_check(device.CreateCommandQueue(&desc, &IID_ID3D12CommandQueue, &queue), "CreateCommandQueue")

// ---- helpers -------------------------------------------------------------------------------

// True if an HRESULT signals success (S_OK, S_FALSE, ...).
inline fn SUCCEEDED(hr: i32) -> bool { hr >= 0 }

// True if an HRESULT signals failure.
inline fn FAILED(hr: i32) -> bool { hr < 0 }

// Stops the program with `what` and the HRESULT in hexadecimal if `hr` is a failure code.
fn dx_check(hr: i32, what: str) {
    if hr < 0 {
        panic(fmt(what, " failed: HRESULT 0x", pad_left(hex(u64(u32(hr))), 8, '0')))
    }
}

// An interface pointer variable as the `void **` out-argument of an exported function:
// `CreateDXGIFactory2(0, &IID_IDXGIFactory4, ppv(&factory))`. Methods take `&factory` directly.
inline fn ppv[T](p: **T) -> **u8 { cast[**u8](p) }

// Releases the COM object in `*pp` (if any) and sets the variable to nil.
fn com_release[T](pp: **T) {
    if *pp != nil {
        cast[*IUnknown](*pp).Release()
        *pp = nil
    }
}

// NUL-terminated UTF-16 copy of UTF-8 text, for the `*u16` (LPCWSTR) parameters. Allocates from the arena.
fn utf16(s: str) -> *u16 {
    w := alloc[u16](len(s) + 1)
    n := 0
    i := 0
    while i < len(s) {
        c := u32(s[i])
        extra := 0
        if c >= 0xf0 {
            c &= 0x07
            extra = 3
        } else if c >= 0xe0 {
            c &= 0x0f
            extra = 2
        } else if c >= 0xc0 {
            c &= 0x1f
            extra = 1
        }
        i += 1
        while extra > 0 && i < len(s) {
            c = c << 6 | u32(s[i]) & 0x3f
            i += 1
            extra -= 1
        }
        if c >= 0x10000 {
            c -= 0x10000
            w[n] = u16(0xd800 + (c >> 10))
            w[n + 1] = u16(0xdc00 + (c & 0x3ff))
            n += 2
        } else {
            w[n] = u16(c)
            n += 1
        }
    }
    ptr(w)
}

// The contents of a blob (compiled shader, serialized root signature, error text) as bytes; no copy.
fn blob_bytes(b: *ID3DBlob) -> str { mkslice[u8](b.GetBufferPointer(), i64(b.GetBufferSize())) }

// ---- Win32: just enough to open a window, pump messages and wait on a fence ----------------
const WS_OVERLAPPEDWINDOW: u32 = 0x00cf0000
const WS_VISIBLE: u32 = 0x10000000
const CW_USEDEFAULT: i32 = 0x80000000
const CS_VREDRAW: u32 = 0x1
const CS_HREDRAW: u32 = 0x2
const WM_DESTROY: u32 = 0x2
const WM_SIZE: u32 = 0x5
const WM_PAINT: u32 = 0xf
const WM_CLOSE: u32 = 0x10
const WM_QUIT: u32 = 0x12
const WM_KEYDOWN: u32 = 0x100
const WM_KEYUP: u32 = 0x101
const PM_REMOVE: u32 = 0x1
const SW_SHOW: i32 = 5
const VK_ESCAPE: u64 = 0x1b
const IDC_ARROW: u64 = 32512
const INFINITE: u32 = 0xffffffff
const WAIT_OBJECT_0: u32 = 0

// A window procedure is a plain AL function: fn(hwnd: *u8, msg: u32, wparam: u64, lparam: i64) -> i64.

// Handle of a loaded module; nil names the executable itself.
extern "kernel32.dll" fn GetModuleHandleW(name: *u16) -> *u8
// Creates an event object (for ID3D12Fence.SetEventOnCompletion); nil on failure.
extern "kernel32.dll" fn CreateEventW(attributes: *SECURITY_ATTRIBUTES, manual_reset: i32, initial_state: i32, name: *u16) -> *u8
// Blocks until the object is signalled or the time-out (INFINITE: none) passes.
extern "kernel32.dll" fn WaitForSingleObject(handle: *u8, milliseconds: u32) -> u32
// Closes a kernel object handle.
extern "kernel32.dll" fn CloseHandle(handle: *u8) -> i32
// Suspends the calling thread.
extern "kernel32.dll" fn Sleep(milliseconds: u32)
// Error code of the last failed Win32 call on this thread.
extern "kernel32.dll" fn GetLastError() -> u32
// Sends a NUL-terminated string to the debugger output.
extern "kernel32.dll" fn OutputDebugStringA(text: *u8)
// Reads the high-resolution counter.
extern "kernel32.dll" fn QueryPerformanceCounter(count: *i64) -> i32
// Ticks per second of the high-resolution counter.
extern "kernel32.dll" fn QueryPerformanceFrequency(frequency: *i64) -> i32
// Registers a window class; 0 on failure.
extern "user32.dll" fn RegisterClassExW(class: *WNDCLASSEXW) -> u16
// Creates a window; nil on failure.
extern "user32.dll" fn CreateWindowExW(ex_style: u32, class_name: *u16, window_name: *u16, style: u32, x: i32, y: i32, width: i32, height: i32, parent: *u8, menu: *u8, instance: *u8, param: *u8) -> *u8
// Default handling for the messages a window procedure does not process.
extern "user32.dll" fn DefWindowProcW(hwnd: *u8, msg: u32, wparam: u64, lparam: i64) -> i64
// Shows or hides a window (SW_SHOW).
extern "user32.dll" fn ShowWindow(hwnd: *u8, cmd: i32) -> i32
// Destroys a window.
extern "user32.dll" fn DestroyWindow(hwnd: *u8) -> i32
// Fetches the next queued message without blocking; 0 if there is none.
extern "user32.dll" fn PeekMessageW(msg: *MSG, hwnd: *u8, filter_min: u32, filter_max: u32, remove: u32) -> i32
// Turns key messages into character messages.
extern "user32.dll" fn TranslateMessage(msg: *MSG) -> i32
// Hands a message to the window procedure.
extern "user32.dll" fn DispatchMessageW(msg: *MSG) -> i64
// Queues WM_QUIT, which ends the message loop.
extern "user32.dll" fn PostQuitMessage(exit_code: i32)
// Loads a cursor; system cursors use a nil instance and `cast[*u16](IDC_ARROW)`.
extern "user32.dll" fn LoadCursorW(instance: *u8, name: *u16) -> *u8
// Grows a client rectangle to the window rectangle of a style.
extern "user32.dll" fn AdjustWindowRect(rect: *RECT, style: u32, menu: i32) -> i32
// Client-area size of a window.
extern "user32.dll" fn GetClientRect(hwnd: *u8, rect: *RECT) -> i32
// Shows a modal message box.
extern "user32.dll" fn MessageBoxW(hwnd: *u8, text: *u16, caption: *u16, kind: u32) -> i32
'''

WIN32_CONSTANTS = ['WS_OVERLAPPEDWINDOW', 'WS_VISIBLE', 'CW_USEDEFAULT', 'CS_VREDRAW', 'CS_HREDRAW', 'WM_DESTROY', 'WM_SIZE',
                   'WM_PAINT', 'WM_CLOSE', 'WM_QUIT', 'WM_KEYDOWN', 'WM_KEYUP', 'PM_REMOVE', 'SW_SHOW', 'VK_ESCAPE',
                   'INFINITE', 'WAIT_OBJECT_0']


def emit_module(db):
    out = PROLOGUE.rstrip('\n').split('\n') + ['']
    emit_constants(db, out)
    emit_structs(db, out)
    emit_guids(db, out)
    emit_interfaces(db, out)
    emit_functions(db, out)
    return '\n'.join(out).rstrip('\n') + '\n'


# ---- self-test written in AL ---------------------------------------------------------------------

TEST_HEAD = r'''// GENERATED by tools/gen_dx12.py together with std/dx12.al.
// Checks on Linux what can be checked without Windows: struct sizes and field offsets against
// the values computed from the headers (which `gen_dx12.py --verify` proves against a C
// compiler), vtable sizes, the helpers, and calls through a COM vtable built in AL.
use std.dx12

checked: i64
wrong: i64

fn chk(got: i64, want: i64, what: str) {
    checked += 1
    if got != want {
        wrong += 1
        print("MISMATCH", what, "got", got, "want", want)
    }
}

// A COM object implemented in AL: the vtable layout of ID3DBlob with a reference count.
struct FakeBlob { vt: *ID3DBlobVtbl, refs: u32, data: str }

fn fake_query(self: *ID3DBlob, riid: *GUID, out: **u8) -> i32 {
    if *riid == IID_ID3DBlob || *riid == IID_IUnknown {
        *out = cast[*u8](self)
        cast[*FakeBlob](self).refs += 1
        return S_OK
    }
    *out = nil
    E_NOINTERFACE
}

fn fake_addref(self: *ID3DBlob) -> u32 {
    b := cast[*FakeBlob](self)
    b.refs += 1
    b.refs
}

fn fake_release(self: *ID3DBlob) -> u32 {
    b := cast[*FakeBlob](self)
    b.refs -= 1
    b.refs
}

fn fake_pointer(self: *ID3DBlob) -> *u8 { ptr(cast[*FakeBlob](self).data) }

fn fake_size(self: *ID3DBlob) -> u64 { u64(len(cast[*FakeBlob](self).data)) }

fn helpers() {
    print("S_OK", SUCCEEDED(S_OK), FAILED(S_OK), "S_FALSE", SUCCEEDED(S_FALSE), "E_FAIL", SUCCEEDED(E_FAIL), FAILED(E_FAIL))
    print("DXGI_ERROR_DEVICE_REMOVED", hex(u64(u32(DXGI_ERROR_DEVICE_REMOVED))), FAILED(DXGI_ERROR_DEVICE_REMOVED))
    dx_check(S_OK, "nothing")
    w := mkslice[u16](utf16("A\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80z"), 7)
    print("utf16", w)
    print("guid", hex(u64(IID_ID3D12Device.Data1)), IID_ID3D12Device.Data4, IID_ID3D12Device == IID_ID3D12Device, IID_ID3D12Device == IID_ID3D12Resource)
    print("consts", D3D12_COMMAND_LIST_TYPE_DIRECT, D3D_FEATURE_LEVEL_12_0, DXGI_FORMAT_R8G8B8A8_UNORM, D3D12_RESOURCE_STATE_GENERIC_READ, D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING, DXGI_USAGE_RENDER_TARGET_OUTPUT)

    // unions: the accessors view the same bytes
    barrier: D3D12_RESOURCE_BARRIER
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION
    t := barrier.u_Transition()
    t.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES
    t.StateBefore = D3D12_RESOURCE_STATE_PRESENT
    t.StateAfter = D3D12_RESOURCE_STATE_RENDER_TARGET
    print("barrier", cast[i64](barrier.u_Aliasing()) - cast[i64](&barrier), barrier.u_Transition().Subresource, barrier.u_Transition().StateAfter)
    clear: D3D12_CLEAR_VALUE
    color := clear.u_Color()
    color[2] = 0.5
    print("clear", clear.u_Color()[2], clear.u_DepthStencil().Depth)

    // calls through a vtable
    vt: ID3DBlobVtbl
    vt.QueryInterface = fake_query
    vt.AddRef = fake_addref
    vt.Release = fake_release
    vt.GetBufferPointer = fake_pointer
    vt.GetBufferSize = fake_size
    fake := FakeBlob{&vt, 1, "shader bytes"}
    blob := cast[*ID3DBlob](&fake)
    print("blob", blob.GetBufferSize(), blob_bytes(blob), blob.AddRef(), blob.Release())
    unknown: *IUnknown
    device: *ID3D12Device
    print("query", blob.QueryInterface(&IID_IUnknown, &unknown) == S_OK, unknown == cast[*IUnknown](blob), fake.refs,
        blob.QueryInterface(&IID_ID3D12Device, &device) == E_NOINTERFACE, device == nil)
    com_release(&unknown)
    com_release(&unknown)
    print("release", unknown == nil, fake.refs)
}
'''


def emit_test(db):
    out = TEST_HEAD.rstrip('\n').split('\n') + ['']
    structs = [s for s in db.structs.values() if not s.union and not s.bitfield]
    chunk = 24
    for k in range(0, len(structs), chunk):
        out.append('fn layouts_%d(b: *u8) {' % (k // chunk))
        out.append('    a := cast[i64](b)')
        for s in structs[k:k + chunk]:
            size, _ = db.layout(('struct', s.name))
            out.append('    chk(sizeof[%s](), %d, "%s")' % (s.name, size, s.name))
            for f, off in db.offsets(s):
                out.append('    chk(cast[i64](&cast[*%s](b).%s) - a, %d, "%s.%s")' % (s.name, ident(f.name), off, s.name, f.name))
        out.append('}')
        out.append('')
    out.append('fn vtables() {')
    for name, methods in db.ifaces.items():
        out.append('    chk(sizeof[%sVtbl](), %d, "%sVtbl")' % (name, 8 * len(methods), name))
    out.append('}')
    out.append('')
    # every generic wrapper (COM out-parameters) instantiated once; never called, only compiled
    out.append('fn instantiate(o: **IUnknown) {')
    for name, methods in db.ifaces.items():
        generic = [(m, signature(db, m, name)) for m in methods]
        generic = [(m, s) for m, s in generic if s[5]]
        if not generic:
            continue
        out.append('    {')
        out.append('        x: *%s' % name)
        for m, (_, params, _, _, _, tparams) in generic:
            args = []
            for p in params[1:]:
                pname, pty = p.split(': ', 1)
                if pty.startswith('**T'):
                    args.append('o')
                elif pty[0] == '*':
                    args.append('nil')
                elif pty[0] in 'iuf' and pty[1:].isdigit():
                    args.append('0')
                else:
                    args.append('%s{}' % pty)
            out.append('        x.%s(%s)' % (m.name, ', '.join(args)))
        out.append('    }')
    out.append('}')
    out.append('')
    out.append('fn main() {')
    out.append('    helpers()')
    out.append('    scratch := alloc[u8](8192)')
    for k in range(0, len(structs), chunk):
        out.append('    layouts_%d(ptr(scratch))' % (k // chunk))
    out.append('    print("structs", %d, "layout checks", checked, "wrong", wrong)' % len(structs))
    out.append('    checked = 0')
    out.append('    vtables()')
    out.append('    print("vtables", checked, "wrong", wrong)')
    out.append('}')
    nfields = sum(len(s.fields) for s in structs)
    expected = '''S_OK true false S_FALSE true E_FAIL false true
DXGI_ERROR_DEVICE_REMOVED 887a0005 true
utf16 [65, 233, 8364, 55357, 56832, 122, 0]
guid 189819f1 [190, 84, 24, 33, 51, 155, 133, 247] true false
consts 0 49152 28 2755 5768 32
barrier 8 4294967295 4
clear 0.5 0.0
blob 12 shader bytes 2 1
query true true 2 true true
release true 1
structs %d layout checks %d wrong 0
vtables %d wrong 0
''' % (len(structs), len(structs) + nfields, len(db.ifaces))
    return '\n'.join(out) + '\n', expected


# ---- verification against the C compiler ---------------------------------------------------------

def emit_c(db):
    """A C translation unit of static assertions; returns (text, counts)."""
    c = ['#define COBJMACROS', '#define CINTERFACE', '#include <stddef.h>', '#include <windows.h>',
         '#include <d3d12.h>', '#include <d3d12sdklayers.h>', '#include <dxgi1_6.h>', '#include <dxgidebug.h>',
         '#include <d3dcompiler.h>', '#define CHECK(c) _Static_assert(c, #c)', '']
    cname = {v: k for k, v in RENAMED_INTERFACES.items()}
    counts = {'structs': 0, 'fields': 0, 'interfaces': 0, 'methods': 0, 'constants': 0}
    def member(f):
        """C name of a field; an anonymous union is located through its first member."""
        inner = db.structs.get(f.ty[1]) if f.ty[0] == 'struct' else None
        return member(inner.fields[0]) if inner and inner.anon else f.name

    for s in db.structs.values():
        if s.bitfield or s.anon:
            continue
        size, align = db.layout(('struct', s.name))
        counts['structs'] += 1
        if s.outer:   # written inline: reachable only as a member of the enclosing type
            c.append('CHECK(sizeof(((%s *)0)->%s) == %d);' % (s.outer, s.cpath, size))
            for f, off in db.offsets(s):
                c.append('CHECK(offsetof(%s, %s.%s) - offsetof(%s, %s) == %d);' % (s.outer, s.cpath, member(f), s.outer, s.cpath, off))
        else:
            c.append('CHECK(sizeof(%s) == %d);' % (s.name, size))
            c.append('CHECK(_Alignof(%s) == %d);' % (s.name, align))
            for f, off in db.offsets(s):
                c.append('CHECK(offsetof(%s, %s) == %d);' % (s.name, member(f), off))
        counts['fields'] += len(s.fields)
    for name, methods in db.ifaces.items():
        vt = cname.get(name, name) + 'Vtbl'
        c.append('CHECK(sizeof(%s) == %d);' % (vt, 8 * len(methods)))
        counts['interfaces'] += 1
        for slot, m in enumerate(methods):
            c.append('CHECK(offsetof(%s, %s) / 8 == %d);' % (vt, m.name, slot))
            counts['methods'] += 1
    for name, (al, items) in db.enums.items():
        c.append('CHECK(sizeof(%s) == 4);' % name)
        for item, value, _ in items:
            c.append('CHECK((long long)%s == %dLL);' % (item, value if value < 0x80000000 or al == 'u32' else value - (1 << 32)))
            counts['constants'] += 1
    for name, literal, value, typed in db.defines:
        if isinstance(value, float):
            c.append('CHECK((float)%s == (float)%r);' % (name, value))
        elif typed:
            c.append('CHECK((unsigned)%s == %uu);' % (name, value & 0xffffffff))
        else:
            c.append('CHECK((long long)%s == %dLL);' % (name, value))
        counts['constants'] += 1
    for name in WIN32_CONSTANTS:
        m = re.search(r'^const %s: (\w+) = (\w+)$' % name, PROLOGUE, re.M)
        c.append('CHECK((unsigned long long)(%s)%s == %sull);' % ({'u32': 'unsigned', 'i32': 'unsigned', 'u64': 'unsigned long long'}[m.group(1)], name, m.group(2)))
        counts['constants'] += 1
    c.append('CHECK((ULONG_PTR)IDC_ARROW == 32512);')
    return '\n'.join(c) + '\n', counts


def verify(db, include_dir):
    text, counts = emit_c(db)
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, 'dx12_verify.c')
        with open(path, 'w') as f:
            f.write(text)
        compilers = [['x86_64-w64-mingw32-gcc', '-fsyntax-only', '-w', path],
                     ['clang', '--target=x86_64-w64-mingw32', '-fsyntax-only', '-w', '-isystem', include_dir, path]]
        for cmd in compilers:
            try:
                r = subprocess.run(cmd, capture_output=True, text=True)
            except FileNotFoundError:
                continue
            if r.returncode != 0:
                sys.stderr.write(r.stderr[:6000])
                sys.exit('verification FAILED with ' + cmd[0])
            print('verified with %s: %d structs (%d field offsets), %d interfaces (%d vtable slots), %d constants' % (
                cmd[0], counts['structs'], counts['fields'], counts['interfaces'], counts['methods'], counts['constants']))
            return
    sys.exit('no Windows cross compiler found (x86_64-w64-mingw32-gcc or clang)')


def main():
    argv = sys.argv[1:]
    include_dir = next((d for d in INCLUDE_DIRS if os.path.exists(os.path.join(d, 'd3d12.h'))), None)
    if '--include' in argv:
        include_dir = argv[argv.index('--include') + 1]
    if not include_dir:
        sys.exit('d3d12.h not found; pass --include DIR')
    db = load(include_dir)
    module = emit_module(db)
    test, expected = emit_test(db)
    for rel, text in (('std/dx12.al', module), ('tests/std/dx12.al', test), ('tests/std/dx12.out', expected)):
        with open(os.path.join(ROOT, rel), 'w') as f:
            f.write(text)
    if '--quiet' not in argv:
        wrappers = sum(len(m) for m in db.ifaces.values())
        print('std/dx12.al: %d lines; %d enums, %d #defines, %d structs, %d GUIDs, %d interfaces, %d methods, %d functions' % (
            module.count('\n'), len(db.enums), len(db.defines), sum(1 for s in db.structs.values() if not s.union and not s.bitfield),
            len(db.guids), len(db.ifaces), wrappers, module.count('\nextern "d') ))
        for note in db.skipped:
            print('  skipped: ' + note[:150])
    if '--verify' in argv:
        verify(db, include_dir)


if __name__ == '__main__':
    main()

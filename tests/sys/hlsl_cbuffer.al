// hlsl_cbuffer_size and offsetof against the real HLSL compiler: each case is an AL struct and
// the cbuffer a shader declares for it. D3DCompile (d3dcompiler_47.dll) compiles the shader and
// its shader reflection (D3DReflect, ID3D12ShaderReflection) reports where it put every
// variable and struct member and the size of the cbuffer; the test compares them with
// offsetof of the AL fields and with hlsl_cbuffer_size. The last cases are layouts that
// hlsl_cbuffer_size rejects (tests/fail/hlsl_cbuffer.al): their reflected offsets are printed,
// the ones the compile errors name.
use std.dx12

// ---- the cases --------------------------------------------------------------------------------

struct Pair { x: f32, y: f32 }
struct Quad { x: f32, y: f32, pad: vec2 }
struct Point3 { p: vec3 }
struct Wide { v: vec4, w: f32, pad: vec3 }
struct Nested { a: f32, pad: vec3, inner: Pair, b: f32 }
struct DrawConsts { view_proj: mat4, model: mat4, tint: vec4, eye: vec4, fx: vec4 }

struct Vec2After { a: f32, b: vec2 }                                   // a float2 packs at 4
struct Vec2Moved { a: f32, b: vec2, pad: f32, c: vec2 }                // c would cross 16
struct Vec3After { a: f32, b: vec3 }
struct ArrayVec4 { a: [3]vec4, b: f32 }
struct MatAfter { a: f32, p0: f32, p1: f32, p2: f32, m: mat4 }
struct AfterStruct { s: Pair, z: f32 }                                  // z packs into s's register
struct StructStart { a: f32, pad: vec3, s: Point3 }
struct Flags { on: u32, f: f32 }                                        // HLSL bool: 4 bytes
struct Doubles { d: f64, f: f32, pad: f32, e: f64 }
struct DoubleAligned { f: f32, d: f64 }
struct StructArray { arr: [2]Wide, t: f32 }
struct MatVec { m: mat4, v: vec3, s: f32 }
struct QuadArray { s: [2]Quad, z: f32 }
struct Vec3Vec2 { a: vec3, pad: f32, b: vec2 }
struct Deep { a: f32, pad: vec3, s: Nested, c: f32 }
struct IntVec { i: i32, v: vec3, on: u32 }
struct ArrayAfter { a: f32, pad: vec3, b: [2]vec4, c: f32 }

const HLSL_STRUCTS = `
struct Pair { float x; float y; };
struct Quad { float x; float y; float2 pad; };
struct Point3 { float3 p; };
struct Wide { float4 v; float w; float3 pad; };
struct Nested { float a; float3 pad; Pair inner; float b; };
struct Inner { float4 a; float b; };
struct Big { double d; float f; };
`

struct Case {
    name: str
    body: str           // the members of the cbuffer
    first: str          // an expression that reads it (an unused cbuffer is left out)
    offsets: []i64      // offsetof of each variable and struct member, in declaration order
    size: i64           // hlsl_cbuffer_size; 0: a layout hlsl_cbuffer_size rejects
}

fn cases() -> []Case {
    return []Case{
        Case{"Vec2After", "float a; float2 b;", "a", []i64{offsetof[Vec2After](a), offsetof[Vec2After](b)}, hlsl_cbuffer_size[Vec2After]()},
        Case{"Vec2Moved", "float a; float2 b; float pad; float2 c;", "a", []i64{offsetof[Vec2Moved](a), offsetof[Vec2Moved](b),
            offsetof[Vec2Moved](pad), offsetof[Vec2Moved](c)}, hlsl_cbuffer_size[Vec2Moved]()},
        Case{"Vec3After", "float a; float3 b;", "a", []i64{offsetof[Vec3After](a), offsetof[Vec3After](b)}, hlsl_cbuffer_size[Vec3After]()},
        Case{"ArrayVec4", "float4 a[3]; float b;", "b", []i64{offsetof[ArrayVec4](a), offsetof[ArrayVec4](b)}, hlsl_cbuffer_size[ArrayVec4]()},
        Case{"MatAfter", "float a; float p0; float p1; float p2; float4x4 m;", "a", []i64{offsetof[MatAfter](a), offsetof[MatAfter](p0),
            offsetof[MatAfter](p1), offsetof[MatAfter](p2), offsetof[MatAfter](m)}, hlsl_cbuffer_size[MatAfter]()},
        Case{"AfterStruct", "Pair s; float z;", "z", []i64{offsetof[AfterStruct](s), offsetof[AfterStruct](s.x), offsetof[AfterStruct](s.y),
            offsetof[AfterStruct](z)}, hlsl_cbuffer_size[AfterStruct]()},
        Case{"StructStart", "float a; float3 pad; Point3 s;", "a", []i64{offsetof[StructStart](a), offsetof[StructStart](pad),
            offsetof[StructStart](s), offsetof[StructStart](s.p)}, hlsl_cbuffer_size[StructStart]()},
        Case{"Flags", "bool on; float f;", "f", []i64{offsetof[Flags](on), offsetof[Flags](f)}, hlsl_cbuffer_size[Flags]()},
        Case{"Doubles", "double d; float f; float pad; double e;", "f", []i64{offsetof[Doubles](d), offsetof[Doubles](f),
            offsetof[Doubles](pad), offsetof[Doubles](e)}, hlsl_cbuffer_size[Doubles]()},
        Case{"DoubleAligned", "float f; double d;", "f", []i64{offsetof[DoubleAligned](f), offsetof[DoubleAligned](d)}, hlsl_cbuffer_size[DoubleAligned]()},
        Case{"StructArray", "Wide arr[2]; float t;", "t", []i64{offsetof[StructArray](arr), offsetof[StructArray](arr[0].v),
            offsetof[StructArray](arr[0].w), offsetof[StructArray](arr[0].pad), offsetof[StructArray](t)}, hlsl_cbuffer_size[StructArray]()},
        Case{"MatVec", "float4x4 m; float3 v; float s;", "s", []i64{offsetof[MatVec](m), offsetof[MatVec](v), offsetof[MatVec](s)}, hlsl_cbuffer_size[MatVec]()},
        Case{"QuadArray", "Quad s[2]; float z;", "z", []i64{offsetof[QuadArray](s), offsetof[QuadArray](s[0].x), offsetof[QuadArray](s[0].y),
            offsetof[QuadArray](s[0].pad), offsetof[QuadArray](z)}, hlsl_cbuffer_size[QuadArray]()},
        Case{"Vec3Vec2", "float3 a; float pad; float2 b;", "pad", []i64{offsetof[Vec3Vec2](a), offsetof[Vec3Vec2](pad), offsetof[Vec3Vec2](b)}, hlsl_cbuffer_size[Vec3Vec2]()},
        Case{"Deep", "float a; float3 pad; Nested s; float c;", "c", []i64{offsetof[Deep](a), offsetof[Deep](pad), offsetof[Deep](s),
            offsetof[Deep](s.a), offsetof[Deep](s.pad), offsetof[Deep](s.inner), offsetof[Deep](s.inner.x), offsetof[Deep](s.inner.y),
            offsetof[Deep](s.b), offsetof[Deep](c)}, hlsl_cbuffer_size[Deep]()},
        Case{"IntVec", "int i; float3 v; bool on;", "v.x", []i64{offsetof[IntVec](i), offsetof[IntVec](v), offsetof[IntVec](on)}, hlsl_cbuffer_size[IntVec]()},
        Case{"ArrayAfter", "float a; float3 pad; float4 b[2]; float c;", "c", []i64{offsetof[ArrayAfter](a), offsetof[ArrayAfter](pad),
            offsetof[ArrayAfter](b), offsetof[ArrayAfter](c)}, hlsl_cbuffer_size[ArrayAfter]()},
        Case{"DrawConsts", "float4x4 view_proj; float4x4 model; float4 tint; float4 eye; float4 fx;", "fx.x", []i64{
            offsetof[DrawConsts](view_proj), offsetof[DrawConsts](model), offsetof[DrawConsts](tint), offsetof[DrawConsts](eye),
            offsetof[DrawConsts](fx)}, hlsl_cbuffer_size[DrawConsts]()},
        // rejected (tests/fail/hlsl_cbuffer.al): where HLSL puts what AL puts elsewhere
        Case{"Straddle", "float a; float b; float c; float2 d;", "a", nil, 0},
        Case{"FloatArray", "float ks[4]; float after;", "after", nil, 0},
        Case{"StructAfterFloat", "float a; Pair s;", "a", nil, 0},
        Case{"MatAfterFloat", "float a; float4x4 m;", "a", nil, 0},
        Case{"Vec4AfterFloat", "float a; float4 v;", "a", nil, 0},
        Case{"Vec3Array", "float3 vs[2];", "vs[0].x", nil, 0},
        Case{"InnerArray", "Inner items[2];", "items[0].b", nil, 0},
        Case{"AfterPadded", "Big s; float x;", "x", nil, 0},
    }
}

// ---- shader reflection (d3d12shader.h), only what the test calls ------------------------------

struct Reflection { vt: *ReflectionVtbl }
struct ReflectionVtbl {
    QueryInterface: fn(*Reflection, *GUID, **u8) -> i32
    AddRef: fn(*Reflection) -> u32
    Release: fn(*Reflection) -> u32
    GetDesc: fn(*Reflection, *u8) -> i32
    GetConstantBufferByIndex: fn(*Reflection, u32) -> *ReflBuffer
}
struct ReflBuffer { vt: *ReflBufferVtbl }       // ID3D12ShaderReflectionConstantBuffer (no IUnknown)
struct ReflBufferVtbl {
    GetDesc: fn(*ReflBuffer, *BufferDesc) -> i32
    GetVariableByIndex: fn(*ReflBuffer, u32) -> *ReflVariable
}
struct BufferDesc { Name: *u8, Type: u32, Variables: u32, Size: u32, uFlags: u32 }
struct ReflVariable { vt: *ReflVariableVtbl }
struct ReflVariableVtbl {
    GetDesc: fn(*ReflVariable, *VariableDesc) -> i32
    GetType: fn(*ReflVariable) -> *ReflType
}
struct VariableDesc {
    Name: *u8
    StartOffset: u32
    Size: u32
    uFlags: u32
    DefaultValue: *u8
    StartTexture: u32
    TextureSize: u32
    StartSampler: u32
    SamplerSize: u32
}
struct ReflType { vt: *ReflTypeVtbl }
struct ReflTypeVtbl {
    GetDesc: fn(*ReflType, *TypeDesc) -> i32
    GetMemberTypeByIndex: fn(*ReflType, u32) -> *ReflType
    GetMemberTypeByName: fn(*ReflType, *u8) -> *ReflType
    GetMemberTypeName: fn(*ReflType, u32) -> *u8
}
struct TypeDesc { Class: u32, Type: u32, Rows: u32, Columns: u32, Elements: u32, Members: u32, Offset: u32, Name: *u8 }

IID_ID3D12ShaderReflection := GUID{0x5a58797d, 0xa72c, 0x478d, [8]u8{0x8b, 0xa2, 0xef, 0xc6, 0xb0, 0xef, 0xe8, 0x8e}}

// the offsets of the members of a struct type at `base` (of its first element), in order
fn members(t: *ReflType, base: i64, out: *Vec[i64], names: *Vec[str]) {
    d: TypeDesc
    t.vt.GetDesc(t, &d)
    for i in 0..i64(d.Members) {
        m := t.vt.GetMemberTypeByIndex(t, u32(i))
        md: TypeDesc
        m.vt.GetDesc(m, &md)
        out.push(base + i64(md.Offset))
        names.push(from_cstr(t.vt.GetMemberTypeName(t, u32(i))))
        members(m, base + i64(md.Offset), out, names)
    }
}

// compiles the cbuffer of `c` and returns the size and the offsets reflection reports, with
// the names they belong to; "" or what failed
fn reflect(c: Case) -> (i64, Vec[i64], Vec[str], str) {
    offsets := vec[i64]()
    names := vec[str]()
    src := fmt(HLSL_STRUCTS, "cbuffer ", c.name, " : register(b0) { ", c.body, " };\n",
        "float4 main() : SV_POSITION { return float4((float)", c.first, ", 0.0, 0.0, 1.0); }\n")
    code: *ID3DBlob
    errors: *ID3DBlob
    hr := D3DCompile(ptr(src), u64(len(src)), nil, nil, nil, ptr("main"), ptr("vs_5_0"), 0, 0, &code, &errors)
    if FAILED(hr) {
        text := if errors != nil { from_cstr(errors.GetBufferPointer()) } else { hresult_code(hr) }
        return (0, offsets, names, fmt("D3DCompile: ", text))
    }
    r: *Reflection
    hr = D3DReflect(code.GetBufferPointer(), code.GetBufferSize(), &IID_ID3D12ShaderReflection, cast[**u8](&r))
    if FAILED(hr) {
        return (0, offsets, names, fmt("D3DReflect: ", hresult_code(hr)))
    }
    cb := r.vt.GetConstantBufferByIndex(r, 0)
    bd: BufferDesc
    if FAILED(cb.vt.GetDesc(cb, &bd)) {
        return (0, offsets, names, "no constant buffer")
    }
    for i in 0..i64(bd.Variables) {
        v := cb.vt.GetVariableByIndex(cb, u32(i))
        vd: VariableDesc
        v.vt.GetDesc(v, &vd)
        offsets.push(i64(vd.StartOffset))
        names.push(from_cstr(vd.Name))
        members(v.vt.GetType(v), i64(vd.StartOffset), &offsets, &names)
    }
    r.vt.Release(r)
    com_release(&code)
    com_release(&errors)
    (i64(bd.Size), offsets, names, "")
}

extern "kernel32.dll" fn GetModuleHandleA(name: *u8) -> i64
extern "kernel32.dll" fn GetProcAddress(module: i64, name: *u8) -> i64

fn main() -> i64 {
    // Wine's D3DReflect (vkd3d-shader, Wine 11.22) places doubles in a cbuffer unlike Windows'
    // D3DCompile (`float f; double d;`: d at 4, not 8): the rules are Windows'
    if GetProcAddress(GetModuleHandleA(cstr("ntdll.dll")), cstr("wine_get_version")) != 0 {
        print("Wine's shader reflection packs doubles unlike D3DCompile: runs on Windows (tests\\run.bat)")
        return 77
    }
    bad := 0
    for c in cases() {
        size, offsets, names, err := reflect(c)
        if starts_with(err, "D3DReflect") {
            print("no ID3D12ShaderReflection here:", err)          // status 77: SKIP (Wine)
            return 77
        }
        if err != "" {
            print(c.name, "failed:", err)
            return 1
        }
        if c.size == 0 {
            parts := vec[str]()
            for i, o in offsets {
                parts.push(fmt(names[i], " ", o))
            }
            print(c.name, "(rejected):", join(parts.items(), ", "), "size", size)
        } else if offsets.items() == c.offsets && size == c.size {
            print(c.name, "agrees:", offsets.len, "offsets, size", size)
        } else {
            print(c.name, "DIFFERS: reflection", offsets.items(), "size", size, "; AL", c.offsets, "size", c.size)
            bad += 1
        }
    }
    if bad > 0 { 1 } else { 0 }
}

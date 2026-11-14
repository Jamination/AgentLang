// std.shaderc: compiles GLSL and HLSL to SPIR-V at run time and checks the SPIR-V header, a
// compile error with its message, a macro definition, the preprocessor and an include callback.
use std.shaderc

const VERT = `#version 450
layout(location = 0) in vec2 pos;
layout(location = 0) out vec3 color;
void main() {
    color = vec3(SCALE);
    gl_Position = vec4(pos, 0.0, 1.0);
}
`

const HLSL = `float4 main(float4 p : POSITION) : SV_Position { return p * 2.0; }
`

const BROKEN = `#version 450
void main() { undeclared = 1; }
`

const WITH_INCLUDE = `#version 450
#extension GL_GOOGLE_include_directive : require
#include "common.glsl"
layout(local_size_x = 1) in;
void main() { float x = HALF; }
`

const COMMON = "#define HALF 0.5\n"

// The include resolver: every request gets COMMON. The result lives in a global (no allocation
// by the library), so the releaser has nothing to do.
included: shaderc_include_result
requests: i64

fn resolve(user: *u8, requested: *u8, kind: i32, requesting: *u8, depth: u64) -> *shaderc_include_result {
    requests += 1
    included.source_name = ptr("common.glsl")
    included.source_name_length = 11
    included.content = ptr(COMMON)
    included.content_length = u64(COMMON.len)
    &included
}

fn release_include(user: *u8, result: *shaderc_include_result) {}

// The SPIR-V words of a successful result (copied), or nil.
fn words(result: *u8) -> []u32 {
    if shaderc_result_get_compilation_status(result) != shaderc_compilation_status_success { return nil }
    n := i64(shaderc_result_get_length(result))
    out := alloc[u32](n / 4)
    memcopy(ptr(out), shaderc_result_get_bytes(result), n)
    out
}

fn main() -> i64 {
    compiler := shaderc_compiler_initialize()
    if compiler == nil {
        print("shaderc_compiler_initialize failed")
        return 1
    }
    options := shaderc_compile_options_initialize()
    shaderc_compile_options_set_target_env(options, shaderc_target_env_vulkan, u32(shaderc_env_version_vulkan_1_3))
    shaderc_compile_options_set_optimization_level(options, shaderc_optimization_level_performance)
    shaderc_compile_options_add_macro_definition(options, ptr("SCALE"), 5, ptr("0.5"), 3)

    r := shaderc_compile_into_spv(compiler, ptr(VERT), u64(VERT.len), shaderc_vertex_shader, ptr("v.vert"), ptr("main"), options)
    w := words(r)
    // SPIR-V 1.6 is what Vulkan 1.3 implies
    print("glsl:", w.len > 5, hex(u64(w[0])), "version", hex(u64(w[1])), "errors", shaderc_result_get_num_errors(r))
    shaderc_result_release(r)

    hlsl := shaderc_compile_options_clone(options)
    shaderc_compile_options_set_source_language(hlsl, shaderc_source_language_hlsl)
    r = shaderc_compile_into_spv(compiler, ptr(HLSL), u64(HLSL.len), shaderc_vertex_shader, ptr("v.hlsl"), ptr("main"), hlsl)
    w = words(r)
    print("hlsl:", w.len > 5 && w[0] == 0x07230203)
    shaderc_result_release(r)
    shaderc_compile_options_release(hlsl)

    r = shaderc_compile_into_spv(compiler, ptr(BROKEN), u64(BROKEN.len), shaderc_fragment_shader, ptr("broken.frag"), ptr("main"), nil)
    message := from_cstr(shaderc_result_get_error_message(r))
    print("broken:", shaderc_result_get_compilation_status(r) == shaderc_compilation_status_compilation_error,
        shaderc_result_get_num_errors(r) >= 1, contains_text(message, "broken.frag:2"), contains_text(message, "undeclared"))
    shaderc_result_release(r)

    pre := shaderc_compile_into_preprocessed_text(compiler, ptr(VERT), u64(VERT.len), shaderc_vertex_shader, ptr("v.vert"), ptr("main"), options)
    text := mkslice[u8](shaderc_result_get_bytes(pre), i64(shaderc_result_get_length(pre)))
    print("preprocessed: SCALE replaced", contains_text(text, "vec3(0.5)"))
    shaderc_result_release(pre)

    inc := shaderc_compile_options_initialize()
    shaderc_compile_options_set_include_callbacks(inc, cast[*u8](resolve), cast[*u8](release_include), nil)
    r = shaderc_compile_into_spv(compiler, ptr(WITH_INCLUDE), u64(WITH_INCLUDE.len), shaderc_compute_shader, ptr("c.comp"), ptr("main"), inc)
    print("include:", words(r).len > 5, "requests", requests)
    shaderc_result_release(r)
    shaderc_compile_options_release(inc)

    version: u32
    revision: u32
    shaderc_get_spv_version(&version, &revision)
    v: i32
    profile: i32
    ok := shaderc_parse_version_profile(ptr("310es"), &v, &profile)
    print("versions:", version >= 0x10000, ok, v, profile == shaderc_profile_es)

    shaderc_compile_options_release(options)
    shaderc_compiler_release(compiler)
    0
}

fn contains_text(s: str, sub: str) -> bool { find(s, sub) >= 0 }

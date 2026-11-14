# std.shaderc: GLSL and HLSL to SPIR-V at run time

`use std.shaderc` binds the C API of [shaderc](https://github.com/google/shaderc)
(`<shaderc/shaderc.h>`, `libshaderc_shared.so.1`): the compiler behind `glslc`, as a library.
It is the counterpart of `D3DCompile` in the Direct3D 12 bindings: a game can compile its
shaders while it runs, for example to reload them when their files change. It is a binding,
not a shader system: what to compile when, caching and error display are the program's.

Linux only (`--target windows` reports `use std.shaderc` as an error). A program that calls a
shaderc function is dynamically linked against `libshaderc_shared.so.1` (Arch: package
`shaderc`; Debian/Ubuntu: `libshaderc1`), which must then be installed where it runs. Shaders
that do not change at run time need neither the library nor this module: compile them when
building and embed the SPIR-V ([vk.md](vk.md#spir-v-shaders)).

## Mapping

Every name, parameter and value is that of the C header, so shaderc's documentation (the
comments in `shaderc.h`) applies directly.

| C | AL |
|---|----|
| `shaderc_compiler_t`, `shaderc_compile_options_t`, `shaderc_compilation_result_t` | `*u8` |
| the enums (`shaderc_shader_kind`, `shaderc_compilation_status`, `shaderc_target_env`, `shaderc_limit`, ...) | `i32`; their values are constants with the C names: `shaderc_vertex_shader`, `shaderc_compilation_status_success`, ... |
| `int` / `uint32_t` / `size_t` / `bool` | `i32` / `u32` / `u64` / `bool` |
| `const char*` | `*u8`: `ptr("main")` (literals are NUL-terminated), `cstr(s)`; read with `from_cstr` |
| `shaderc_include_result` | struct of the same name and layout |
| the include callbacks `shaderc_include_resolve_fn`, `shaderc_include_result_release_fn` | AL functions passed as `cast[*u8](f)` |

The source text is passed as pointer and length (`ptr(src), u64(src.len)`) and need not be
NUL-terminated. The library allocates the results; nothing of it uses the AL arena. Release
what you create: `shaderc_result_release`, `shaderc_compile_options_release`,
`shaderc_compiler_release`.

## Functions

Compiler and results:

| Function | Purpose |
|----------|---------|
| `shaderc_compiler_initialize() -> *u8`, `shaderc_compiler_release(compiler)` | create / destroy a compiler (one can be used from one thread at a time) |
| `shaderc_compile_into_spv(compiler, source_text, source_text_size, shader_kind, input_file_name, entry_point_name, additional_options) -> *u8` | compile to SPIR-V; `additional_options` may be `nil`; the file name only appears in messages |
| `shaderc_compile_into_spv_assembly(...)`, `shaderc_compile_into_preprocessed_text(...)` | the same parameters: SPIR-V assembly text, or the source after the preprocessor |
| `shaderc_assemble_into_spv(compiler, source_assembly, source_assembly_size, additional_options) -> *u8` | SPIR-V assembly text to SPIR-V |
| `shaderc_result_get_compilation_status(result) -> i32` | `shaderc_compilation_status_success`, `..._compilation_error`, `..._invalid_stage`, ... |
| `shaderc_result_get_bytes(result) -> *u8`, `shaderc_result_get_length(result) -> u64` | the output (SPIR-V words or text); valid until the result is released |
| `shaderc_result_get_error_message(result) -> *u8` | the messages, `file:line: error: ...` lines |
| `shaderc_result_get_num_errors(result)`, `shaderc_result_get_num_warnings(result) -> u64` | counts |
| `shaderc_result_release(result)` | frees the result |
| `shaderc_get_spv_version(version: *u32, revision: *u32)` | the SPIR-V version the library produces by default |
| `shaderc_parse_version_profile(str_: *u8, version: *i32, profile: *i32) -> bool` | parses `"450core"`, `"310es"`, ... |

Options (`options` is a `shaderc_compile_options_t`):

| Function | Purpose |
|----------|---------|
| `shaderc_compile_options_initialize() -> *u8`, `shaderc_compile_options_clone(options) -> *u8`, `shaderc_compile_options_release(options)` | create, copy, destroy |
| `shaderc_compile_options_set_source_language(options, lang)` | `shaderc_source_language_glsl` (default) or `shaderc_source_language_hlsl` |
| `shaderc_compile_options_set_target_env(options, target, version: u32)` | `shaderc_target_env_vulkan` with `u32(shaderc_env_version_vulkan_1_3)`: also selects the SPIR-V version (1.6 for Vulkan 1.3) |
| `shaderc_compile_options_set_target_spirv(options, version)` | a SPIR-V version explicitly (`shaderc_spirv_version_1_5`, ...) |
| `shaderc_compile_options_set_optimization_level(options, level)` | `shaderc_optimization_level_zero`, `_size`, `_performance` |
| `shaderc_compile_options_set_generate_debug_info(options)` | keep names and source lines (for RenderDoc and validation messages) |
| `shaderc_compile_options_add_macro_definition(options, name, name_length, value, value_length)` | `#define name value`; `value` may be `nil` with length 0 |
| `shaderc_compile_options_set_include_callbacks(options, resolver, result_releaser, user_data)` | handles `#include` (GLSL needs `#extension GL_GOOGLE_include_directive : require`); see below |
| `shaderc_compile_options_set_forced_version_profile(options, version, profile)` | override `#version` |
| `shaderc_compile_options_set_suppress_warnings(options)`, `shaderc_compile_options_set_warnings_as_errors(options)` | warning policy |
| `shaderc_compile_options_set_limit(options, limit, value)` | a GLSL resource limit (`shaderc_limit_max_...`) |
| `shaderc_compile_options_set_auto_bind_uniforms(options, auto_bind)`, `shaderc_compile_options_set_auto_map_locations(options, auto_map)`, `shaderc_compile_options_set_auto_combined_image_sampler(options, upgrade)` | assign bindings / locations the source leaves out; GL-style `sampler2D` handling |
| `shaderc_compile_options_set_binding_base(options, kind, base)`, `shaderc_compile_options_set_binding_base_for_stage(options, shader_kind, kind, base)`, `shaderc_compile_options_set_preserve_bindings(options, preserve_bindings)` | binding numbers for automatically bound resources (`shaderc_uniform_kind_...`) |
| `shaderc_compile_options_set_hlsl_io_mapping(options, hlsl_iomap)`, `shaderc_compile_options_set_hlsl_offsets(options, hlsl_offsets)`, `shaderc_compile_options_set_hlsl_functionality1(options, enable)`, `shaderc_compile_options_set_hlsl_16bit_types(options, enable)` | HLSL specifics |
| `shaderc_compile_options_set_hlsl_register_set_and_binding(options, reg, set, binding)`, `shaderc_compile_options_set_hlsl_register_set_and_binding_for_stage(options, shader_kind, reg, set, binding)` | map an HLSL register (`"t4"`) to a descriptor set and binding (strings) |
| `shaderc_compile_options_set_max_id_bound(options, max_id_bound)`, `shaderc_compile_options_set_vulkan_rules_relaxed(options, enable)`, `shaderc_compile_options_set_invert_y(options, enable)`, `shaderc_compile_options_set_nan_clamp(options, enable)` | the remaining switches of `shaderc.h` |

## Example: compile a file for hot reload

```
use std.shaderc

// SPIR-V words of a GLSL file, or the error messages.
fn compile(compiler: *u8, options: *u8, path: str, kind: i32) -> ([]u32, str) {
    src, ok := read_file(path)
    if !ok { return (nil, fmt("cannot read ", path)) }
    r := shaderc_compile_into_spv(compiler, ptr(src), u64(src.len), kind, cstr(path), ptr("main"), options)
    defer { shaderc_result_release(r) }
    if shaderc_result_get_compilation_status(r) != shaderc_compilation_status_success {
        return (nil, clone(from_cstr(shaderc_result_get_error_message(r))))
    }
    words := alloc[u32](i64(shaderc_result_get_length(r)) / 4)
    memcopy(ptr(words), shaderc_result_get_bytes(r), words.len * 4)
    (words, "")
}

fn main() {
    compiler := shaderc_compiler_initialize()
    options := shaderc_compile_options_initialize()
    shaderc_compile_options_set_target_env(options, shaderc_target_env_vulkan, u32(shaderc_env_version_vulkan_1_3))
    words, err := compile(compiler, options, "shaders/mesh.vert", shaderc_vertex_shader)
    if err != "" { eprint(err) } else { print("SPIR-V words:", words.len) }
    shaderc_compile_options_release(options)
    shaderc_compiler_release(compiler)
}
```

The words go into `VkShaderModuleCreateInfo.pCode` (`codeSize` in bytes); after
`vkCreateShaderModule` they are no longer needed. To reload, compare the file's modification
time each frame or second (`std.os`), recompile, and on success rebuild the pipelines that use
the module (after `vkDeviceWaitIdle`, or once the frames in flight that use the old pipeline
are done).

## Include callbacks

The resolver is called for each `#include` with the requested name and returns a pointer to a
`shaderc_include_result` that stays valid until the releaser is called for it. An empty
`source_name` means the include failed; `content` then holds the error message.

```
included: shaderc_include_result     // one global is enough when includes are not nested

fn resolve(user: *u8, requested: *u8, kind: i32, requesting: *u8, depth: u64) -> *shaderc_include_result {
    name := from_cstr(requested)     // kind: shaderc_include_type_relative ("x") or _standard (<x>)
    text, _ := read_file(concat("shaders/", name))
    included = shaderc_include_result{cstr(name), u64(name.len), ptr(text), u64(text.len), nil}
    &included
}
fn release_include(user: *u8, result: *shaderc_include_result) {}

shaderc_compile_options_set_include_callbacks(options, cast[*u8](resolve), cast[*u8](release_include), nil)
```

`tests/sys/shaderc.al` compiles GLSL (checking the SPIR-V magic number `0x07230203` and the
version) and HLSL, a source with an error, a macro definition, the preprocessor and an include
callback; it is skipped when `libshaderc_shared.so.1` is missing.

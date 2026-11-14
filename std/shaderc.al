// std.shaderc: bindings for shaderc's C API (<shaderc/shaderc.h>, libshaderc_shared.so.1):
// GLSL and HLSL to SPIR-V at run time, for example to reload shaders while a game runs. Names,
// parameters and values are those of the C header. Mapping: shaderc_compiler_t,
// shaderc_compile_options_t and shaderc_compilation_result_t are `*u8`; the enums (also
// shaderc_shader_kind, shaderc_compilation_status) and `int` are `i32`; size_t is `u64`; `bool`
// is `bool`; `const char*` is `*u8` (string literals are NUL-terminated: `ptr("main")`).
// Linux only. See docs/std/shaderc.md.

// ---- shaderc_target_env ----
const shaderc_target_env_vulkan: i32 = 0
const shaderc_target_env_opengl: i32 = 1
const shaderc_target_env_opengl_compat: i32 = 2
const shaderc_target_env_webgpu: i32 = 3
const shaderc_target_env_default: i32 = 0

// ---- shaderc_env_version (also the `version` of set_target_env: u32) ----
const shaderc_env_version_vulkan_1_0: i32 = 0x400000
const shaderc_env_version_vulkan_1_1: i32 = 0x401000
const shaderc_env_version_vulkan_1_2: i32 = 0x402000
const shaderc_env_version_vulkan_1_3: i32 = 0x403000
const shaderc_env_version_vulkan_1_4: i32 = 0x404000
const shaderc_env_version_opengl_4_5: i32 = 450
const shaderc_env_version_webgpu: i32 = 451

// ---- shaderc_spirv_version ----
const shaderc_spirv_version_1_0: i32 = 0x010000
const shaderc_spirv_version_1_1: i32 = 0x010100
const shaderc_spirv_version_1_2: i32 = 0x010200
const shaderc_spirv_version_1_3: i32 = 0x010300
const shaderc_spirv_version_1_4: i32 = 0x010400
const shaderc_spirv_version_1_5: i32 = 0x010500
const shaderc_spirv_version_1_6: i32 = 0x010600

// ---- shaderc_compilation_status ----
const shaderc_compilation_status_success: i32 = 0
const shaderc_compilation_status_invalid_stage: i32 = 1
const shaderc_compilation_status_compilation_error: i32 = 2
const shaderc_compilation_status_internal_error: i32 = 3
const shaderc_compilation_status_null_result_object: i32 = 4
const shaderc_compilation_status_invalid_assembly: i32 = 5
const shaderc_compilation_status_validation_error: i32 = 6
const shaderc_compilation_status_transformation_error: i32 = 7
const shaderc_compilation_status_configuration_error: i32 = 8

// ---- shaderc_source_language ----
const shaderc_source_language_glsl: i32 = 0
const shaderc_source_language_hlsl: i32 = 1

// ---- shaderc_shader_kind ----
const shaderc_vertex_shader: i32 = 0
const shaderc_fragment_shader: i32 = 1
const shaderc_compute_shader: i32 = 2
const shaderc_geometry_shader: i32 = 3
const shaderc_tess_control_shader: i32 = 4
const shaderc_tess_evaluation_shader: i32 = 5
const shaderc_glsl_vertex_shader: i32 = 0
const shaderc_glsl_fragment_shader: i32 = 1
const shaderc_glsl_compute_shader: i32 = 2
const shaderc_glsl_geometry_shader: i32 = 3
const shaderc_glsl_tess_control_shader: i32 = 4
const shaderc_glsl_tess_evaluation_shader: i32 = 5
const shaderc_glsl_infer_from_source: i32 = 6
const shaderc_glsl_default_vertex_shader: i32 = 7
const shaderc_glsl_default_fragment_shader: i32 = 8
const shaderc_glsl_default_compute_shader: i32 = 9
const shaderc_glsl_default_geometry_shader: i32 = 10
const shaderc_glsl_default_tess_control_shader: i32 = 11
const shaderc_glsl_default_tess_evaluation_shader: i32 = 12
const shaderc_spirv_assembly: i32 = 13
const shaderc_raygen_shader: i32 = 14
const shaderc_anyhit_shader: i32 = 15
const shaderc_closesthit_shader: i32 = 16
const shaderc_miss_shader: i32 = 17
const shaderc_intersection_shader: i32 = 18
const shaderc_callable_shader: i32 = 19
const shaderc_glsl_raygen_shader: i32 = 14
const shaderc_glsl_anyhit_shader: i32 = 15
const shaderc_glsl_closesthit_shader: i32 = 16
const shaderc_glsl_miss_shader: i32 = 17
const shaderc_glsl_intersection_shader: i32 = 18
const shaderc_glsl_callable_shader: i32 = 19
const shaderc_glsl_default_raygen_shader: i32 = 20
const shaderc_glsl_default_anyhit_shader: i32 = 21
const shaderc_glsl_default_closesthit_shader: i32 = 22
const shaderc_glsl_default_miss_shader: i32 = 23
const shaderc_glsl_default_intersection_shader: i32 = 24
const shaderc_glsl_default_callable_shader: i32 = 25
const shaderc_task_shader: i32 = 26
const shaderc_mesh_shader: i32 = 27
const shaderc_glsl_task_shader: i32 = 26
const shaderc_glsl_mesh_shader: i32 = 27
const shaderc_glsl_default_task_shader: i32 = 28
const shaderc_glsl_default_mesh_shader: i32 = 29

// ---- shaderc_profile ----
const shaderc_profile_none: i32 = 0
const shaderc_profile_core: i32 = 1
const shaderc_profile_compatibility: i32 = 2
const shaderc_profile_es: i32 = 3

// ---- shaderc_optimization_level ----
const shaderc_optimization_level_zero: i32 = 0
const shaderc_optimization_level_size: i32 = 1
const shaderc_optimization_level_performance: i32 = 2

// ---- shaderc_uniform_kind ----
const shaderc_uniform_kind_image: i32 = 0
const shaderc_uniform_kind_sampler: i32 = 1
const shaderc_uniform_kind_texture: i32 = 2
const shaderc_uniform_kind_buffer: i32 = 3
const shaderc_uniform_kind_storage_buffer: i32 = 4
const shaderc_uniform_kind_unordered_access_view: i32 = 5

// ---- shaderc_include_type ----
const shaderc_include_type_relative: i32 = 0
const shaderc_include_type_standard: i32 = 1

// ---- shaderc_limit ----
const shaderc_limit_max_lights: i32 = 0
const shaderc_limit_max_clip_planes: i32 = 1
const shaderc_limit_max_texture_units: i32 = 2
const shaderc_limit_max_texture_coords: i32 = 3
const shaderc_limit_max_vertex_attribs: i32 = 4
const shaderc_limit_max_vertex_uniform_components: i32 = 5
const shaderc_limit_max_varying_floats: i32 = 6
const shaderc_limit_max_vertex_texture_image_units: i32 = 7
const shaderc_limit_max_combined_texture_image_units: i32 = 8
const shaderc_limit_max_texture_image_units: i32 = 9
const shaderc_limit_max_fragment_uniform_components: i32 = 10
const shaderc_limit_max_draw_buffers: i32 = 11
const shaderc_limit_max_vertex_uniform_vectors: i32 = 12
const shaderc_limit_max_varying_vectors: i32 = 13
const shaderc_limit_max_fragment_uniform_vectors: i32 = 14
const shaderc_limit_max_vertex_output_vectors: i32 = 15
const shaderc_limit_max_fragment_input_vectors: i32 = 16
const shaderc_limit_min_program_texel_offset: i32 = 17
const shaderc_limit_max_program_texel_offset: i32 = 18
const shaderc_limit_max_clip_distances: i32 = 19
const shaderc_limit_max_compute_work_group_count_x: i32 = 20
const shaderc_limit_max_compute_work_group_count_y: i32 = 21
const shaderc_limit_max_compute_work_group_count_z: i32 = 22
const shaderc_limit_max_compute_work_group_size_x: i32 = 23
const shaderc_limit_max_compute_work_group_size_y: i32 = 24
const shaderc_limit_max_compute_work_group_size_z: i32 = 25
const shaderc_limit_max_compute_uniform_components: i32 = 26
const shaderc_limit_max_compute_texture_image_units: i32 = 27
const shaderc_limit_max_compute_image_uniforms: i32 = 28
const shaderc_limit_max_compute_atomic_counters: i32 = 29
const shaderc_limit_max_compute_atomic_counter_buffers: i32 = 30
const shaderc_limit_max_varying_components: i32 = 31
const shaderc_limit_max_vertex_output_components: i32 = 32
const shaderc_limit_max_geometry_input_components: i32 = 33
const shaderc_limit_max_geometry_output_components: i32 = 34
const shaderc_limit_max_fragment_input_components: i32 = 35
const shaderc_limit_max_image_units: i32 = 36
const shaderc_limit_max_combined_image_units_and_fragment_outputs: i32 = 37
const shaderc_limit_max_combined_shader_output_resources: i32 = 38
const shaderc_limit_max_image_samples: i32 = 39
const shaderc_limit_max_vertex_image_uniforms: i32 = 40
const shaderc_limit_max_tess_control_image_uniforms: i32 = 41
const shaderc_limit_max_tess_evaluation_image_uniforms: i32 = 42
const shaderc_limit_max_geometry_image_uniforms: i32 = 43
const shaderc_limit_max_fragment_image_uniforms: i32 = 44
const shaderc_limit_max_combined_image_uniforms: i32 = 45
const shaderc_limit_max_geometry_texture_image_units: i32 = 46
const shaderc_limit_max_geometry_output_vertices: i32 = 47
const shaderc_limit_max_geometry_total_output_components: i32 = 48
const shaderc_limit_max_geometry_uniform_components: i32 = 49
const shaderc_limit_max_geometry_varying_components: i32 = 50
const shaderc_limit_max_tess_control_input_components: i32 = 51
const shaderc_limit_max_tess_control_output_components: i32 = 52
const shaderc_limit_max_tess_control_texture_image_units: i32 = 53
const shaderc_limit_max_tess_control_uniform_components: i32 = 54
const shaderc_limit_max_tess_control_total_output_components: i32 = 55
const shaderc_limit_max_tess_evaluation_input_components: i32 = 56
const shaderc_limit_max_tess_evaluation_output_components: i32 = 57
const shaderc_limit_max_tess_evaluation_texture_image_units: i32 = 58
const shaderc_limit_max_tess_evaluation_uniform_components: i32 = 59
const shaderc_limit_max_tess_patch_components: i32 = 60
const shaderc_limit_max_patch_vertices: i32 = 61
const shaderc_limit_max_tess_gen_level: i32 = 62
const shaderc_limit_max_viewports: i32 = 63
const shaderc_limit_max_vertex_atomic_counters: i32 = 64
const shaderc_limit_max_tess_control_atomic_counters: i32 = 65
const shaderc_limit_max_tess_evaluation_atomic_counters: i32 = 66
const shaderc_limit_max_geometry_atomic_counters: i32 = 67
const shaderc_limit_max_fragment_atomic_counters: i32 = 68
const shaderc_limit_max_combined_atomic_counters: i32 = 69
const shaderc_limit_max_atomic_counter_bindings: i32 = 70
const shaderc_limit_max_vertex_atomic_counter_buffers: i32 = 71
const shaderc_limit_max_tess_control_atomic_counter_buffers: i32 = 72
const shaderc_limit_max_tess_evaluation_atomic_counter_buffers: i32 = 73
const shaderc_limit_max_geometry_atomic_counter_buffers: i32 = 74
const shaderc_limit_max_fragment_atomic_counter_buffers: i32 = 75
const shaderc_limit_max_combined_atomic_counter_buffers: i32 = 76
const shaderc_limit_max_atomic_counter_buffer_size: i32 = 77
const shaderc_limit_max_transform_feedback_buffers: i32 = 78
const shaderc_limit_max_transform_feedback_interleaved_components: i32 = 79
const shaderc_limit_max_cull_distances: i32 = 80
const shaderc_limit_max_combined_clip_and_cull_distances: i32 = 81
const shaderc_limit_max_samples: i32 = 82
const shaderc_limit_max_mesh_output_vertices_nv: i32 = 83
const shaderc_limit_max_mesh_output_primitives_nv: i32 = 84
const shaderc_limit_max_mesh_work_group_size_x_nv: i32 = 85
const shaderc_limit_max_mesh_work_group_size_y_nv: i32 = 86
const shaderc_limit_max_mesh_work_group_size_z_nv: i32 = 87
const shaderc_limit_max_task_work_group_size_x_nv: i32 = 88
const shaderc_limit_max_task_work_group_size_y_nv: i32 = 89
const shaderc_limit_max_task_work_group_size_z_nv: i32 = 90
const shaderc_limit_max_mesh_view_count_nv: i32 = 91
const shaderc_limit_max_mesh_output_vertices_ext: i32 = 92
const shaderc_limit_max_mesh_output_primitives_ext: i32 = 93
const shaderc_limit_max_mesh_work_group_size_x_ext: i32 = 94
const shaderc_limit_max_mesh_work_group_size_y_ext: i32 = 95
const shaderc_limit_max_mesh_work_group_size_z_ext: i32 = 96
const shaderc_limit_max_task_work_group_size_x_ext: i32 = 97
const shaderc_limit_max_task_work_group_size_y_ext: i32 = 98
const shaderc_limit_max_task_work_group_size_z_ext: i32 = 99
const shaderc_limit_max_mesh_view_count_ext: i32 = 100
const shaderc_limit_max_dual_source_draw_buffers_ext: i32 = 101

// What an include resolver returns (C layout). An empty source_name means the include failed;
// content then holds the error message.
struct shaderc_include_result {
    source_name: *u8            // const char*
    source_name_length: u64     // size_t
    content: *u8                // const char*
    content_length: u64         // size_t
    user_data: *u8              // void*
}

// ---- compiler ----
// shaderc_compiler_t shaderc_compiler_initialize(void)
extern "libshaderc_shared.so.1" fn shaderc_compiler_initialize() -> *u8
// void shaderc_compiler_release(shaderc_compiler_t)
extern "libshaderc_shared.so.1" fn shaderc_compiler_release(compiler: *u8)

// ---- options ----
// shaderc_compile_options_t shaderc_compile_options_initialize(void)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_initialize() -> *u8
// shaderc_compile_options_t shaderc_compile_options_clone(const shaderc_compile_options_t options)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_clone(options: *u8) -> *u8
// void shaderc_compile_options_release(shaderc_compile_options_t options)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_release(options: *u8)
// void shaderc_compile_options_add_macro_definition(shaderc_compile_options_t options, const char* name, size_t name_length, const char* value, size_t value_length)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_add_macro_definition(options: *u8, name: *u8, name_length: u64, value: *u8, value_length: u64)
// void shaderc_compile_options_set_source_language(shaderc_compile_options_t options, shaderc_source_language lang)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_source_language(options: *u8, lang: i32)
// void shaderc_compile_options_set_generate_debug_info(shaderc_compile_options_t options)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_generate_debug_info(options: *u8)
// void shaderc_compile_options_set_optimization_level(shaderc_compile_options_t options, shaderc_optimization_level level)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_optimization_level(options: *u8, level: i32)
// void shaderc_compile_options_set_forced_version_profile(shaderc_compile_options_t options, int version, shaderc_profile profile)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_forced_version_profile(options: *u8, version: i32, profile: i32)
// void shaderc_compile_options_set_include_callbacks(shaderc_compile_options_t options, shaderc_include_resolve_fn resolver, shaderc_include_result_release_fn result_releaser, void* user_data)
//   resolver: fn(user_data: *u8, requested_source: *u8, type: i32, requesting_source: *u8, include_depth: u64) -> *shaderc_include_result
//   result_releaser: fn(user_data: *u8, include_result: *shaderc_include_result); pass both with cast[*u8](f)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_include_callbacks(options: *u8, resolver: *u8, result_releaser: *u8, user_data: *u8)
// void shaderc_compile_options_set_suppress_warnings(shaderc_compile_options_t options)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_suppress_warnings(options: *u8)
// void shaderc_compile_options_set_target_env(shaderc_compile_options_t options, shaderc_target_env target, uint32_t version)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_target_env(options: *u8, target: i32, version: u32)
// void shaderc_compile_options_set_target_spirv(shaderc_compile_options_t options, shaderc_spirv_version version)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_target_spirv(options: *u8, version: i32)
// void shaderc_compile_options_set_warnings_as_errors(shaderc_compile_options_t options)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_warnings_as_errors(options: *u8)
// void shaderc_compile_options_set_limit(shaderc_compile_options_t options, shaderc_limit limit, int value)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_limit(options: *u8, limit: i32, value: i32)
// void shaderc_compile_options_set_auto_bind_uniforms(shaderc_compile_options_t options, bool auto_bind)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_auto_bind_uniforms(options: *u8, auto_bind: bool)
// void shaderc_compile_options_set_auto_combined_image_sampler(shaderc_compile_options_t options, bool upgrade)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_auto_combined_image_sampler(options: *u8, upgrade: bool)
// void shaderc_compile_options_set_hlsl_io_mapping(shaderc_compile_options_t options, bool hlsl_iomap)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_hlsl_io_mapping(options: *u8, hlsl_iomap: bool)
// void shaderc_compile_options_set_hlsl_offsets(shaderc_compile_options_t options, bool hlsl_offsets)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_hlsl_offsets(options: *u8, hlsl_offsets: bool)
// void shaderc_compile_options_set_binding_base(shaderc_compile_options_t options, shaderc_uniform_kind kind, uint32_t base)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_binding_base(options: *u8, kind: i32, base: u32)
// void shaderc_compile_options_set_binding_base_for_stage(shaderc_compile_options_t options, shaderc_shader_kind shader_kind, shaderc_uniform_kind kind, uint32_t base)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_binding_base_for_stage(options: *u8, shader_kind: i32, kind: i32, base: u32)
// void shaderc_compile_options_set_preserve_bindings(shaderc_compile_options_t options, bool preserve_bindings)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_preserve_bindings(options: *u8, preserve_bindings: bool)
// void shaderc_compile_options_set_max_id_bound(shaderc_compile_options_t options, uint32_t max_id_bound)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_max_id_bound(options: *u8, max_id_bound: u32)
// void shaderc_compile_options_set_auto_map_locations(shaderc_compile_options_t options, bool auto_map)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_auto_map_locations(options: *u8, auto_map: bool)
// void shaderc_compile_options_set_hlsl_register_set_and_binding_for_stage(shaderc_compile_options_t options, shaderc_shader_kind shader_kind, const char* reg, const char* set, const char* binding)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_hlsl_register_set_and_binding_for_stage(options: *u8, shader_kind: i32, reg: *u8, set: *u8, binding: *u8)
// void shaderc_compile_options_set_hlsl_register_set_and_binding(shaderc_compile_options_t options, const char* reg, const char* set, const char* binding)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_hlsl_register_set_and_binding(options: *u8, reg: *u8, set: *u8, binding: *u8)
// void shaderc_compile_options_set_hlsl_functionality1(shaderc_compile_options_t options, bool enable)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_hlsl_functionality1(options: *u8, enable: bool)
// void shaderc_compile_options_set_hlsl_16bit_types(shaderc_compile_options_t options, bool enable)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_hlsl_16bit_types(options: *u8, enable: bool)
// void shaderc_compile_options_set_vulkan_rules_relaxed(shaderc_compile_options_t options, bool enable)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_vulkan_rules_relaxed(options: *u8, enable: bool)
// void shaderc_compile_options_set_invert_y(shaderc_compile_options_t options, bool enable)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_invert_y(options: *u8, enable: bool)
// void shaderc_compile_options_set_nan_clamp(shaderc_compile_options_t options, bool enable)
extern "libshaderc_shared.so.1" fn shaderc_compile_options_set_nan_clamp(options: *u8, enable: bool)

// ---- compiling ----
// shaderc_compilation_result_t shaderc_compile_into_spv(const shaderc_compiler_t compiler, const char* source_text, size_t source_text_size, shaderc_shader_kind shader_kind, const char* input_file_name, const char* entry_point_name, const shaderc_compile_options_t additional_options)
extern "libshaderc_shared.so.1" fn shaderc_compile_into_spv(compiler: *u8, source_text: *u8, source_text_size: u64, shader_kind: i32, input_file_name: *u8, entry_point_name: *u8, additional_options: *u8) -> *u8
// shaderc_compilation_result_t shaderc_compile_into_spv_assembly(...same parameters...)
extern "libshaderc_shared.so.1" fn shaderc_compile_into_spv_assembly(compiler: *u8, source_text: *u8, source_text_size: u64, shader_kind: i32, input_file_name: *u8, entry_point_name: *u8, additional_options: *u8) -> *u8
// shaderc_compilation_result_t shaderc_compile_into_preprocessed_text(...same parameters...)
extern "libshaderc_shared.so.1" fn shaderc_compile_into_preprocessed_text(compiler: *u8, source_text: *u8, source_text_size: u64, shader_kind: i32, input_file_name: *u8, entry_point_name: *u8, additional_options: *u8) -> *u8
// shaderc_compilation_result_t shaderc_assemble_into_spv(const shaderc_compiler_t compiler, const char* source_assembly, size_t source_assembly_size, const shaderc_compile_options_t additional_options)
extern "libshaderc_shared.so.1" fn shaderc_assemble_into_spv(compiler: *u8, source_assembly: *u8, source_assembly_size: u64, additional_options: *u8) -> *u8

// ---- results ----
// void shaderc_result_release(shaderc_compilation_result_t result)
extern "libshaderc_shared.so.1" fn shaderc_result_release(result: *u8)
// size_t shaderc_result_get_length(const shaderc_compilation_result_t result)
extern "libshaderc_shared.so.1" fn shaderc_result_get_length(result: *u8) -> u64
// size_t shaderc_result_get_num_warnings(const shaderc_compilation_result_t result)
extern "libshaderc_shared.so.1" fn shaderc_result_get_num_warnings(result: *u8) -> u64
// size_t shaderc_result_get_num_errors(const shaderc_compilation_result_t result)
extern "libshaderc_shared.so.1" fn shaderc_result_get_num_errors(result: *u8) -> u64
// shaderc_compilation_status shaderc_result_get_compilation_status(const shaderc_compilation_result_t)
extern "libshaderc_shared.so.1" fn shaderc_result_get_compilation_status(result: *u8) -> i32
// const char* shaderc_result_get_bytes(const shaderc_compilation_result_t result)
extern "libshaderc_shared.so.1" fn shaderc_result_get_bytes(result: *u8) -> *u8
// const char* shaderc_result_get_error_message(const shaderc_compilation_result_t result)
extern "libshaderc_shared.so.1" fn shaderc_result_get_error_message(result: *u8) -> *u8

// ---- versions ----
// void shaderc_get_spv_version(unsigned int* version, unsigned int* revision)
extern "libshaderc_shared.so.1" fn shaderc_get_spv_version(version: *u32, revision: *u32)
// bool shaderc_parse_version_profile(const char* str, int* version, shaderc_profile* profile)
extern "libshaderc_shared.so.1" fn shaderc_parse_version_profile(str_: *u8, version: *i32, profile: *i32) -> bool

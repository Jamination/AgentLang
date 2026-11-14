#version 450
// One textured quad per instance. The instances come from a storage buffer that the compute
// shader instances.comp writes every frame; the camera from the per-frame uniform buffer.
layout(location = 0) in vec2 in_pos;
layout(location = 1) in vec2 in_uv;

layout(set = 0, binding = 0) uniform Frame {
    mat4 view_proj;
    vec4 params;            // x: seconds since start
} frame;

struct Instance {
    vec4 offset_scale;      // xy: centre, z: depth, w: half size
    vec4 tint;
};
layout(set = 0, binding = 2, std430) readonly buffer Instances { Instance inst[]; };

layout(push_constant) uniform Push { vec4 tint; } pc;

layout(location = 0) out vec2 uv;
layout(location = 1) out vec4 tint;

void main() {
    Instance i = inst[gl_InstanceIndex];
    vec3 p = vec3(in_pos * i.offset_scale.w + i.offset_scale.xy, i.offset_scale.z);
    gl_Position = frame.view_proj * vec4(p, 1.0);
    uv = in_uv;
    tint = i.tint * pc.tint;
}

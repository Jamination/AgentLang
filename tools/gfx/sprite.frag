// The fragment shader of std.gfx, Vulkan (std/gfx_vk.al): the same as ps_main of sprite.hlsl.
#version 450
layout(set = 0, binding = 0) uniform sampler2D tex;
layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_color;
layout(location = 0) out vec4 out_color;

void main() {
    vec4 t = textureLod(tex, v_uv, 0.0);
    out_color = (v_uv.x < -1.0 ? vec4(1.0) : t) * v_color;
}

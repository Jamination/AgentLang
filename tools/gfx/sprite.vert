// The vertex shader of std.gfx, Vulkan (std/gfx_vk.al): the same as vs_main of sprite.hlsl.
#version 450
layout(push_constant) uniform View { vec4 view; } pc;
layout(location = 0) in vec2 pos;
layout(location = 1) in vec2 uv;
layout(location = 2) in vec4 color;
layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_color;

void main() {
    gl_Position = vec4(pos * pc.view.xy + pc.view.zw, 0.0, 1.0);
    v_uv = uv;
    v_color = color;
}

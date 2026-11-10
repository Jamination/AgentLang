#version 450
// Fragment shader of tests/sys/vk_triangle.al and examples/vk_triangle.al.
// Build: glslangValidator -V tri.frag -o tri.frag.spv
layout(location = 0) in vec3 v_color;
layout(location = 0) out vec4 out_color;

void main() {
    out_color = vec4(v_color, 1.0);
}

#version 450
// A full-screen triangle over the portrait swapchain image. The texture
// coordinate it hands on is the point of the app's landscape image that
// lands on this pixel once the picture is turned by 90 degrees.
layout(location = 0) out vec2 uv;
layout(push_constant) uniform Push { int rot; } p;

void main()
{
    vec2 t = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(t * 2.0 - 1.0, 0.0, 1.0);
    // t: 0..1 across the portrait image, y down
    uv = (p.rot == 270) ? vec2(1.0 - t.y, t.x) : vec2(t.y, 1.0 - t.x);
}

#include <metal_stdlib>
using namespace metal;

// Placeholder resource for the first-pass package scaffold.
// Future CRT rendering will credit Timothy Lottes' public-domain shader.
[[vertex]] float4 phosphorVertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0)
    };
    return float4(positions[vertexID], 0.0, 1.0);
}

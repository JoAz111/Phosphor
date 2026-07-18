#include <metal_stdlib>
using namespace metal;

struct alignas(16) ShaderUniforms {
    float2 drawableSize;
    float2 sourceSize;
    float4 effect;
    float4 effect2;
    float4 yuvRow0;
    float4 yuvRow1;
    float4 yuvRow2;
};

struct FullscreenVertex {
    float4 position [[position]];
    float2 uv;
};

struct CRTGeometry {
    float2 tubePosition;
    float2 sourceUV;
    float2 texelSize;
    bool visible;
};

struct LinearRGBInput {
    float3 center;
    float3 left;
    float3 right;
    float3 up;
    float3 down;
};

constexpr sampler phosphorLinearSampler(
    coord::normalized,
    address::clamp_to_edge,
    filter::linear
);

float3 phosphorSRGBToLinear(float3 color) {
    float3 low = color / 12.92;
    float3 high = pow((color + 0.055) / 1.055, float3(2.4));
    return select(low, high, color > 0.04045);
}

CRTGeometry phosphorGeometry(float2 outputUV, constant ShaderUniforms &uniforms) {
    CRTGeometry result;
    result.tubePosition = float2(0.0);
    result.sourceUV = float2(0.5);
    result.texelSize = 1.0 / max(uniforms.sourceSize, float2(1.0));
    result.visible = false;

    if (any(uniforms.drawableSize <= 0.0) || any(uniforms.sourceSize <= 0.0)) {
        return result;
    }

    float sourceAspect = uniforms.sourceSize.x / uniforms.sourceSize.y;
    float drawableAspect = uniforms.drawableSize.x / uniforms.drawableSize.y;
    float2 fitScale = float2(1.0);
    if (sourceAspect > drawableAspect) {
        fitScale.y = drawableAspect / sourceAspect;
    } else {
        fitScale.x = sourceAspect / drawableAspect;
    }

    float2 fittedPosition = outputUV * 2.0 - 1.0;
    if (any(abs(fittedPosition) > fitScale)) {
        return result;
    }

    float2 tube = fittedPosition / fitScale;
    float cornerDistance = length(max(abs(tube) - 0.94, 0.0));
    if (cornerDistance > 0.06) {
        return result;
    }

    float curvature = saturate(uniforms.effect.y) * dot(tube, tube);
    float2 curved = tube * (1.0 + curvature);
    if (any(abs(curved) > 1.0)) {
        return result;
    }

    result.tubePosition = tube;
    result.sourceUV = curved * 0.5 + 0.5;
    result.visible = true;
    return result;
}

float3 phosphorSampleNV12(
    texture2d<float> lumaTexture,
    texture2d<float> chromaTexture,
    float2 uv,
    constant ShaderUniforms &uniforms
) {
    float y = lumaTexture.sample(phosphorLinearSampler, uv).r;
    float2 chroma = chromaTexture.sample(phosphorLinearSampler, uv).rg;
    float4 yuv = float4(y, chroma, 1.0);
    float3 encodedRGB = float3(
        dot(uniforms.yuvRow0, yuv),
        dot(uniforms.yuvRow1, yuv),
        dot(uniforms.yuvRow2, yuv)
    );
    return phosphorSRGBToLinear(saturate(encodedRGB));
}

float3 phosphorSampleBGRA(texture2d<float> colorTexture, float2 uv) {
    return phosphorSRGBToLinear(saturate(
        colorTexture.sample(phosphorLinearSampler, uv).rgb
    ));
}

// Compact native treatment informed by classic public-domain CRT techniques.
float4 phosphorApplyCRT(
    float2 outputUV,
    LinearRGBInput input,
    constant ShaderUniforms &uniforms
) {
    CRTGeometry geometry = phosphorGeometry(outputUV, uniforms);
    if (!geometry.visible) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    float glowAmount = saturate(uniforms.effect2.x);
    float3 glow = input.center * 0.44
        + (input.left + input.right + input.up + input.down) * 0.14;
    float3 treated = mix(input.center, glow, glowAmount * 0.32);
    treated += glow * (glowAmount * 0.06);

    float sourceLine = geometry.sourceUV.y * uniforms.sourceSize.y;
    float scanWave = 0.5 + 0.5 * cos(sourceLine * M_PI_F);
    float scanModulation = mix(1.0, 0.72 + 0.28 * scanWave, saturate(uniforms.effect.z));
    treated *= scanModulation;

    uint stripe = uint(max(outputUV.x * uniforms.drawableSize.x, 0.0)) % 3;
    float3 grille = stripe == 0 ? float3(1.12, 0.94, 0.94)
        : (stripe == 1 ? float3(0.94, 1.12, 0.94) : float3(0.94, 0.94, 1.12));
    treated *= mix(float3(1.0), grille, saturate(uniforms.effect.w));

    float2 edge = geometry.tubePosition * geometry.tubePosition;
    float vignetteShape = saturate(dot(edge, edge) * 0.5);
    float vignette = 1.0 - saturate(uniforms.effect2.y) * vignetteShape * 0.55;
    treated *= vignette;

    float intensity = saturate(uniforms.effect.x);
    return float4(saturate(mix(input.center, treated, intensity)), 1.0);
}

vertex FullscreenVertex phosphorFullscreenVertex(uint vertexID [[vertex_id]]) {
    float2 triangle = float2((vertexID << 1) & 2, vertexID & 2);
    FullscreenVertex output;
    output.position = float4(triangle * 2.0 - 1.0, 0.0, 1.0);
    output.uv = float2(triangle.x, 1.0 - triangle.y);
    return output;
}

fragment float4 phosphorCRTFragmentNV12(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> lumaTexture [[texture(0)]],
    texture2d<float> chromaTexture [[texture(1)]]
) {
    CRTGeometry geometry = phosphorGeometry(input.uv, uniforms);
    float2 uv = geometry.sourceUV;
    float2 dx = float2(geometry.texelSize.x, 0.0);
    float2 dy = float2(0.0, geometry.texelSize.y);
    LinearRGBInput color = {
        phosphorSampleNV12(lumaTexture, chromaTexture, uv, uniforms),
        phosphorSampleNV12(lumaTexture, chromaTexture, uv - dx, uniforms),
        phosphorSampleNV12(lumaTexture, chromaTexture, uv + dx, uniforms),
        phosphorSampleNV12(lumaTexture, chromaTexture, uv - dy, uniforms),
        phosphorSampleNV12(lumaTexture, chromaTexture, uv + dy, uniforms)
    };
    return phosphorApplyCRT(input.uv, color, uniforms);
}

fragment float4 phosphorCRTFragmentBGRA(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> colorTexture [[texture(0)]]
) {
    CRTGeometry geometry = phosphorGeometry(input.uv, uniforms);
    float2 uv = geometry.sourceUV;
    float2 dx = float2(geometry.texelSize.x, 0.0);
    float2 dy = float2(0.0, geometry.texelSize.y);
    LinearRGBInput color = {
        phosphorSampleBGRA(colorTexture, uv),
        phosphorSampleBGRA(colorTexture, uv - dx),
        phosphorSampleBGRA(colorTexture, uv + dx),
        phosphorSampleBGRA(colorTexture, uv - dy),
        phosphorSampleBGRA(colorTexture, uv + dy)
    };
    return phosphorApplyCRT(input.uv, color, uniforms);
}

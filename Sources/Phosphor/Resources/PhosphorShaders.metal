#include <metal_stdlib>
using namespace metal;

/*
    Phosphor CRT renderer — Metal adaptation of CRT-Guest-Advanced HD.

    CRT-Guest-Advanced copyright (C) 2018-2025 guest(r).
    Metal translation and macOS video adaptation copyright (C) 2026 Joey Azizoff.

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
    GNU General Public License for more details.

    Modified for Phosphor on 2026-07-19. This is a Metal translation and
    adaptation, not an unmodified upstream file. It preserves Guest Advanced's pass structure, Gaussian light
    spread, luminance-dependent beam reconstruction, and physical-pixel
    phosphor mask while adapting the input stage for AVFoundation video.
*/

struct alignas(16) ShaderUniforms {
    float4 drawableSize;
    float4 sourceSize;
    float4 rasterSize;
    float4 effect;
    float4 effect2;
    float4 guestBeam;
    float4 guestLight;
    float4 yuvRow0;
    float4 yuvRow1;
    float4 yuvRow2;
    float4 frameData;
};

struct FullscreenVertex {
    float4 position [[position]];
    float2 uv;
};

struct FittedGeometry {
    float2 tubePosition;
    float2 sourceUV;
    bool visible;
};

constexpr sampler phosphorLinearSampler(
    coord::normalized,
    address::clamp_to_edge,
    filter::linear
);

constexpr sampler phosphorNearestSampler(
    coord::normalized,
    address::clamp_to_edge,
    filter::nearest
);

float3 phosphorSRGBToLinear(float3 color) {
    float3 low = color / 12.92;
    float3 high = pow((color + 0.055) / 1.055, float3(2.4));
    return select(low, high, color > 0.04045);
}

float phosphorMaximum(float3 color) {
    return max(max(color.r, color.g), color.b);
}

float3 guestPlant(float3 color, float level) {
    return color * level / (phosphorMaximum(color) + 0.00001);
}

FittedGeometry phosphorAspectFit(
    float2 outputUV,
    constant ShaderUniforms &uniforms
) {
    FittedGeometry result;
    result.tubePosition = float2(0.0);
    result.sourceUV = float2(0.5);
    result.visible = false;

    if (any(uniforms.drawableSize.xy <= 0.0)
        || any(uniforms.sourceSize.xy <= 0.0)) {
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

    result.tubePosition = fittedPosition / fitScale;
    result.sourceUV = result.tubePosition * 0.5 + 0.5;
    result.visible = true;
    return result;
}

FittedGeometry guestWarp(
    FittedGeometry fitted,
    constant ShaderUniforms &uniforms
) {
    if (!fitted.visible) {
        return fitted;
    }

    // CRT-Guest-Advanced curvature model, with equal X/Y control for the
    // compact Phosphor UI.
    float curve = saturate(uniforms.effect.y);
    float curveShape = 0.25;
    float2 position = fitted.tubePosition;
    float2 curved = float2(
        position.x * rsqrt(max(1.0 - curveShape * position.y * position.y, 0.001)),
        position.y * rsqrt(max(1.0 - curveShape * position.x * position.x, 0.001))
    );
    position = mix(position, curved, float2(curve / curveShape));
    if (any(abs(position) > 1.0)) {
        fitted.visible = false;
        return fitted;
    }

    fitted.tubePosition = position;
    fitted.sourceUV = position * 0.5 + 0.5;
    return fitted;
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

vertex FullscreenVertex phosphorFullscreenVertex(uint vertexID [[vertex_id]]) {
    float2 triangle = float2((vertexID << 1) & 2, vertexID & 2);
    FullscreenVertex output;
    output.position = float4(triangle * 2.0 - 1.0, 0.0, 1.0);
    output.uv = float2(triangle.x, 1.0 - triangle.y);
    return output;
}

fragment float4 phosphorBypassFragmentNV12(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> lumaTexture [[texture(0)]],
    texture2d<float> chromaTexture [[texture(1)]]
) {
    FittedGeometry fitted = phosphorAspectFit(input.uv, uniforms);
    if (!fitted.visible) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    return float4(phosphorSampleNV12(
        lumaTexture,
        chromaTexture,
        fitted.sourceUV,
        uniforms
    ), 1.0);
}

fragment float4 phosphorBypassFragmentBGRA(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> colorTexture [[texture(0)]]
) {
    FittedGeometry fitted = phosphorAspectFit(input.uv, uniforms);
    if (!fitted.visible) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    return float4(phosphorSampleBGRA(colorTexture, fitted.sourceUV), 1.0);
}

fragment float4 phosphorDecodeFragmentNV12(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> lumaTexture [[texture(0)]],
    texture2d<float> chromaTexture [[texture(1)]]
) {
    return float4(phosphorSampleNV12(
        lumaTexture,
        chromaTexture,
        input.uv,
        uniforms
    ), 1.0);
}

fragment float4 phosphorDecodeFragmentBGRA(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> colorTexture [[texture(0)]]
) {
    return float4(phosphorSampleBGRA(colorTexture, input.uv), 1.0);
}

// Adapted from CRT-Guest-Advanced HD afterglow0.slang. The AVFoundation
// source texture replaces RetroArch's OriginalHistory0 input.
fragment float4 guestAfterglowFragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> currentTexture [[texture(0)]],
    texture2d<float> historyTexture [[texture(1)]]
) {
    float3 current = currentTexture.sample(phosphorLinearSampler, input.uv).rgb;
    if (uniforms.frameData.y < 0.5) {
        return float4(current, 1.0);
    }

    float2 dx = float2(uniforms.rasterSize.z, 0.0);
    float2 dy = float2(0.0, uniforms.rasterSize.w);
    float3 history0 = historyTexture.sample(phosphorLinearSampler, input.uv).rgb;
    float3 history1 = historyTexture.sample(phosphorLinearSampler, input.uv - dx).rgb;
    float3 history2 = historyTexture.sample(phosphorLinearSampler, input.uv + dx).rgb;
    float3 history3 = historyTexture.sample(phosphorLinearSampler, input.uv - dy).rgb;
    float3 history4 = historyTexture.sample(phosphorLinearSampler, input.uv + dy).rgb;
    float3 spread = (2.5 * history0 + history1 + history2 + history3 + history4) / 6.5;

    float threshold = 4.0 / 255.0;
    float freshPixel = smoothstep(
        threshold,
        2.0 * threshold,
        phosphorMaximum(current)
    );
    float3 persisted = max(mix(spread, history0, 0.81) - 1.25 / 255.0, 0.0);
    float3 result = mix(
        max(current, persisted * uniforms.effect2.w),
        current,
        freshPixel
    );
    return float4(result, freshPixel);
}

float guestHorizontalGaussian(float x) {
    constexpr float sigma = 0.50;
    return exp(-(x * x) / (2.0 * sigma * sigma));
}

// Port of crt-guest-advanced-hd-pass1.slang's Gaussian/subtractive
// horizontal reconstruction. Alpha carries Guest's spike-resistant peak.
fragment float4 guestHDSharpenFragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> source [[texture(0)]]
) {
    float f = 0.5 - fract(uniforms.rasterSize.x * input.uv.x);
    float2 tex = (floor(uniforms.rasterSize.xy * input.uv) + 0.5)
        * uniforms.rasterSize.zw;
    float2 dx = float2(uniforms.rasterSize.z, 0.0);

    float3 color = 0.0;
    float3 colorMax = 0.0;
    float3 colorMin = 1.0;
    float weightedPeak = 0.0;
    float weightedPeakSum = 0.0;
    float weightSum = 0.0;

    constexpr float subtractiveSharpness = 1.0;
    constexpr float maximumSharpness = 0.15;
    constexpr float ringing = 0.20;
    float sharp = guestHorizontalGaussian(1.0) * subtractiveSharpness;

    for (int offset = -2; offset <= 2; ++offset) {
        float3 pixel = source.sample(
            phosphorLinearSampler,
            tex + float(offset) * dx
        ).rgb;
        float samplePosition = float(offset) + f;
        float weight = guestHorizontalGaussian(samplePosition) - sharp;
        float falloff = saturate(abs(samplePosition) - 1.0);
        if (weight < 0.0) {
            weight = max(weight, mix(-maximumSharpness, 0.0, pow(falloff, 1.20)));
        } else {
            colorMax = max(colorMax, pixel);
            colorMin = min(colorMin, pixel);
            float peakWeight = weight * (dot(pixel, float3(0.2126, 0.7152, 0.0722)) + 0.025);
            weightedPeak += peakWeight * phosphorMaximum(pixel);
            weightedPeakSum += peakWeight;
        }
        color += weight * pixel;
        weightSum += weight;
    }

    color /= max(weightSum, 0.00001);
    color = saturate(mix(clamp(color, colorMin, colorMax), color, ringing));
    float peak = weightedPeak / max(weightedPeakSum, 0.00001);
    peak = saturate(mix(phosphorMaximum(color), peak, 1.0));
    return float4(color, peak);
}

float guestGaussian(float x, float sigma) {
    return exp(-(x * x) / (2.0 * sigma * sigma));
}

fragment float4 guestGlowHorizontalFragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> source [[texture(0)]]
) {
    float3 color = 0.0;
    float weightSum = 0.0;
    float2 dx = float2(uniforms.rasterSize.z, 0.0);
    for (int offset = -6; offset <= 6; ++offset) {
        float weight = guestGaussian(float(offset), 1.20);
        color += weight * source.sample(
            phosphorLinearSampler,
            input.uv + float(offset) * dx
        ).rgb;
        weightSum += weight;
    }
    return float4(color / weightSum, 1.0);
}

fragment float4 guestGlowVerticalFragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> source [[texture(0)]]
) {
    float3 color = 0.0;
    float weightSum = 0.0;
    float2 dy = float2(0.0, 1.0 / max(float(source.get_height()), 1.0));
    for (int offset = -6; offset <= 6; ++offset) {
        float weight = guestGaussian(float(offset), 1.20);
        color += weight * source.sample(
            phosphorLinearSampler,
            input.uv + float(offset) * dy
        ).rgb;
        weightSum += weight;
    }
    return float4(color / weightSum, 1.0);
}

fragment float4 guestBloomHorizontalFragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> source [[texture(0)]]
) {
    float4 color = 0.0;
    float weightSum = 0.0;
    float2 dx = float2(uniforms.rasterSize.z, 0.0);
    for (int offset = -3; offset <= 3; ++offset) {
        float weight = guestGaussian(float(offset), 0.75);
        float3 pixel = source.sample(
            phosphorLinearSampler,
            input.uv + float(offset) * dx
        ).rgb;
        float peak = phosphorMaximum(pixel);
        color += weight * float4(pixel, peak * peak * peak);
        weightSum += weight;
    }
    color /= weightSum;
    return float4(color.rgb, pow(max(color.a, 0.0), 1.0 / 3.0));
}

fragment float4 guestBloomVerticalFragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> source [[texture(0)]]
) {
    float4 color = 0.0;
    float weightSum = 0.0;
    float2 dy = float2(0.0, 1.0 / max(float(source.get_height()), 1.0));
    for (int offset = -3; offset <= 3; ++offset) {
        float weight = guestGaussian(float(offset), 0.60);
        float4 pixel = source.sample(
            phosphorLinearSampler,
            input.uv + float(offset) * dy
        );
        pixel.a = pixel.a * pixel.a * pixel.a;
        color += weight * pixel;
        weightSum += weight;
    }
    color /= weightSum;
    return float4(color.rgb, pow(max(color.a, 0.0), 0.175));
}

float guestBeamCenterWeight(float x) {
    return exp2(-10.0 * x * x);
}

float3 guestBeamWeight(
    float distance,
    float peak,
    float shape,
    float3 normalizedColor,
    constant ShaderUniforms &uniforms
) {
    float beamWidth = mix(uniforms.guestBeam.z, uniforms.guestBeam.w, peak);
    float3 saturation = mix(
        float3(1.0 + 1.5 * uniforms.effect.z),
        float3(1.0),
        normalizedColor
    );
    float exponent = distance * beamWidth;
    return exp2(-shape * exponent * exponent * saturation);
}

// Port of crt-guest-advanced-hd-pass2.slang's central beam reconstruction.
// Dark pixels produce narrow beams; bright pixels excite wider beams.
fragment float4 guestHDBeamFragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> sharpened [[texture(0)]],
    texture2d<float> bloomTexture [[texture(1)]],
    texture2d<float> prepass [[texture(2)]]
) {
    FittedGeometry fitted = guestWarp(phosphorAspectFit(input.uv, uniforms), uniforms);
    if (!fitted.visible) {
        return float4(0.0);
    }

    float rasterPosition = fitted.sourceUV.y * uniforms.rasterSize.y - 0.5;
    float fraction = fract(rasterPosition);
    float2 center = float2(
        fitted.sourceUV.x,
        (floor(rasterPosition) + 0.5) * uniforms.rasterSize.w
    );
    float2 dy = float2(0.0, uniforms.rasterSize.w);

    float4 firstSample = sharpened.sample(phosphorLinearSampler, center);
    float4 secondSample = sharpened.sample(phosphorLinearSampler, center + dy);
    float3 color1 = pow(max(firstSample.rgb, 0.0), float3(2.40 / 2.20));
    float3 color2 = pow(max(secondSample.rgb, 0.0), float3(2.40 / 2.20));

    float weightCenter1 = guestBeamCenterWeight(fraction);
    float weightCenter2 = guestBeamCenterWeight(1.0 - fraction);
    float3 interpolated = (
        color1 * weightCenter1 + color2 * weightCenter2
    ) / max(weightCenter1 + weightCenter2, 0.00001);

    float peak1 = pow(max(firstSample.a, phosphorMaximum(interpolated)), 1.0);
    float peak2 = pow(max(secondSample.a, phosphorMaximum(interpolated)), 1.0);
    float shape1 = mix(uniforms.guestBeam.x, uniforms.guestBeam.y, fraction);
    float shape2 = mix(uniforms.guestBeam.x, uniforms.guestBeam.y, 1.0 - fraction);
    float maximum1 = phosphorMaximum(color1) + 0.0000001;
    float maximum2 = phosphorMaximum(color2) + 0.0000001;
    float3 normalized1 = color1 / maximum1;
    float3 normalized2 = color2 / maximum2;

    float3 weight1 = guestBeamWeight(
        fraction,
        peak1,
        shape1,
        normalized1,
        uniforms
    );
    float3 weight2 = guestBeamWeight(
        1.0 - fraction,
        peak2,
        shape2,
        normalized2,
        uniforms
    );
    float maximumWeight = phosphorMaximum(weight1 + weight2);
    if (maximumWeight > 1.0) {
        weight1 /= maximumWeight;
        weight2 /= maximumWeight;
    }

    float3 beam = color1 * weight1 + color2 * weight2;
    beam = pow(max(beam, 0.0), float3(2.20 / 2.40));
    float3 smoothImage = prepass.sample(phosphorLinearSampler, fitted.sourceUV).rgb;
    float3 color = mix(smoothImage, beam, saturate(uniforms.effect.z));

    // Preserve Guest's peak channel in alpha for brightness-adaptive masks.
    float peak = phosphorMaximum(interpolated);
    return float4(saturate(color), saturate(peak));
}

// CRT-Guest-Advanced aperture-grille mask type 6. The brightness-dependent
// mixing is what makes dark phosphors discrete while allowing highlights to
// spread naturally into neighboring phosphors.
float3 guestApertureMask(
    float2 physicalPixel,
    float brightness,
    float control,
    float maskScale
) {
    float2 maskCoordinate = floor(physicalPixel / max(maskScale, 1.0));
    uint stripe = uint(fmod(maskCoordinate.x, 3.0));
    float3 emitter = stripe == 0
        ? float3(1.0, 0.0, 0.0)
        : (stripe == 1 ? float3(0.0, 1.0, 0.0) : float3(0.0, 0.0, 1.0));

    float strength = 1.0 - pow(1.0 - saturate(control), 2.2);
    float3 darkMask = saturate(mix(
        float3(1.0),
        emitter,
        1.10 * strength
    ));
    float3 brightMask = saturate(mix(
        float3(1.0),
        emitter,
        0.55 * strength
    ));
    return mix(darkMask, brightMask, saturate(brightness));
}

float guestCorner(FittedGeometry fitted, constant ShaderUniforms &uniforms) {
    float2 edge = fitted.tubePosition * fitted.tubePosition;
    float vignetteShape = saturate(dot(edge, edge) * 0.5);
    float vignette = 1.0 - saturate(uniforms.effect2.y) * vignetteShape * 0.72;

    float2 rounded = max(abs(fitted.tubePosition) - 0.94, 0.0);
    float corner = 1.0 - smoothstep(0.035, 0.065, length(rounded));
    return vignette * corner;
}

// Port/adaptation of deconvergence-hd.slang's final physical-pixel mask,
// brightness compensation, bloom, glow, and glass integration.
fragment float4 guestPhosphorMaskFragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> beamTexture [[texture(0)]],
    texture2d<float> rawTexture [[texture(1)]],
    texture2d<float> glowTexture [[texture(2)]],
    texture2d<float> bloomTexture [[texture(3)]]
) {
    FittedGeometry fitted = phosphorAspectFit(input.uv, uniforms);
    FittedGeometry warped = guestWarp(fitted, uniforms);
    if (!warped.visible) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    float4 beamSample = beamTexture.sample(phosphorLinearSampler, input.uv);
    float3 raw = rawTexture.sample(phosphorLinearSampler, warped.sourceUV).rgb;
    float3 bloom = bloomTexture.sample(phosphorLinearSampler, warped.sourceUV).rgb;
    float3 glow = glowTexture.sample(phosphorLinearSampler, warped.sourceUV).rgb;

    float brightness = max(beamSample.a, phosphorMaximum(beamSample.rgb));
    float maskBrightness = pow(saturate(brightness), 1.40 / 2.20);
    float3 mask = guestApertureMask(
        input.position.xy,
        maskBrightness,
        uniforms.effect.w,
        uniforms.effect2.z
    );

    constexpr float maskGamma = 2.40;
    constexpr float inputGamma = 2.20;
    float3 color = pow(max(beamSample.rgb, 0.0), float3(maskGamma / inputGamma));
    color *= mask;
    color = pow(max(color, 0.0), float3(inputGamma / maskGamma));

    float brightBoost = mix(
        uniforms.guestLight.z,
        uniforms.guestLight.w,
        maskBrightness
    );
    color *= brightBoost;

    float glowControl = saturate(uniforms.effect2.x);
    float bloomStrength = uniforms.guestLight.x + 0.24 * glowControl;
    float halationStrength = uniforms.guestLight.y + 0.15 * glowControl;
    float glowStrength = 0.04 + 0.32 * glowControl;

    // Bloom crosses mask boundaries; halation is biased red like light
    // scattered through a CRT's glass and phosphor substrate.
    color += bloom * bloomStrength;
    color += bloom * float3(0.55, 0.18, 0.06) * halationStrength;
    color += glow * glowStrength;

    color *= guestCorner(warped, uniforms);
    float3 treated = saturate(color);
    float3 result = mix(raw, treated, saturate(uniforms.effect.x));
    return float4(saturate(result), 1.0);
}

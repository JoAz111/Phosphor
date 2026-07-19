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
    float4 guestColor;
    float4 guestScan;
    float4 guestMask;
    float4 yuvRow0;
    float4 yuvRow1;
    float4 yuvRow2;
    float4 frameData;
    float4 temporalData;
    float4 tubeData;
    float4 videoData;
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

// The mask geometry is uniform for an entire frame. Specializing it when the
// pipeline is created lets Apple GPU compilation completely remove the unused
// aperture-only or slot-mask branch from the native-pixel final pass.
constant bool guestUsesSlotMask [[function_constant(0)]];

float3 phosphorSRGBToLinear(float3 color) {
    float3 low = color / 12.92;
    float3 high = pow((color + 0.055) / 1.055, float3(2.4));
    return select(low, high, color > 0.04045);
}

float phosphorMaximum(float3 color) {
    return max(max(color.r, color.g), color.b);
}

// A CRT's visible bloom comes from high-energy phosphor excitation rather than
// a uniform blur of the whole picture. Linear-light soft-knee extraction keeps
// blacks black while allowing midtones to enter the halo gradually.
float3 guestHighlightEnergy(float3 color) {
    float peak = phosphorMaximum(max(color, 0.0));
    float gate = smoothstep(0.10, 0.75, peak);
    return max(color, 0.0) * gate;
}

// Reserve highlight headroom for the additive light passes, then roll it into
// the SDR drawable without a hard white clip. Values below the knee are exact.
float3 guestSoftClip(float3 color) {
    constexpr float knee = 0.86;
    float3 positive = max(color, 0.0);
    float3 excess = max(positive - knee, 0.0);
    return min(positive, knee)
        + (1.0 - knee) * (1.0 - exp(-excess / (1.0 - knee)));
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
    // A real horizontal deflection stage never holds phase with mathematical
    // precision. Keep the displacement sub-pixel and mostly near the edges.
    float edgeLoad = smoothstep(0.35, 1.0, abs(position.y));
    float lineJitter = sin(
        uniforms.temporalData.x * 67.0
        + position.y * uniforms.rasterSize.y * 2.39996
    );
    position.x += lineJitter
        * edgeLoad
        * (0.08 + 0.12 * uniforms.tubeData.z)
        * uniforms.drawableSize.z
        * 2.0;
    if (any(abs(position) > 1.0)) {
        fitted.visible = false;
        return fitted;
    }

    fitted.tubePosition = position;
    fitted.sourceUV = position * 0.5 + 0.5;
    return fitted;
}

float3 phosphorSampleEncodedNV12(
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
    return saturate(encodedRGB);
}

float3 phosphorSampleEncodedBGRA(texture2d<float> colorTexture, float2 uv) {
    return saturate(colorTexture.sample(phosphorLinearSampler, uv).rgb);
}

// Reconstructs the bandwidth and channel coupling of the selected analog input.
// RGB remains untouched; S-Video shares only chroma bandwidth, while composite
// adds asymmetric chroma delay, carrier-dependent dot crawl, and cross-color.
float3 guestAnalogSignal(
    float3 center,
    float3 left,
    float3 right,
    float3 farLeft,
    float3 farRight,
    float2 uv,
    constant ShaderUniforms &uniforms
) {
    float signalType = uniforms.videoData.z;
    if (signalType < 0.5) {
        return center;
    }

    constexpr float3 lumaWeights = float3(0.299, 0.587, 0.114);
    float centerLuma = dot(center, lumaWeights);
    float leftLuma = dot(left, lumaWeights);
    float rightLuma = dot(right, lumaWeights);
    float farLeftLuma = dot(farLeft, lumaWeights);
    float farRightLuma = dot(farRight, lumaWeights);
    float3 centerChroma = center - centerLuma;
    float3 chroma = (
        (left - leftLuma)
        + 2.0 * centerChroma
        + (right - rightLuma)
    ) * 0.25;
    if (signalType < 1.5) {
        return saturate(centerLuma + chroma);
    }

    float luma = 0.08 * farLeftLuma
        + 0.18 * leftLuma
        + 0.48 * centerLuma
        + 0.18 * rightLuma
        + 0.08 * farRightLuma;
    float3 delayedChroma = (
        2.0 * (farLeft - farLeftLuma)
        + 3.0 * (left - leftLuma)
        + 2.0 * centerChroma
        + (right - rightLuma)
    ) / 8.0;

    float sourceLine = floor(uv.y * uniforms.sourceSize.y);
    float carrier = uv.x * uniforms.sourceSize.x * 1.5707963
        + uniforms.frameData.x * 1.5707963;
    bool usesPAL = signalType > 2.5;
    if (usesPAL && fmod(sourceLine, 2.0) >= 1.0) {
        delayedChroma *= 0.96;
        carrier += 3.1415927;
    }

    float horizontalEdge = rightLuma - leftLuma;
    float crawl = sin(carrier);
    float3 crossColor = horizontalEdge
        * crawl
        * (usesPAL ? 0.018 : 0.035)
        * float3(0.85, -0.34, 0.72);
    float3 dotCrawl = delayedChroma
        * cos(carrier * 0.5 + sourceLine * 1.5707963)
        * (usesPAL ? 0.018 : 0.032);
    return saturate(luma + delayedChroma + crossColor + dotCrawl);
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
    return float4(phosphorSRGBToLinear(phosphorSampleEncodedNV12(
        lumaTexture,
        chromaTexture,
        fitted.sourceUV,
        uniforms
    )), 1.0);
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
    return float4(phosphorSRGBToLinear(
        phosphorSampleEncodedBGRA(colorTexture, fitted.sourceUV)
    ), 1.0);
}

fragment float4 phosphorDecodeFragmentNV12(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> lumaTexture [[texture(0)]],
    texture2d<float> chromaTexture [[texture(1)]]
) {
    return float4(phosphorSampleEncodedNV12(
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
    return float4(phosphorSampleEncodedBGRA(colorTexture, input.uv), 1.0);
}

// Direct Metal port of afterglow0.slang's default path. Phosphor keeps the
// previous decoded video frame and the feedback texture explicitly because
// AVPlayerItemVideoOutput does not provide RetroArch's OriginalHistory0.
float4 guestAfterglowValue(
    float2 uv,
    constant ShaderUniforms &uniforms,
    texture2d<float> previousSource,
    texture2d<float> feedbackTexture
) {
    if (uniforms.frameData.y < 0.5) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    float2 dx = float2(uniforms.rasterSize.z, 0.0);
    float2 dy = float2(0.0, uniforms.rasterSize.w);
    float3 source0 = previousSource.sample(phosphorLinearSampler, uv).rgb;
    float3 source1 = previousSource.sample(phosphorLinearSampler, uv - dx).rgb;
    float3 source2 = previousSource.sample(phosphorLinearSampler, uv + dx).rgb;
    float3 source3 = previousSource.sample(phosphorLinearSampler, uv - dy).rgb;
    float3 source4 = previousSource.sample(phosphorLinearSampler, uv + dy).rgb;
    float3 spread = (2.5 * source0 + source1 + source2 + source3 + source4) / 6.5;
    float3 accumulated = feedbackTexture.sample(
        phosphorLinearSampler,
        uv
    ).rgb;

    float threshold = 4.0 / 255.0;
    float freshPixel = smoothstep(
        threshold,
        2.0 * threshold,
        phosphorMaximum(source0)
    );
    float3 persisted = max(
        mix(spread, accumulated, 0.49 + float3(0.32)) - 1.25 / 255.0,
        0.0
    );
    float3 result = mix(persisted, spread, freshPixel);
    return float4(result, freshPixel);
}

fragment float4 guestAfterglowFragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> previousSource [[texture(0)]],
    texture2d<float> feedbackTexture [[texture(1)]]
) {
    return guestAfterglowValue(
        input.uv,
        uniforms,
        previousSource,
        feedbackTexture
    );
}

float guestPrepassVignette(
    float2 uv,
    constant ShaderUniforms &uniforms
) {
    float aspect = uniforms.sourceSize.x / max(uniforms.sourceSize.y, 1.0);
    float2 border = float2(1.0, aspect) * 0.125;
    float2 position = abs(2.0 * (clamp(uv, 0.0, 1.0) - 0.5));
    float2 edge = 1.0 - smoothstep(1.0 - border, 1.0, sqrt(position));
    edge = pow(max(edge, 0.0), float2(0.70));
    float shaped = sqrt(edge.x * edge.y);
    return max(mix(1.0, shaped, saturate(uniforms.effect2.y)), 0.0);
}

float4 guestPrepassEncodedValue(
    float2 uv,
    float3 source,
    float4 afterglow,
    constant ShaderUniforms &uniforms
) {
    source = min(source, 1.0);
    float afterglowWeight = 1.0 - afterglow.a;
    float afterglowLength = length(afterglow.rgb);
    float3 persisted = uniforms.guestColor.z
        * afterglowWeight
        * normalize(pow(afterglow.rgb + 0.01, float3(uniforms.guestColor.w)))
        * afterglowLength;

    const float3x3 profileEBU = float3x3(
        float3(0.412391, 0.212639, 0.019331),
        float3(0.357584, 0.715169, 0.119195),
        float3(0.180481, 0.072192, 0.950532)
    );
    const float3x3 toSRGB = float3x3(
        float3(3.240970, -0.969244, 0.055630),
        float3(-1.537383, 1.875968, -0.203977),
        float3(-0.498611, 0.041555, 1.056972)
    );
    constexpr float profileGamma = 2.20;
    float3 color = pow(saturate(source), float3(profileGamma));
    color = toSRGB * (profileEBU * color);
    color = pow(max(saturate(color), 0.0), float3(1.0 / profileGamma));
    color = min(color + persisted, 1.0);

    return float4(color, guestPrepassVignette(uv, uniforms));
}

// Default CP=0 / CS=0 color path from pre-shaders-afterglow.slang. The LUT
// branch is intentionally omitted because Guest's default TNTC value is zero.
fragment float4 guestPrepassFragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> currentSource [[texture(0)]],
    texture2d<float> afterglowTexture [[texture(1)]]
) {
    return guestPrepassEncodedValue(
        input.uv,
        currentSource.sample(phosphorLinearSampler, input.uv).rgb,
        afterglowTexture.sample(phosphorLinearSampler, input.uv),
        uniforms
    );
}

// Phosphor's optimized path folds Guest's following gamma-linearization pass
// into the color prepass. RGB remains mathematically identical to sampling the
// prepass and applying guestLinearizeFragment; alpha keeps the vignette value
// that the final glass pass consumes.
fragment float4 guestPrepassLinearizedFragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> currentSource [[texture(0)]],
    texture2d<float> afterglowTexture [[texture(1)]]
) {
    float4 encoded = guestPrepassEncodedValue(
        input.uv,
        currentSource.sample(phosphorLinearSampler, input.uv).rgb,
        afterglowTexture.sample(phosphorLinearSampler, input.uv),
        uniforms
    );

    return float4(
        pow(max(encoded.rgb, 0.0), float3(uniforms.guestColor.x)),
        encoded.a
    );
}

struct GuestFramePreparationOutput {
    float4 raw [[color(0)]];
    float4 history [[color(1)]];
    float4 prepassLinearized [[color(2)]];
};

GuestFramePreparationOutput guestPrepareFrame(
    float2 uv,
    float3 encodedSource,
    constant ShaderUniforms &uniforms,
    texture2d<float> previousSource,
    texture2d<float> feedbackTexture
) {
    GuestFramePreparationOutput output;
    output.raw = float4(encodedSource, 1.0);
    output.history = guestAfterglowValue(
        uv,
        uniforms,
        previousSource,
        feedbackTexture
    );
    float4 encodedPrepass = guestPrepassEncodedValue(
        uv,
        encodedSource,
        output.history,
        uniforms
    );
    output.prepassLinearized = float4(
        pow(max(encodedPrepass.rgb, 0.0), float3(uniforms.guestColor.x)),
        encodedPrepass.a
    );
    return output;
}

fragment GuestFramePreparationOutput guestPrepareFrameNV12Fragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> lumaTexture [[texture(0)]],
    texture2d<float> chromaTexture [[texture(1)]],
    texture2d<float> previousSource [[texture(2)]],
    texture2d<float> feedbackTexture [[texture(3)]]
) {
    float2 dx = float2(uniforms.sourceSize.z, 0.0);
    float3 center = phosphorSampleEncodedNV12(
        lumaTexture,
        chromaTexture,
        input.uv,
        uniforms
    );
    return guestPrepareFrame(
        input.uv,
        guestAnalogSignal(
            center,
            phosphorSampleEncodedNV12(lumaTexture, chromaTexture, input.uv - dx, uniforms),
            phosphorSampleEncodedNV12(lumaTexture, chromaTexture, input.uv + dx, uniforms),
            phosphorSampleEncodedNV12(lumaTexture, chromaTexture, input.uv - 2.0 * dx, uniforms),
            phosphorSampleEncodedNV12(lumaTexture, chromaTexture, input.uv + 2.0 * dx, uniforms),
            input.uv,
            uniforms
        ),
        uniforms,
        previousSource,
        feedbackTexture
    );
}

fragment GuestFramePreparationOutput guestPrepareFrameBGRAFragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> colorTexture [[texture(0)]],
    texture2d<float> previousSource [[texture(1)]],
    texture2d<float> feedbackTexture [[texture(2)]]
) {
    float2 dx = float2(uniforms.sourceSize.z, 0.0);
    float3 center = phosphorSampleEncodedBGRA(colorTexture, input.uv);
    return guestPrepareFrame(
        input.uv,
        guestAnalogSignal(
            center,
            phosphorSampleEncodedBGRA(colorTexture, input.uv - dx),
            phosphorSampleEncodedBGRA(colorTexture, input.uv + dx),
            phosphorSampleEncodedBGRA(colorTexture, input.uv - 2.0 * dx),
            phosphorSampleEncodedBGRA(colorTexture, input.uv + 2.0 * dx),
            input.uv,
            uniforms
        ),
        uniforms,
        previousSource,
        feedbackTexture
    );
}

// linearize-hd.slang's non-interlaced default path. AVFoundation already
// presents progressive frames, so RetroArch's field-selection branches do not
// apply here.
fragment float4 guestLinearizeFragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> source [[texture(0)]]
) {
    float3 encoded = source.sample(phosphorLinearSampler, input.uv).rgb;
    return float4(
        pow(max(encoded, 0.0), float3(uniforms.guestColor.x)),
        1.0 / uniforms.guestColor.x
    );
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
    float fraction = 0.5 - fract(uniforms.rasterSize.x * input.uv.x);
    float2 center = (
        floor(uniforms.rasterSize.xy * input.uv) + 0.5
    ) * uniforms.rasterSize.zw;
    float2 dx = float2(uniforms.rasterSize.z, 0.0);
    for (int offset = -6; offset <= 6; ++offset) {
        float weight = guestGaussian(float(offset) + fraction, 2.00);
        float3 pixel = guestHighlightEnergy(source.sample(
            phosphorLinearSampler,
            center + float(offset) * dx
        ).rgb);
        color += weight * pixel;
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
    float fraction = 0.5 - fract(uniforms.rasterSize.y * input.uv.y);
    float2 center = float2(
        input.uv.x,
        (floor(uniforms.rasterSize.y * input.uv.y) + 0.5)
            * uniforms.rasterSize.w
    );
    float2 dy = float2(0.0, uniforms.rasterSize.w);
    for (int offset = -6; offset <= 6; ++offset) {
        float weight = guestGaussian(float(offset) + fraction, 2.00);
        color += weight * source.sample(
            phosphorLinearSampler,
            center + float(offset) * dy
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
    float fraction = 0.5 - fract(uniforms.rasterSize.x * input.uv.x);
    float2 center = (
        floor(uniforms.rasterSize.xy * input.uv) + 0.5
    ) * uniforms.rasterSize.zw;
    float2 dx = float2(uniforms.rasterSize.z, 0.0);
    for (int offset = -6; offset <= 6; ++offset) {
        float weight = guestGaussian(float(offset) + fraction, 2.40);
        float sampleOffset = float(offset) * 1.75;
        float3 pixel = guestHighlightEnergy(source.sample(
            phosphorLinearSampler,
            center + sampleOffset * dx
        ).rgb);
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
    float fraction = 0.5 - fract(uniforms.rasterSize.y * input.uv.y);
    float2 center = float2(
        input.uv.x,
        (floor(uniforms.rasterSize.y * input.uv.y) + 0.5)
            * uniforms.rasterSize.w
    );
    float2 dy = float2(0.0, uniforms.rasterSize.w);
    for (int offset = -6; offset <= 6; ++offset) {
        float weight = guestGaussian(float(offset) + fraction, 2.00);
        float sampleOffset = float(offset) * 1.75;
        float4 pixel = source.sample(
            phosphorLinearSampler,
            center + sampleOffset * dy
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
        float3(1.0 + uniforms.guestScan.y),
        float3(1.0),
        normalizedColor
    );
    float exponent = distance * beamWidth;
    return exp2(-shape * exponent * exponent * saturation);
}

float4 guestReconstructBeam(
    FittedGeometry fitted,
    constant ShaderUniforms &uniforms,
    texture2d<float> sharpened
) {
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

    float radialLoad = saturate(dot(
        fitted.tubePosition * fitted.tubePosition,
        float2(0.55, 0.45)
    ));
    float convergence = uniforms.tubeData.y * radialLoad * 1.6;
    float focus = uniforms.tubeData.z * radialLoad * radialLoad;
    float2 convergenceOffset = float2(
        uniforms.rasterSize.z * max(convergence, 0.75 * focus),
        0.0
    );

    float4 firstCenter = sharpened.sample(phosphorLinearSampler, center);
    float4 firstLeft = sharpened.sample(
        phosphorLinearSampler,
        center - convergenceOffset
    );
    float4 firstRight = sharpened.sample(
        phosphorLinearSampler,
        center + convergenceOffset
    );
    float4 firstConverged = mix(
        firstCenter,
        float4(firstLeft.r, firstCenter.g, firstRight.b, firstCenter.a),
        saturate(convergence)
    );
    float4 firstSample = mix(
        firstConverged,
        0.25 * (firstLeft + 2.0 * firstCenter + firstRight),
        focus
    );

    float2 secondCenterUV = center + dy;
    float4 secondCenter = sharpened.sample(phosphorLinearSampler, secondCenterUV);
    float4 secondLeft = sharpened.sample(
        phosphorLinearSampler,
        secondCenterUV - convergenceOffset
    );
    float4 secondRight = sharpened.sample(
        phosphorLinearSampler,
        secondCenterUV + convergenceOffset
    );
    float4 secondConverged = mix(
        secondCenter,
        float4(secondLeft.r, secondCenter.g, secondRight.b, secondCenter.a),
        saturate(convergence)
    );
    float4 secondSample = mix(
        secondConverged,
        0.25 * (secondLeft + 2.0 * secondCenter + secondRight),
        focus
    );
    float scanGamma = uniforms.guestScan.w;
    float gammaInput = uniforms.guestColor.x;
    float3 color1 = pow(
        max(firstSample.rgb, 0.0),
        float3(scanGamma / gammaInput)
    );
    float3 color2 = pow(
        max(secondSample.rgb, 0.0),
        float3(scanGamma / gammaInput)
    );

    if (uniforms.videoData.x > 0.5) {
        int firstLine = int(floor(rasterPosition));
        int activeParity = uniforms.videoData.y > 0.5 ? 1 : 0;
        // The panel displays a time-integrated field exposure, not a camera's
        // instantaneous view between electron-beam sweeps. Retain most of the
        // opposite field's perceived energy while the temporal state still
        // receives the stronger active-field excitation.
        float fieldExposure = mix(
            0.96,
            0.995,
            saturate(uniforms.tubeData.x)
        );
        if ((firstLine & 1) != activeParity) {
            color1 *= fieldExposure;
            firstSample.a *= fieldExposure;
        }
        if (((firstLine + 1) & 1) != activeParity) {
            color2 *= fieldExposure;
            secondSample.a *= fieldExposure;
        }
    }

    float weightCenter1 = guestBeamCenterWeight(fraction);
    float weightCenter2 = guestBeamCenterWeight(1.0 - fraction);
    float3 interpolated = (
        color1 * weightCenter1 + color2 * weightCenter2
    ) / max(weightCenter1 + weightCenter2, 0.00001);

    float3 spikePeak = max(
        (float3(firstSample.a) * weightCenter1
            + float3(secondSample.a) * weightCenter2)
            / max(weightCenter1 + weightCenter2, 0.00001),
        interpolated
    );
    float peak1 = pow(
        phosphorMaximum(mix(spikePeak, float3(firstSample.a), uniforms.guestScan.x)),
        uniforms.guestScan.z
    );
    float peak2 = pow(
        phosphorMaximum(mix(spikePeak, float3(secondSample.a), uniforms.guestScan.x)),
        uniforms.guestScan.z
    );
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
    beam = pow(
        max(beam, 0.0),
        float3(gammaInput / scanGamma)
    );
    float3 smoothImage = pow(
        max(interpolated, 0.0),
        float3(gammaInput / scanGamma)
    );
    float3 color = mix(smoothImage, beam, saturate(uniforms.effect.z));

    // Preserve Guest's peak channel in alpha for brightness-adaptive masks.
    float peak = phosphorMaximum(interpolated);
    return float4(saturate(color), saturate(peak));
}

// Port of crt-guest-advanced-hd-pass2.slang's central beam reconstruction.
// Dark pixels produce narrow beams; bright pixels excite wider beams.
fragment float4 guestHDBeamFragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> sharpened [[texture(0)]],
    texture2d<float> bloomTexture [[texture(1)]],
    texture2d<float> linearized [[texture(2)]]
) {
    FittedGeometry fitted = guestWarp(phosphorAspectFit(input.uv, uniforms), uniforms);
    return guestReconstructBeam(fitted, uniforms, sharpened);
}

float guestRoundedEmitter(
    float2 localCoordinate,
    float2 halfExtent,
    float softness
) {
    float2 distance = abs(localCoordinate - 0.5) - halfExtent;
    float signedDistance = length(max(distance, 0.0))
        + min(max(distance.x, distance.y), 0.0);
    return 1.0 - smoothstep(-softness, softness, signedDistance);
}

float3 guestEmitterColor(float subphosphor) {
    return subphosphor < 0.5
        ? float3(1.0, 0.0, 0.0)
        : (subphosphor < 1.5
            ? float3(0.0, 1.0, 0.0)
            : float3(0.0, 0.0, 1.0));
}

// Aperture grilles are continuous vertical phosphor stripes separated by the
// black grille wires. Bright beam spots grow laterally into the wire region.
float3 guestApertureMask(
    float2 physicalPixel,
    float brightness,
    float control,
    float maskScale
) {
    float scale = max(maskScale, 1.0);
    float2 maskCoordinate = physicalPixel / scale;
    float subphosphor = floor(fmod(maskCoordinate.x, 3.0));
    float3 emitterColor = guestEmitterColor(subphosphor);
    float localX = fract(maskCoordinate.x);
    float halfWidth = mix(0.31, 0.47, saturate(brightness));
    float wireSoftness = 0.16 / scale;
    float stripe = 1.0 - smoothstep(
        halfWidth - wireSoftness,
        halfWidth + wireSoftness,
        abs(localX - 0.5)
    );
    float spill = smoothstep(0.45, 1.0, brightness)
        * (1.0 - stripe)
        * 0.08;
    float3 phosphors = emitterColor * stripe + spill;
    float strength = saturate(control);
    return saturate(mix(float3(1.0), phosphors, strength));
}

// A slot mask is a two-dimensional shadow-mask lattice, not an aperture grille
// with dark horizontal lines. Each triad contains separate rounded R/G/B slots;
// adjacent triads are vertically staggered like brickwork, and a black matrix
// surrounds every individual phosphor deposit in both axes.
float3 guestSlotPhosphorMask(
    float2 physicalPixel,
    float brightness,
    float control,
    float maskScale
) {
    float scale = max(maskScale, 1.0);
    float2 maskCoordinate = physicalPixel / scale;
    float triad = floor(maskCoordinate.x / 3.0);
    float subphosphor = floor(fmod(maskCoordinate.x, 3.0));
    float stagger = fmod(abs(triad), 2.0) * 0.5;
    constexpr float slotPitch = 4.0;
    float2 local = float2(
        fract(maskCoordinate.x),
        fract(maskCoordinate.y / slotPitch + stagger)
    );
    float energy = saturate(brightness);
    float2 halfExtent = float2(
        mix(0.23, 0.38, energy),
        mix(0.34, 0.46, energy)
    );
    float softness = 0.13 / scale;
    float slot = guestRoundedEmitter(local, halfExtent, softness);
    float halo = guestRoundedEmitter(
        local,
        min(halfExtent + float2(0.08, 0.055), float2(0.49)),
        softness * 1.4
    );
    float3 emitterColor = guestEmitterColor(subphosphor);
    float spill = (halo - slot) * energy * 0.11;
    float3 phosphors = emitterColor * slot + spill;
    return saturate(mix(
        float3(1.0),
        phosphors,
        saturate(control)
    ));
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
float4 guestTubeSample(
    FullscreenVertex input,
    constant ShaderUniforms &uniforms,
    texture2d<float> sharpenedTexture,
    texture2d<float> bloomTexture,
    texture2d<float> prepassLinearizedTexture,
    texture2d<float> glowTexture,
    texture2d<float> rawTexture
) {
    FittedGeometry fitted = phosphorAspectFit(input.uv, uniforms);
    FittedGeometry warped = guestWarp(fitted, uniforms);
    if (!warped.visible) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    float4 beamSample = guestReconstructBeam(
        warped,
        uniforms,
        sharpenedTexture
    );
    float3 raw = rawTexture.sample(phosphorLinearSampler, warped.sourceUV).rgb;
    float3 bloom = bloomTexture.sample(phosphorLinearSampler, warped.sourceUV).rgb;
    float3 glow = glowTexture.sample(phosphorLinearSampler, warped.sourceUV).rgb;
    float prepassVignette = prepassLinearizedTexture.sample(
        phosphorLinearSampler,
        clamp(warped.sourceUV, 0.0, 1.0)
    ).a;

    float gammaInput = uniforms.guestColor.x;
    float colorMaximum = phosphorMaximum(beamSample.rgb);
    float brightness = max(beamSample.a, colorMaximum);
    float maskBrightness = pow(saturate(brightness), 1.40 / gammaInput);
    bool usesSlotMask = guestUsesSlotMask;
    float3 mask;
    if (usesSlotMask) {
        mask = guestSlotPhosphorMask(
            input.position.xy,
            maskBrightness,
            uniforms.effect.w,
            uniforms.effect2.z
        );
    } else {
        mask = guestApertureMask(
            input.position.xy,
            maskBrightness,
            uniforms.effect.w,
            uniforms.effect2.z
        );
    }

    float maskGamma = uniforms.guestMask.z;
    float3 color = pow(
        max(beamSample.rgb, 0.0),
        float3(maskGamma / gammaInput)
    );
    color *= mask;
    color = pow(max(min(color, 1.0), 0.0), float3(gammaInput / maskGamma));

    float brightBoost = mix(
        uniforms.guestLight.z,
        uniforms.guestLight.w,
        maskBrightness
    );
    float maskCompensation = 0.40;
    float lowMaskStrength = uniforms.guestMask.y * saturate(uniforms.effect.w);
    float darkCompensation = mix(
        max(
            saturate(mix(lowMaskStrength, uniforms.effect.w, maskBrightness))
                - 1.0
                + maskCompensation,
            0.0
        ) + 1.0,
        1.0,
        maskBrightness
    );
    float slotCompensation = usesSlotMask
        ? mix(1.0, 1.12, saturate(uniforms.effect.w))
        : 1.0;
    color *= brightBoost * darkCompensation * slotCompensation;

    float glowControl = saturate(uniforms.effect2.x);
    float lightResponse = pow(glowControl, 0.65);
    float haloPlacement = mix(
        1.0,
        0.35,
        smoothstep(0.35, 1.0, colorMaximum)
    );

    // Medium-radius phosphor diffusion. Reduce its contribution at the bright
    // core so the same energy reads as a surrounding halo instead of softness.
    glow = mix(glow, 0.25 * color, colorMaximum);
    color += glow * (0.18 * lightResponse * haloPlacement);

    // Wider neutral phosphor bloom and the warmer scatter produced by light
    // travelling through the CRT faceplate. Both remain fully disabled at the
    // zero position of Tube Glow.
    float3 wideLight = bloom * lightResponse * haloPlacement;
    color += wideLight * uniforms.guestLight.x;
    color += wideLight * float3(1.0, 0.32, 0.12) * uniforms.guestLight.y;
    color = guestSoftClip(color);
    color = pow(
        max(color, 0.0),
        float3(1.0 / uniforms.guestColor.y)
    );
    color *= prepassVignette * guestCorner(warped, uniforms);

    float3 treatedEncoded = saturate(color);
    float3 resultEncoded = mix(
        raw,
        treatedEncoded,
        saturate(uniforms.effect.x)
    );
    float3 resultLinear = phosphorSRGBToLinear(saturate(resultEncoded));

    // On an EDR-capable display, spend brightness headroom only on excited
    // phosphors. SDR output remains mathematically identical at headroom 1,
    // while bright beam cores and their optical glow become genuinely
    // luminous instead of merely being painted white.
    float headroom = max(uniforms.frameData.z, 1.0);
    float phosphorExcitation = smoothstep(
        0.72,
        1.0,
        phosphorMaximum(treatedEncoded)
    );
    float edrResponse = mix(0.16, 0.38, lightResponse);
    float edrGain = 1.0
        + (headroom - 1.0)
        * phosphorExcitation
        * edrResponse
        * saturate(uniforms.effect.x);
    return float4(min(resultLinear * edrGain, headroom), 1.0);
}

// Static entry point retained for deterministic shader tests and tooling. The
// app uses the temporal MRT entry point below for live CRT presentation.
fragment float4 guestPhosphorMaskFragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> sharpenedTexture [[texture(0)]],
    texture2d<float> bloomTexture [[texture(1)]],
    texture2d<float> prepassLinearizedTexture [[texture(2)]],
    texture2d<float> glowTexture [[texture(3)]],
    texture2d<float> rawTexture [[texture(4)]]
) {
    return guestTubeSample(
        input,
        uniforms,
        sharpenedTexture,
        bloomTexture,
        prepassLinearizedTexture,
        glowTexture,
        rawTexture
    );
}

struct GuestTemporalOutput {
    float4 excitation [[color(0)]];
    float4 display [[color(1)]];
};

// A CRT is a time-domain device. The beam excites only the region swept since
// the previous display presentation; the native-resolution state texture then
// decays with separate red, green, and blue phosphor time constants.
fragment GuestTemporalOutput guestPhosphorTemporalFragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> sharpenedTexture [[texture(0)]],
    texture2d<float> bloomTexture [[texture(1)]],
    texture2d<float> prepassLinearizedTexture [[texture(2)]],
    texture2d<float> glowTexture [[texture(3)]],
    texture2d<float> rawTexture [[texture(4)]],
    texture2d<float> previousExcitation [[texture(5)]]
) {
    float4 instantaneous = guestTubeSample(
        input,
        uniforms,
        sharpenedTexture,
        bloomTexture,
        prepassLinearizedTexture,
        glowTexture,
        rawTexture
    );

    float persistence = saturate(uniforms.tubeData.x);
    float3 lifetime = mix(
        float3(0.010, 0.014, 0.008),
        float3(0.030, 0.050, 0.022),
        persistence
    );
    float3 decay = exp(-uniforms.temporalData.y / lifetime);
    float3 state = instantaneous.rgb;
    if (uniforms.videoData.w >= 0.5) {
        float3 previous = previousExcitation.sample(
            phosphorLinearSampler,
            input.uv
        ).rgb;
        float3 decayed = previous * decay;
        float distanceBehindBeam = fract(
            uniforms.temporalData.z - input.uv.y + 1.0
        );
        float edgeWidth = max(2.0 * uniforms.drawableSize.w, 0.00001);
        float swept = 1.0 - smoothstep(
            uniforms.temporalData.w - edgeWidth,
            uniforms.temporalData.w + edgeWidth,
            distanceBehindBeam
        );
        float3 excited = max(decayed, instantaneous.rgb);
        state = mix(decayed, excited, swept);
    }

    GuestTemporalOutput output;
    output.excitation = float4(state, 1.0);
    // A Retina panel holds each rendered frame, whereas a CRT emits a brief
    // light pulse that the eye integrates over the raster interval. Present a
    // near-steady exposure floor from the current beam solution while keeping
    // the raw excitation texture free to decay during motion and scene cuts.
    float exposureFloor = mix(0.985, 0.998, persistence);
    float3 integratedPresentation = max(
        state,
        instantaneous.rgb * exposureFloor
    );
    output.display = float4(
        min(integratedPresentation, max(uniforms.frameData.z, 1.0)),
        1.0
    );
    return output;
}

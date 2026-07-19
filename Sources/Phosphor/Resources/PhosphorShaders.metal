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
    float4 temporalResponse;
    float4 tubeData;
    float4 videoData;
    float4 sourceColor;
    float4 scanTiming;
    float4 maskGeometry;
    float4 compositeData;
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
constant ushort guestMaskPattern [[function_constant(0)]];

float3 phosphorSRGBToLinear(float3 color) {
    float3 low = color / 12.92;
    float3 high = pow((color + 0.055) / 1.055, float3(2.4));
    return select(low, high, color > 0.04045);
}

float3 phosphorLinearToSRGB(float3 color) {
    float3 positive = max(color, 0.0);
    float3 low = positive * 12.92;
    float3 high = 1.055 * pow(positive, float3(1.0 / 2.4)) - 0.055;
    return select(low, high, positive > 0.0031308);
}

float3 phosphorPQToLinear(float3 encoded) {
    constexpr float m1 = 2610.0 / 16384.0;
    constexpr float m2 = 2523.0 / 32.0;
    constexpr float c1 = 3424.0 / 4096.0;
    constexpr float c2 = 2413.0 / 128.0;
    constexpr float c3 = 2392.0 / 128.0;
    float3 power = pow(saturate(encoded), float3(1.0 / m2));
    float3 normalizedNits = pow(
        max(power - c1, 0.0) / max(c2 - c3 * power, 0.000001),
        float3(1.0 / m1)
    );
    // PQ is absolute up to 10,000 nits. CRT drive is expressed relative to
    // 203-nit HDR reference white before the tube's own highlight compression.
    return normalizedNits * (10000.0 / 203.0);
}

float3 phosphorHLGToLinear(float3 encoded) {
    constexpr float a = 0.17883277;
    constexpr float b = 0.28466892;
    constexpr float c = 0.55991073;
    float3 low = encoded * encoded / 3.0;
    float3 high = (exp((encoded - c) / a) + b) / 12.0;
    float3 sceneLinear = select(low, high, encoded > 0.5);
    // Apply the nominal BT.2100 display OOTF and normalize diffuse white.
    return pow(max(sceneLinear, 0.0), float3(1.2)) * 3.0;
}

float3 phosphorToSRGBPrimaries(float3 linear, float primaries) {
    if (primaries > 1.5) {
        const float3x3 bt2020ToSRGB = float3x3(
            float3(1.660491, -0.124550, -0.018151),
            float3(-0.587641, 1.132900, -0.100579),
            float3(-0.072850, -0.008349, 1.118730)
        );
        return bt2020ToSRGB * linear;
    }
    if (primaries > 0.5) {
        const float3x3 displayP3ToSRGB = float3x3(
            float3(1.224940, -0.042057, -0.019638),
            float3(-0.224940, 1.042057, -0.078636),
            float3(0.0, 0.0, 1.098274)
        );
        return displayP3ToSRGB * linear;
    }
    return linear;
}

// Converts tagged video into the encoded drive expected by the virtual tube.
// HDR values retain their scene relationships through a soft shoulder instead
// of being clipped by the old 8-bit SDR input path.
float3 phosphorSourceToCRTDrive(
    float3 source,
    constant ShaderUniforms &uniforms
) {
    float transfer = uniforms.sourceColor.x;
    if (transfer < 0.5) {
        return saturate(source);
    }

    float3 linear;
    if (transfer < 1.5) {
        linear = max(source, 0.0);
    } else if (transfer < 2.5) {
        linear = phosphorPQToLinear(source);
    } else {
        linear = phosphorHLGToLinear(source);
    }
    linear = max(
        phosphorToSRGBPrimaries(linear, uniforms.sourceColor.y),
        0.0
    );

    float luminance = dot(linear, float3(0.2126, 0.7152, 0.0722));
    float mappedLuminance = luminance;
    if (luminance > 0.72) {
        mappedLuminance = 0.72
            + 0.28 * (1.0 - exp(-(luminance - 0.72) * 0.72));
    }
    float3 mapped = linear * (mappedLuminance / max(luminance, 0.00001));
    return saturate(phosphorLinearToSRGB(mapped));
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
    return phosphorSourceToCRTDrive(encodedRGB, uniforms);
}

float3 phosphorSampleEncodedBGRA(
    texture2d<float> colorTexture,
    float2 uv,
    constant ShaderUniforms &uniforms
) {
    return phosphorSourceToCRTDrive(
        colorTexture.sample(phosphorLinearSampler, uv).rgb,
        uniforms
    );
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
        phosphorSampleEncodedBGRA(colorTexture, fitted.sourceUV, uniforms)
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
    return float4(
        phosphorSampleEncodedBGRA(colorTexture, input.uv, uniforms),
        1.0
    );
}

// Direct Metal port of afterglow0.slang's default path, retained for reference
// tests and shader tooling. Live playback uses the post-mask temporal model so
// persistence is applied once at the physical phosphor stage.
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
    texture2d<float> currentSource [[texture(0)]]
) {
    float4 encoded = guestPrepassEncodedValue(
        input.uv,
        currentSource.sample(phosphorLinearSampler, input.uv).rgb,
        float4(0.0, 0.0, 0.0, 1.0),
        uniforms
    );

    return float4(
        pow(max(encoded.rgb, 0.0), float3(uniforms.guestColor.x)),
        encoded.a
    );
}

struct GuestFramePreparationOutput {
    float4 raw [[color(0)]];
    float4 prepassLinearized [[color(1)]];
};

GuestFramePreparationOutput guestPrepareFrame(
    float2 uv,
    float3 encodedSource,
    constant ShaderUniforms &uniforms
) {
    GuestFramePreparationOutput output;
    output.raw = float4(encodedSource, 1.0);
    // Persistence now occurs once, after the beam excites the physical mask.
    // Eliminating Guest's older source-frame feedback avoids colored motion
    // ghosts and removes one render target write from every decoded frame.
    float4 encodedPrepass = guestPrepassEncodedValue(
        uv,
        encodedSource,
        float4(0.0, 0.0, 0.0, 1.0),
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
    texture2d<float> chromaTexture [[texture(1)]]
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
        uniforms
    );
}

fragment GuestFramePreparationOutput guestPrepareFrameBGRAFragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> colorTexture [[texture(0)]]
) {
    float2 dx = float2(uniforms.sourceSize.z, 0.0);
    float3 center = phosphorSampleEncodedBGRA(colorTexture, input.uv, uniforms);
    return guestPrepareFrame(
        input.uv,
        guestAnalogSignal(
            center,
            phosphorSampleEncodedBGRA(colorTexture, input.uv - dx, uniforms),
            phosphorSampleEncodedBGRA(colorTexture, input.uv + dx, uniforms),
            phosphorSampleEncodedBGRA(colorTexture, input.uv - 2.0 * dx, uniforms),
            phosphorSampleEncodedBGRA(colorTexture, input.uv + 2.0 * dx, uniforms),
            input.uv,
            uniforms
        ),
        uniforms
    );
}

float guestCompositeCarrierPhase(
    float sampleIndex,
    float sourceLine,
    constant ShaderUniforms &uniforms
) {
    float sampleFraction = (sampleIndex + 0.5) / uniforms.compositeData.x;
    return 6.28318530718
        * (sourceLine + sampleFraction)
        * uniforms.compositeData.y
        + uniforms.frameData.x * 1.57079632679;
}

float guestCompositeWaveform(
    float3 center,
    float3 left,
    float3 right,
    float3 farLeft,
    float3 farRight,
    float sampleIndex,
    float sourceLine,
    constant ShaderUniforms &uniforms
) {
    constexpr float3 lumaWeights = float3(0.299, 0.587, 0.114);
    float3 lumaSamples = float3(
        dot(left, lumaWeights),
        dot(center, lumaWeights),
        dot(right, lumaWeights)
    );
    float luma = dot(lumaSamples, float3(0.18, 0.64, 0.18));
    // The asymmetric five-sample chroma filter both limits color bandwidth and
    // leaves the small group delay found in an analog decoder's chroma path.
    float3 chromaRGB = (
        2.0 * farLeft + 3.0 * left + 3.0 * center + right
    ) / 9.0;
    float phase = guestCompositeCarrierPhase(
        sampleIndex,
        sourceLine,
        uniforms
    );

    if (uniforms.compositeData.w > 0.5) {
        float u = dot(chromaRGB, float3(-0.14713, -0.28886, 0.43600));
        float v = dot(chromaRGB, float3(0.61500, -0.51499, -0.10001));
        float palSwitch = fmod(sourceLine, 2.0) >= 1.0 ? -1.0 : 1.0;
        return luma + 0.493 * u * sin(phase)
            + 0.877 * v * palSwitch * cos(phase);
    }

    float i = dot(chromaRGB, float3(0.595716, -0.274453, -0.321263));
    float q = dot(chromaRGB, float3(0.211456, -0.522591, 0.311135));
    return luma + 0.5957 * i * cos(phase) + 0.5226 * q * sin(phase);
}

fragment float4 guestCompositeEncodeNV12Fragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> lumaTexture [[texture(0)]],
    texture2d<float> chromaTexture [[texture(1)]]
) {
    float sampleIndex = floor(input.uv.x * uniforms.compositeData.x);
    float sourceLine = floor(input.uv.y * uniforms.rasterSize.y);
    float2 dx = float2(1.0 / uniforms.compositeData.x, 0.0);
    float3 center = phosphorSampleEncodedNV12(
        lumaTexture, chromaTexture, input.uv, uniforms
    );
    float signal = guestCompositeWaveform(
        center,
        phosphorSampleEncodedNV12(lumaTexture, chromaTexture, input.uv - dx, uniforms),
        phosphorSampleEncodedNV12(lumaTexture, chromaTexture, input.uv + dx, uniforms),
        phosphorSampleEncodedNV12(lumaTexture, chromaTexture, input.uv - 2.0 * dx, uniforms),
        phosphorSampleEncodedNV12(lumaTexture, chromaTexture, input.uv + 2.0 * dx, uniforms),
        sampleIndex,
        sourceLine,
        uniforms
    );
    return float4(signal, 0.0, 0.0, 1.0);
}

fragment float4 guestCompositeEncodeBGRAFragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> colorTexture [[texture(0)]]
) {
    float sampleIndex = floor(input.uv.x * uniforms.compositeData.x);
    float sourceLine = floor(input.uv.y * uniforms.rasterSize.y);
    float2 dx = float2(1.0 / uniforms.compositeData.x, 0.0);
    float3 center = phosphorSampleEncodedBGRA(
        colorTexture, input.uv, uniforms
    );
    float signal = guestCompositeWaveform(
        center,
        phosphorSampleEncodedBGRA(colorTexture, input.uv - dx, uniforms),
        phosphorSampleEncodedBGRA(colorTexture, input.uv + dx, uniforms),
        phosphorSampleEncodedBGRA(colorTexture, input.uv - 2.0 * dx, uniforms),
        phosphorSampleEncodedBGRA(colorTexture, input.uv + 2.0 * dx, uniforms),
        sampleIndex,
        sourceLine,
        uniforms
    );
    return float4(signal, 0.0, 0.0, 1.0);
}

float guestCompositeSample(
    texture2d<float> waveform,
    float2 uv,
    float sampleOffset,
    float lineOffset,
    constant ShaderUniforms &uniforms
) {
    float2 offset = float2(
        sampleOffset / uniforms.compositeData.x,
        lineOffset * uniforms.rasterSize.w
    );
    return waveform.sample(phosphorLinearSampler, uv + offset).r;
}

float guestCompositeLuma(
    texture2d<float> waveform,
    float2 uv,
    constant ShaderUniforms &uniforms
) {
    float center = guestCompositeSample(waveform, uv, 0.0, 0.0, uniforms);
    if (uniforms.compositeData.z > 0.5) {
        // NTSC's carrier reverses on the adjacent line. PAL needs a two-line
        // delay: after two 283.75-cycle lines the carrier is reversed while
        // the alternating V-axis switch has returned to its original sign.
        float lineSeparation = uniforms.compositeData.w > 0.5 ? 2.0 : 1.0;
        float adjacent = 0.5 * (
            guestCompositeSample(
                waveform, uv, 0.0, -lineSeparation, uniforms
            )
            + guestCompositeSample(
                waveform, uv, 0.0, lineSeparation, uniforms
            )
        );
        return 0.5 * (center + adjacent);
    }

    // Symmetric 4fsc notch: the color carrier integrates to zero while the
    // lower-frequency luminance waveform retains its edge energy.
    return (
        guestCompositeSample(waveform, uv, -2.0, 0.0, uniforms)
        + 2.0 * guestCompositeSample(waveform, uv, -1.0, 0.0, uniforms)
        + 2.0 * center
        + 2.0 * guestCompositeSample(waveform, uv, 1.0, 0.0, uniforms)
        + guestCompositeSample(waveform, uv, 2.0, 0.0, uniforms)
    ) / 8.0;
}

struct GuestCompositeDecodeOutput {
    float4 raw [[color(0)]];
    float4 prepassLinearized [[color(1)]];
};

fragment GuestCompositeDecodeOutput guestCompositeDecodeFragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> waveform [[texture(0)]]
) {
    float sampleIndex = floor(input.uv.x * uniforms.compositeData.x);
    float sourceLine = floor(input.uv.y * uniforms.rasterSize.y);
    float luma = guestCompositeLuma(waveform, input.uv, uniforms);
    float componentA = 0.0;
    float componentB = 0.0;
    float weightSum = 0.0;
    for (int offset = -6; offset <= 6; ++offset) {
        float weight = exp2(-0.16 * float(offset * offset));
        float2 sampleUV = input.uv + float2(
            float(offset) / uniforms.compositeData.x,
            0.0
        );
        float chroma = guestCompositeSample(
            waveform, input.uv, float(offset), 0.0, uniforms
        ) - guestCompositeLuma(waveform, sampleUV, uniforms);
        float phase = guestCompositeCarrierPhase(
            sampleIndex + float(offset),
            sourceLine,
            uniforms
        );
        componentA += chroma * cos(phase) * weight * 2.0;
        componentB += chroma * sin(phase) * weight * 2.0;
        weightSum += weight;
    }
    componentA /= max(weightSum, 0.00001);
    componentB /= max(weightSum, 0.00001);

    float3 decoded;
    if (uniforms.compositeData.w > 0.5) {
        float palSwitch = fmod(sourceLine, 2.0) >= 1.0 ? -1.0 : 1.0;
        float u = componentB / 0.493;
        float v = componentA * palSwitch / 0.877;
        decoded = float3(
            luma + 1.13983 * v,
            luma - 0.39465 * u - 0.58060 * v,
            luma + 2.03211 * u
        );
    } else {
        float i = componentA / 0.5957;
        float q = componentB / 0.5226;
        decoded = float3(
            luma + 0.9563 * i + 0.6210 * q,
            luma - 0.2721 * i - 0.6474 * q,
            luma - 1.1070 * i + 1.7046 * q
        );
    }
    decoded = saturate(decoded);
    float4 encodedPrepass = guestPrepassEncodedValue(
        input.uv,
        decoded,
        float4(0.0, 0.0, 0.0, 1.0),
        uniforms
    );

    GuestCompositeDecodeOutput output;
    output.raw = float4(decoded, 1.0);
    output.prepassLinearized = float4(
        pow(max(encodedPrepass.rgb, 0.0), float3(uniforms.guestColor.x)),
        encodedPrepass.a
    );
    return output;
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
    // Pair adjacent Gaussian taps and let the texture unit perform their
    // weighted interpolation. This preserves the 13-tap footprint with seven
    // samples, which is considerably friendlier to Apple GPU texture pipes.
    for (int firstOffset = -6; firstOffset <= 4; firstOffset += 2) {
        float firstWeight = guestGaussian(float(firstOffset) + fraction, 2.00);
        float secondWeight = guestGaussian(float(firstOffset + 1) + fraction, 2.00);
        float pairWeight = firstWeight + secondWeight;
        float pairOffset = float(firstOffset) + secondWeight / pairWeight;
        float3 pixel = guestHighlightEnergy(source.sample(
            phosphorLinearSampler,
            center + pairOffset * dx
        ).rgb);
        color += pairWeight * pixel;
        weightSum += pairWeight;
    }
    float finalWeight = guestGaussian(6.0 + fraction, 2.00);
    color += finalWeight * guestHighlightEnergy(source.sample(
        phosphorLinearSampler,
        center + 6.0 * dx
    ).rgb);
    weightSum += finalWeight;
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
    for (int firstOffset = -6; firstOffset <= 4; firstOffset += 2) {
        float firstWeight = guestGaussian(float(firstOffset) + fraction, 2.00);
        float secondWeight = guestGaussian(float(firstOffset + 1) + fraction, 2.00);
        float pairWeight = firstWeight + secondWeight;
        float pairOffset = float(firstOffset) + secondWeight / pairWeight;
        color += pairWeight * source.sample(
            phosphorLinearSampler,
            center + pairOffset * dy
        ).rgb;
        weightSum += pairWeight;
    }
    float finalWeight = guestGaussian(6.0 + fraction, 2.00);
    color += finalWeight * source.sample(
        phosphorLinearSampler,
        center + 6.0 * dy
    ).rgb;
    weightSum += finalWeight;
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
    float maskScale,
    float4 geometry
) {
    float scale = max(maskScale, 1.0);
    float2 maskCoordinate = physicalPixel / scale;
    float subphosphor = floor(fmod(maskCoordinate.x, 3.0));
    float3 emitterColor = guestEmitterColor(subphosphor);
    float localX = fract(maskCoordinate.x);
    float halfWidth = mix(
        geometry.x * 0.82,
        min(geometry.x + 0.08, 0.49),
        saturate(brightness)
    );
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
    float maskScale,
    float4 geometry
) {
    float scale = max(maskScale, 1.0);
    float2 maskCoordinate = physicalPixel / scale;
    float triad = floor(maskCoordinate.x / 3.0);
    float subphosphor = floor(fmod(maskCoordinate.x, 3.0));
    float stagger = fmod(abs(triad), 2.0) * 0.5;
    float slotPitch = max(geometry.z, 2.0);
    float2 local = float2(
        fract(maskCoordinate.x),
        fract(maskCoordinate.y / slotPitch + stagger)
    );
    float energy = saturate(brightness);
    float2 halfExtent = float2(
        mix(geometry.x * 0.76, min(geometry.x + 0.08, 0.47), energy),
        mix(geometry.y * 0.88, min(geometry.y + 0.08, 0.48), energy)
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

// Delta-gun shadow masks use discrete phosphor dots in offset RGB triads. The
// circular deposits and surrounding black matrix are resolved in native panel
// pixels so the pattern remains a physical lattice rather than a screen-space
// color overlay.
float3 guestShadowDotMask(
    float2 physicalPixel,
    float brightness,
    float control,
    float maskScale,
    float4 geometry
) {
    float scale = max(maskScale, 1.0);
    float2 coordinate = physicalPixel / scale;
    float row = floor(coordinate.y / 2.0);
    float stagger = fmod(abs(row), 2.0) * 1.5;
    float shiftedX = coordinate.x + stagger;
    float subphosphor = floor(fmod(shiftedX, 3.0));
    float2 local = float2(
        fract(shiftedX),
        fract(coordinate.y / 2.0)
    ) - 0.5;
    float energy = saturate(brightness);
    float2 radius = float2(
        mix(geometry.w * 0.78, min(geometry.w + 0.07, 0.48), energy),
        mix(geometry.w * 0.68, min(geometry.w + 0.04, 0.46), energy)
    );
    float normalizedDistance = length(local / max(radius, 0.01));
    float dot = 1.0 - smoothstep(0.82, 1.08, normalizedDistance);
    float halo = 1.0 - smoothstep(0.94, 1.28, normalizedDistance);
    float3 emitterColor = guestEmitterColor(subphosphor);
    float spill = max(halo - dot, 0.0) * energy * 0.09;
    return saturate(mix(
        float3(1.0),
        emitterColor * dot + spill,
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
    bool usesSlotMask = guestMaskPattern == 1;
    bool usesShadowMask = guestMaskPattern == 2;
    float3 mask;
    if (usesSlotMask) {
        mask = guestSlotPhosphorMask(
            input.position.xy,
            maskBrightness,
            uniforms.effect.w,
            uniforms.effect2.z,
            uniforms.maskGeometry
        );
    } else if (usesShadowMask) {
        mask = guestShadowDotMask(
            input.position.xy,
            maskBrightness,
            uniforms.effect.w,
            uniforms.effect2.z,
            uniforms.maskGeometry
        );
    } else {
        mask = guestApertureMask(
            input.position.xy,
            maskBrightness,
            uniforms.effect.w,
            uniforms.effect2.z,
            uniforms.maskGeometry
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
        : (usesShadowMask
            ? mix(1.0, 1.16, saturate(uniforms.effect.w))
            : 1.0);
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

struct GuestTemporalSolution {
    float3 state;
    float3 integrated;
};

float guestPixelBeamPhase(
    float2 uv,
    constant ShaderUniforms &uniforms
) {
    float totalLines = max(uniforms.scanTiming.z, 1.0);
    float activeLines = min(max(uniforms.scanTiming.w, 1.0), totalLines);
    float verticalBlankLead = 0.5 * (totalLines - activeLines);
    float rasterLine = floor(saturate(uv.y) * max(activeLines - 1.0, 1.0));
    float activeLineFraction = saturate(uniforms.scanTiming.y);
    float horizontalBlankLead = 0.56 * (1.0 - activeLineFraction);
    float linePhase = horizontalBlankLead + saturate(uv.x) * activeLineFraction;
    return fract((verticalBlankLead + rasterLine + linePhase) / totalLines);
}

// Analytically integrates a train of electron-beam impulses over the panel's
// presentation interval. This models horizontal scan timing and flyback without
// sub-stepping the 15-kHz line clock, and it replaces the old constant exposure
// floor with the emitted phosphor energy actually accumulated during the frame.
GuestTemporalSolution guestIntegratePhosphor(
    float2 uv,
    float3 instantaneous,
    float3 previous,
    float discontinuity,
    bool hasHistory,
    constant ShaderUniforms &uniforms
) {
    GuestTemporalSolution result;
    float dt = max(uniforms.temporalData.y, 1.0 / 1000.0);
    float refresh = max(uniforms.scanTiming.x, 24.0);
    float scanPeriod = 1.0 / refresh;
    float3 lifetime = max(uniforms.temporalResponse.xyz, float3(0.0005));
    float pixelPhase = guestPixelBeamPhase(uv, uniforms);
    float distanceBehindBeam = fract(
        uniforms.temporalData.z - pixelPhase + 1.0
    );
    float beamAge = distanceBehindBeam * scanPeriod;
    float3 impulse = instantaneous * (scanPeriod / lifetime);
    float3 periodDecay = exp(-scanPeriod / lifetime);

    // Seed the physical state at its steady-state beam phase. Starting with the
    // instantaneous color would take several presentations to converge and can
    // flash once when playback begins or temporal history is rebuilt.
    if (!hasHistory) {
        result.state = impulse
            * exp(-beamAge / lifetime)
            / max(1.0 - periodDecay, float3(0.0001));
        result.integrated = instantaneous;
        return result;
    }

    float3 retainedPrevious = previous * (1.0 - discontinuity);
    float3 decay = exp(-dt / lifetime);
    float3 state = retainedPrevious * decay;
    float3 integrated = retainedPrevious
        * lifetime
        * (1.0 - decay)
        / dt;

    float scanSpan = saturate(uniforms.temporalData.w);
    float phaseSoftness = max(
        1.0 / (uniforms.scanTiming.z * 128.0),
        0.000002
    );
    float swept = 1.0 - smoothstep(
        scanSpan - phaseSoftness,
        scanSpan + phaseSoftness,
        distanceBehindBeam
    );
    float age = min(beamAge, dt);

    // One beam visit deposits an impulse whose energy integrates to the desired
    // steady luminance over a complete raster period.
    float3 ageDecay = exp(-age / lifetime);
    state += impulse * ageDecay * swept;
    integrated += impulse
        * lifetime
        * (1.0 - ageDecay)
        * swept
        / dt;

    // A sample-and-hold panel must not directly display the small fraction of a
    // raster swept during one display refresh: doing so turns the CRT's brief
    // light pulse into a conspicuous rolling flicker. Stable mode analytically
    // integrates the current state and the next beam impulse across one complete
    // raster period. For a steady pixel this is phase-invariant, while real
    // phosphor history can still contribute a restrained, neutral presentation.
    // Low Persistence deliberately retains the physical partial-frame exposure
    // and is enabled only on 100-Hz-or-faster screens.
    if (uniforms.temporalResponse.w < 0.5) {
        float3 stateEnergy = state
            * lifetime
            * (1.0 - periodDecay);
        float3 nextImpulseEnergy = impulse
            * lifetime
            * (1.0 - exp(-beamAge / lifetime));
        float3 fullRasterAverage = (
            stateEnergy + nextImpulseEnergy
        ) / scanPeriod;
        float stableHistoryWeight = 0.05
            + 0.07 * saturate(uniforms.tubeData.x);
        integrated = mix(
            instantaneous,
            fullRasterAverage,
            stableHistoryWeight
        );
    }

    // Large local changes are source discontinuities, not phosphor energy. The
    // current beam solution replaces the stale state immediately so fast motion
    // and hard cuts never leave a colored double image.
    integrated = mix(integrated, instantaneous, discontinuity * 0.94);

    result.state = max(state, 0.0);
    result.integrated = max(integrated, 0.0);
    return result;
}

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

    float3 previous = previousExcitation.sample(
        phosphorLinearSampler,
        input.uv
    ).rgb;
    GuestTemporalSolution solution = guestIntegratePhosphor(
        input.uv,
        instantaneous.rgb,
        previous,
        0.0,
        uniforms.videoData.w >= 0.5,
        uniforms
    );

    GuestTemporalOutput output;
    output.excitation = float4(solution.state, 1.0);
    output.display = float4(
        min(solution.integrated, max(uniforms.frameData.z, 1.0)),
        1.0
    );
    return output;
}

// Live presentation entry point. The expensive tube/beam/optical solution is
// cached only when the decoded source changes. This native-refresh pass keeps
// the time-domain CRT behavior while reducing the per-pixel work to one cached
// emission sample, one state sample, and two low-resolution source samples.
fragment GuestTemporalOutput guestPhosphorCachedTemporalFragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<half> cachedEmission [[texture(0)]],
    texture2d<half> previousExcitation [[texture(1)]],
    texture2d<half> currentSource [[texture(2)]],
    texture2d<half> previousSource [[texture(3)]]
) {
    float3 instantaneous = float3(cachedEmission.sample(
        phosphorLinearSampler,
        input.uv
    ).rgb);
    float3 previous = float3(previousExcitation.sample(
        phosphorLinearSampler,
        input.uv
    ).rgb);
    float discontinuity = 0.0;
    if (uniforms.frameData.w > 0.5 && uniforms.frameData.y > 0.5) {
        float3 currentPixel = float3(currentSource.sample(
            phosphorLinearSampler,
            input.uv
        ).rgb);
        float3 previousPixel = float3(previousSource.sample(
            phosphorLinearSampler,
            input.uv
        ).rgb);
        float sourceDelta = length(currentPixel - previousPixel);
        discontinuity = smoothstep(0.16, 0.58, sourceDelta);
    }
    GuestTemporalSolution solution = guestIntegratePhosphor(
        input.uv,
        instantaneous,
        previous,
        discontinuity,
        uniforms.videoData.w >= 0.5,
        uniforms
    );

    GuestTemporalOutput output;
    output.excitation = float4(solution.state, 1.0);
    output.display = float4(
        min(solution.integrated, max(uniforms.frameData.z, 1.0)),
        1.0
    );
    return output;
}

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
fragment float4 guestAfterglowFragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> previousSource [[texture(0)]],
    texture2d<float> feedbackTexture [[texture(1)]]
) {
    if (uniforms.frameData.y < 0.5) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    float2 dx = float2(uniforms.rasterSize.z, 0.0);
    float2 dy = float2(0.0, uniforms.rasterSize.w);
    float3 source0 = previousSource.sample(phosphorLinearSampler, input.uv).rgb;
    float3 source1 = previousSource.sample(phosphorLinearSampler, input.uv - dx).rgb;
    float3 source2 = previousSource.sample(phosphorLinearSampler, input.uv + dx).rgb;
    float3 source3 = previousSource.sample(phosphorLinearSampler, input.uv - dy).rgb;
    float3 source4 = previousSource.sample(phosphorLinearSampler, input.uv + dy).rgb;
    float3 spread = (2.5 * source0 + source1 + source2 + source3 + source4) / 6.5;
    float3 accumulated = feedbackTexture.sample(
        phosphorLinearSampler,
        input.uv
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

// Default CP=0 / CS=0 color path from pre-shaders-afterglow.slang. The LUT
// branch is intentionally omitted because Guest's default TNTC value is zero.
fragment float4 guestPrepassFragment(
    FullscreenVertex input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(0)]],
    texture2d<float> currentSource [[texture(0)]],
    texture2d<float> afterglowTexture [[texture(1)]]
) {
    float3 source = min(
        currentSource.sample(phosphorLinearSampler, input.uv).rgb,
        1.0
    );
    float4 afterglow = afterglowTexture.sample(
        phosphorLinearSampler,
        input.uv
    );
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

    return float4(color, guestPrepassVignette(input.uv, uniforms));
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

    float strength = saturate(control);
    float3 darkMask = saturate(mix(
        float3(1.0),
        emitter,
        1.10 * strength
    ));
    float3 brightMask = saturate(mix(
        float3(1.0),
        emitter,
        strength
    ));
    return mix(darkMask, brightMask, saturate(brightness));
}

// CRT-Guest-Advanced's slot-mask geometry overlays staggered horizontal
// separators on the RGB phosphor columns. One triad is three mask cells wide;
// alternating triads receive separators two rows apart in a four-row period.
float guestSlotMask(
    float2 physicalPixel,
    float brightness,
    float control,
    float maskScale
) {
    float2 maskCoordinate = floor(physicalPixel / max(maskScale, 1.0));
    constexpr float slotWidth = 3.0;
    constexpr float slotHeight = 2.0;
    float horizontal = floor(fmod(maskCoordinate.x, 2.0 * slotWidth));
    float vertical = floor(fmod(maskCoordinate.y, 2.0 * slotHeight));
    bool separator = (vertical == 0.0 && horizontal < slotWidth)
        || (vertical == slotHeight && horizontal >= slotWidth);

    float depth = saturate(
        saturate(control) * mix(1.10, 0.72, saturate(brightness))
    );
    return separator ? 1.0 - depth : 1.0;
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
    texture2d<float> linearizedTexture [[texture(1)]],
    texture2d<float> bloomTexture [[texture(2)]],
    texture2d<float> prepassTexture [[texture(3)]],
    texture2d<float> glowTexture [[texture(4)]],
    texture2d<float> rawTexture [[texture(5)]]
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
    float prepassVignette = prepassTexture.sample(
        phosphorLinearSampler,
        clamp(warped.sourceUV, 0.0, 1.0)
    ).a;

    float gammaInput = uniforms.guestColor.x;
    float colorMaximum = phosphorMaximum(beamSample.rgb);
    float brightness = max(beamSample.a, colorMaximum);
    float maskBrightness = pow(saturate(brightness), 1.40 / gammaInput);
    float3 mask = guestApertureMask(
        input.position.xy,
        maskBrightness,
        uniforms.effect.w,
        uniforms.effect2.z
    );
    bool usesSlotMask = uniforms.effect2.w > 0.5;
    if (usesSlotMask) {
        mask *= guestSlotMask(
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
    return float4(phosphorSRGBToLinear(saturate(resultEncoded)), 1.0);
}

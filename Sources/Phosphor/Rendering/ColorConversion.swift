import CoreVideo

enum YUVMatrixKind: Sendable {
    case bt601
    case bt709
    case bt2020
}

enum YUVRange: Sendable {
    case video
    case video10
    case full
}

enum VideoTransferFunction: Float, Sendable, Equatable {
    case sRGB = 0
    case linear = 1
    case pq = 2
    case hlg = 3
}

enum VideoColorPrimaries: Float, Sendable, Equatable {
    case bt709 = 0
    case displayP3 = 1
    case bt2020 = 2
}

struct VideoColorConversion: Sendable, Equatable {
    let transferFunction: VideoTransferFunction
    let primaries: VideoColorPrimaries

    static let sRGB = VideoColorConversion(
        transferFunction: .sRGB,
        primaries: .bt709
    )

    static func make(for pixelBuffer: CVPixelBuffer) -> VideoColorConversion {
        VideoColorConversion(
            transferFunction: transferFunction(for: pixelBuffer),
            primaries: colorPrimaries(for: pixelBuffer)
        )
    }

    private static func transferFunction(
        for pixelBuffer: CVPixelBuffer
    ) -> VideoTransferFunction {
        guard let attachment = CVBufferCopyAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            nil
        ) else {
            return .sRGB
        }
        if CFEqual(attachment, kCVImageBufferTransferFunction_Linear) {
            return .linear
        }
        if CFEqual(attachment, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) {
            return .pq
        }
        if CFEqual(attachment, kCVImageBufferTransferFunction_ITU_R_2100_HLG) {
            return .hlg
        }
        return .sRGB
    }

    private static func colorPrimaries(
        for pixelBuffer: CVPixelBuffer
    ) -> VideoColorPrimaries {
        guard let attachment = CVBufferCopyAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            nil
        ) else {
            return .bt709
        }
        if CFEqual(attachment, kCVImageBufferColorPrimaries_P3_D65) {
            return .displayP3
        }
        if CFEqual(attachment, kCVImageBufferColorPrimaries_ITU_R_2020) {
            return .bt2020
        }
        return .bt709
    }
}

struct YUVConversion: Sendable {
    let red: SIMD4<Float>
    let green: SIMD4<Float>
    let blue: SIMD4<Float>

    static func make(matrix: YUVMatrixKind, range: YUVRange) -> YUVConversion {
        let coefficients: (redV: Float, greenU: Float, greenV: Float, blueU: Float)
        switch matrix {
        case .bt601:
            coefficients = (1.402, -0.344_136, -0.714_136, 1.772)
        case .bt709:
            coefficients = (1.574_8, -0.187_324, -0.468_124, 1.855_6)
        case .bt2020:
            coefficients = (1.474_6, -0.164_553, -0.571_353, 1.881_4)
        }

        switch range {
        case .full:
            return makeRows(
                yScale: 1,
                yOffset: 0,
                chromaScale: 1,
                coefficients: coefficients
            )
        case .video:
            return makeRows(
                yScale: 255 / 219,
                yOffset: -16 / 219,
                chromaScale: 255 / 224,
                coefficients: coefficients
            )
        case .video10:
            return makeRows(
                yScale: 1_023 / 876,
                yOffset: -64 / 876,
                chromaScale: 1_023 / 896,
                coefficients: coefficients
            )
        }
    }

    func convert(y: Float, u: Float, v: Float) -> SIMD3<Float> {
        let sample = SIMD4<Float>(y, u, v, 1)
        return SIMD3(
            red.x * sample.x + red.y * sample.y + red.z * sample.z + red.w,
            green.x * sample.x + green.y * sample.y + green.z * sample.z + green.w,
            blue.x * sample.x + blue.y * sample.y + blue.z * sample.z + blue.w
        )
    }

    private static func makeRows(
        yScale: Float,
        yOffset: Float,
        chromaScale: Float,
        coefficients: (redV: Float, greenU: Float, greenV: Float, blueU: Float)
    ) -> YUVConversion {
        YUVConversion(
            red: SIMD4(
                yScale,
                0,
                coefficients.redV * chromaScale,
                yOffset - coefficients.redV * chromaScale * 0.5
            ),
            green: SIMD4(
                yScale,
                coefficients.greenU * chromaScale,
                coefficients.greenV * chromaScale,
                yOffset - (coefficients.greenU + coefficients.greenV) * chromaScale * 0.5
            ),
            blue: SIMD4(
                yScale,
                coefficients.blueU * chromaScale,
                0,
                yOffset - coefficients.blueU * chromaScale * 0.5
            )
        )
    }
}

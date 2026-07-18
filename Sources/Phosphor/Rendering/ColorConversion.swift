enum YUVMatrixKind: Sendable {
    case bt601
    case bt709
}

enum YUVRange: Sendable {
    case video
    case full
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
        }

        switch range {
        case .full:
            return makeRows(
                yScale: 1,
                yOffset: 0,
                coefficients: coefficients
            )
        case .video:
            return makeRows(
                yScale: 255 / 219,
                yOffset: -16 / 219,
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
        coefficients: (redV: Float, greenU: Float, greenV: Float, blueU: Float)
    ) -> YUVConversion {
        YUVConversion(
            red: SIMD4(yScale, 0, coefficients.redV, yOffset - coefficients.redV * 0.5),
            green: SIMD4(
                yScale,
                coefficients.greenU,
                coefficients.greenV,
                yOffset - (coefficients.greenU + coefficients.greenV) * 0.5
            ),
            blue: SIMD4(yScale, coefficients.blueU, 0, yOffset - coefficients.blueU * 0.5)
        )
    }
}

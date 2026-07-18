import CoreGraphics

enum AspectFit {
    static func normalizedRect(source: CGSize, destination: CGSize) -> CGRect {
        guard source.width.isFinite,
              source.height.isFinite,
              destination.width.isFinite,
              destination.height.isFinite,
              source.width > 0,
              source.height > 0,
              destination.width > 0,
              destination.height > 0 else {
            return .zero
        }

        let sourceAspect = source.width / source.height
        let destinationAspect = destination.width / destination.height

        if sourceAspect > destinationAspect {
            let height = destinationAspect / sourceAspect
            return CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
        }

        let width = sourceAspect / destinationAspect
        return CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
    }
}

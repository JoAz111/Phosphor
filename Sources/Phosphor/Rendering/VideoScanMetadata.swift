import CoreMedia

/// Identifies the temporal order of fields in the source video stream.
enum VideoFieldOrder: Int, Sendable, Equatable {
    case progressive
    case topFirst
    case bottomFirst

    var isInterlaced: Bool {
        self != .progressive
    }
}

/// Carries source field metadata into the renderer after AVFoundation has decoded a frame.
///
/// `AVPlayerItemVideoOutput` normally supplies progressive pixel buffers even for an
/// interlaced asset. Retaining the track's format-description metadata lets Phosphor
/// reconstruct the original alternating-field presentation instead of losing it at decode.
struct VideoScanMetadata: Sendable, Equatable {
    static let progressive = VideoScanMetadata(fieldOrder: .progressive)

    let fieldOrder: VideoFieldOrder

    /// Creates metadata from a resolved field order.
    ///
    /// - Parameter fieldOrder: Progressive, top-first, or bottom-first source order.
    init(fieldOrder: VideoFieldOrder) {
        self.fieldOrder = fieldOrder
    }

    /// Reads Core Media field-count and field-detail extensions from video descriptions.
    ///
    /// The first description explicitly declaring two fields wins. Missing or malformed
    /// metadata is treated as progressive because inventing interlacing would discard half
    /// of a genuinely progressive image on each virtual field.
    ///
    /// - Parameter formatDescriptions: Format descriptions loaded from the primary video track.
    init(formatDescriptions: [CMFormatDescription]) {
        fieldOrder = Self.detectFieldOrder(in: formatDescriptions)
    }

    /// Resolves a stable field order from Core Media extensions.
    ///
    /// - Parameter formatDescriptions: Candidate descriptions from a video track.
    /// - Returns: The declared temporal field order, or progressive when none is declared.
    private static func detectFieldOrder(
        in formatDescriptions: [CMFormatDescription]
    ) -> VideoFieldOrder {
        for description in formatDescriptions {
            guard let fieldCount = CMFormatDescriptionGetExtension(
                description,
                extensionKey: kCMFormatDescriptionExtension_FieldCount
            ) as? NSNumber,
                fieldCount.intValue == 2 else {
                continue
            }

            guard let detail = CMFormatDescriptionGetExtension(
                description,
                extensionKey: kCMFormatDescriptionExtension_FieldDetail
            ) else {
                return .topFirst
            }

            if CFEqual(detail, kCMFormatDescriptionFieldDetail_TemporalBottomFirst)
                || CFEqual(detail, kCMFormatDescriptionFieldDetail_SpatialFirstLineLate) {
                return .bottomFirst
            }
            return .topFirst
        }
        return .progressive
    }
}

import Foundation
import Metal
import OSLog

/// Opt-in, low-frequency GPU timing for profiling real Phosphor workloads.
/// Set `PHOSPHOR_GPU_DIAGNOSTICS=1` before launch to emit one sampled frame
/// roughly every four seconds at 60 fps. Normal playback pays no counter cost.
final class MetalFrameDiagnostics: @unchecked Sendable {
    private struct PassSample {
        let label: String
        let startIndex: Int
        let endIndex: Int
    }

    private let device: any MTLDevice
    private let sampleBuffer: any MTLCounterSampleBuffer
    private let logger = Logger(
        subsystem: "com.joeyazizoff.Phosphor",
        category: "MetalPerformance"
    )

    private var frameNumber: UInt64 = 0
    private var isSampling = false
    private var nextSampleIndex = 0
    private var openPass: (label: String, startIndex: Int)?
    private var passes: [PassSample] = []
    private var startingClocks: (cpu: MTLTimestamp, gpu: MTLTimestamp)?

    static func makeIfRequested(device: any MTLDevice) -> MetalFrameDiagnostics? {
        guard ProcessInfo.processInfo.environment["PHOSPHOR_GPU_DIAGNOSTICS"] == "1",
              device.supportsCounterSampling(.atDrawBoundary),
              let timestampSet = device.counterSets?.first(where: {
                  $0.name == MTLCommonCounterSet.timestamp.rawValue
              }) else {
            return nil
        }

        let descriptor = MTLCounterSampleBufferDescriptor()
        descriptor.label = "Phosphor Per-pass GPU Timestamps"
        descriptor.counterSet = timestampSet
        descriptor.storageMode = .shared
        descriptor.sampleCount = 32

        guard let sampleBuffer = try? device.makeCounterSampleBuffer(
            descriptor: descriptor
        ) else {
            return nil
        }
        return MetalFrameDiagnostics(device: device, sampleBuffer: sampleBuffer)
    }

    private init(
        device: any MTLDevice,
        sampleBuffer: any MTLCounterSampleBuffer
    ) {
        self.device = device
        self.sampleBuffer = sampleBuffer
    }

    func beginFrame() {
        frameNumber &+= 1
        isSampling = frameNumber == 1 || frameNumber.isMultiple(of: 240)
        guard isSampling else { return }

        nextSampleIndex = 0
        openPass = nil
        passes.removeAll(keepingCapacity: true)
        startingClocks = device.sampleTimestamps()
    }

    func beginPass(
        _ label: String,
        encoder: any MTLRenderCommandEncoder
    ) {
        guard isSampling,
              openPass == nil,
              nextSampleIndex + 1 < sampleBuffer.sampleCount else {
            return
        }

        let startIndex = nextSampleIndex
        nextSampleIndex += 1
        encoder.sampleCounters(
            sampleBuffer: sampleBuffer,
            sampleIndex: startIndex,
            barrier: true
        )
        openPass = (label, startIndex)
    }

    func endPass(encoder: any MTLRenderCommandEncoder) {
        guard isSampling,
              let openPass,
              nextSampleIndex < sampleBuffer.sampleCount else {
            return
        }

        let endIndex = nextSampleIndex
        nextSampleIndex += 1
        encoder.sampleCounters(
            sampleBuffer: sampleBuffer,
            sampleIndex: endIndex,
            barrier: true
        )
        passes.append(PassSample(
            label: openPass.label,
            startIndex: openPass.startIndex,
            endIndex: endIndex
        ))
        self.openPass = nil
    }

    func completeFrame(commandBuffer: any MTLCommandBuffer) {
        guard isSampling,
              nextSampleIndex > 0,
              let startingClocks else {
            return
        }

        let endingClocks = device.sampleTimestamps()
        guard let data = try? sampleBuffer.resolveCounterRange(
            0 ..< nextSampleIndex
        ) else {
            return
        }

        let timestamps = data.withUnsafeBytes {
            Array($0.bindMemory(to: MTLCounterResultTimestamp.self))
        }
        let cpuSpan = Double(endingClocks.cpu &- startingClocks.cpu)
        let gpuSpan = Double(endingClocks.gpu &- startingClocks.gpu)
        guard cpuSpan > 0, gpuSpan > 0 else { return }

        let passReport = passes.compactMap { passSample -> String? in
            guard passSample.startIndex < timestamps.count,
                  passSample.endIndex < timestamps.count else {
                return nil
            }
            let start = timestamps[passSample.startIndex].timestamp
            let end = timestamps[passSample.endIndex].timestamp
            guard start != MTLCounterErrorValue,
                  end != MTLCounterErrorValue,
                  end >= start else {
                return nil
            }
            let milliseconds = Self.milliseconds(
                gpuDelta: Double(end - start),
                gpuClockSpan: gpuSpan,
                cpuClockSpan: cpuSpan
            )
            return "\(passSample.label)=\(String(format: "%.3f", milliseconds))ms"
        }.joined(separator: ", ")

        let totalMilliseconds = max(
            0,
            (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1_000
        )
        logger.info(
            "GPU frame \(totalMilliseconds, format: .fixed(precision: 3))ms; \(passReport, privacy: .public)"
        )
    }

    static func milliseconds(
        gpuDelta: Double,
        gpuClockSpan: Double,
        cpuClockSpan: Double
    ) -> Double {
        guard gpuDelta >= 0, gpuClockSpan > 0, cpuClockSpan > 0 else {
            return 0
        }
        return gpuDelta / gpuClockSpan * cpuClockSpan / 1_000_000
    }
}

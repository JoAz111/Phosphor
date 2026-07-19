import Foundation

/// Smooths GPU timing noise and chooses a presentation cadence that the final
/// native-resolution phosphor pass can sustain without dropped display ticks.
final class MetalFrameBudgetController: @unchecked Sendable {
    private let lock = NSLock()
    private var movingGPUTime: TimeInterval = 0
    private var sampleCount = 0
    private var overBudgetCount = 0
    private var recoveryCount = 0
    private var recommendedMaximum: Float?

    func reset() {
        lock.withLock {
            movingGPUTime = 0
            sampleCount = 0
            overBudgetCount = 0
            recoveryCount = 0
            recommendedMaximum = nil
        }
    }

    func recordPresentation(
        gpuDuration: TimeInterval,
        displayMaximum: Float
    ) {
        guard gpuDuration.isFinite,
              gpuDuration > 0,
              displayMaximum.isFinite,
              displayMaximum >= 24 else {
            return
        }

        lock.withLock {
            let smoothing = sampleCount == 0 ? 1.0 : 0.08
            movingGPUTime += (gpuDuration - movingGPUTime) * smoothing
            sampleCount += 1

            let highRefreshBudget = 1 / Double(displayMaximum)
            if movingGPUTime > highRefreshBudget * 0.82 {
                overBudgetCount += 1
                recoveryCount = 0
            } else {
                overBudgetCount = max(overBudgetCount - 1, 0)
                if movingGPUTime < highRefreshBudget * 0.55 {
                    recoveryCount += 1
                } else {
                    recoveryCount = 0
                }
            }

            if displayMaximum > 60, overBudgetCount >= 18 {
                recommendedMaximum = 60
                overBudgetCount = 0
            } else if recommendedMaximum != nil, recoveryCount >= 180 {
                recommendedMaximum = nil
                recoveryCount = 0
            }
        }
    }

    func maximumFrameRate(displayMaximum: Float) -> Float {
        lock.withLock {
            min(recommendedMaximum ?? displayMaximum, displayMaximum)
        }
    }
}

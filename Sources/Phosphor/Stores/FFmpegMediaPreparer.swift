import CryptoKit
import Foundation

enum FFmpegPreparationMode: String, Sendable {
    case remux
    case transcode
}

enum FFmpegVideoEncoder: Sendable, CaseIterable {
    case videoToolbox
    case libx264
    case mpeg4
}

enum FFmpegPreparationError: Error, Equatable {
    case sourceNotFound
    case unableToCreateCache
    case processFailed(exitStatus: Int32)
    case emptyOutput
}

enum FFmpegExecutableLocator {
    static func locate(
        resourceURL: URL? = Bundle.main.resourceURL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        candidateURLs(resourceURL: resourceURL, environment: environment)
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    static func candidateURLs(
        resourceURL: URL?,
        environment: [String: String]
    ) -> [URL] {
        var candidates: [URL] = []

        if let resourceURL {
            candidates.append(resourceURL.appending(path: "ffmpeg"))
        }
        if let override = environment["PHOSPHOR_FFMPEG_PATH"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path
                .split(separator: ":")
                .map { URL(fileURLWithPath: String($0)).appending(path: "ffmpeg") })
        }

        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        ])

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

struct FFmpegMediaPreparer: Sendable {
    let executableURL: URL
    private let cacheDirectory: URL

    init(
        executableURL: URL,
        cacheDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.executableURL = executableURL
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory(
            fileManager: fileManager
        )
    }

    func prepare(
        _ sourceURL: URL,
        mode: FFmpegPreparationMode
    ) async throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw FFmpegPreparationError.sourceNotFound
        }

        do {
            try fileManager.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw FFmpegPreparationError.unableToCreateCache
        }

        let cacheKey = try Self.cacheKey(
            sourceURL: sourceURL,
            mode: mode,
            fileManager: fileManager
        )
        let outputURL = cacheDirectory.appending(path: "\(cacheKey).mov")
        if Self.hasUsableFile(at: outputURL, fileManager: fileManager) {
            return outputURL
        }

        let encoders: [FFmpegVideoEncoder?] = mode == .remux
            ? [nil]
            : FFmpegVideoEncoder.allCases.map(Optional.some)
        var lastStatus: Int32 = -1

        for encoder in encoders {
            let temporaryURL = cacheDirectory.appending(
                path: "\(cacheKey).\(UUID().uuidString).partial.mov"
            )
            defer { try? fileManager.removeItem(at: temporaryURL) }

            let status = try await FFmpegProcess.run(
                executableURL: executableURL,
                arguments: Self.arguments(
                    sourceURL: sourceURL,
                    outputURL: temporaryURL,
                    mode: mode,
                    videoEncoder: encoder ?? .videoToolbox
                )
            )
            lastStatus = status
            guard status == 0,
                  Self.hasUsableFile(at: temporaryURL, fileManager: fileManager) else {
                continue
            }

            if Self.hasUsableFile(at: outputURL, fileManager: fileManager) {
                return outputURL
            }
            try fileManager.moveItem(at: temporaryURL, to: outputURL)
            return outputURL
        }

        if lastStatus == 0 {
            throw FFmpegPreparationError.emptyOutput
        }
        throw FFmpegPreparationError.processFailed(exitStatus: lastStatus)
    }

    static func arguments(
        sourceURL: URL,
        outputURL: URL,
        mode: FFmpegPreparationMode,
        videoEncoder: FFmpegVideoEncoder = .videoToolbox
    ) -> [String] {
        var arguments = [
            "-hide_banner",
            "-nostdin",
            "-loglevel", "error",
            "-y",
            "-i", sourceURL.path,
            "-map", "0:v:0",
            "-map", "0:a:0?",
            "-map_metadata", "0",
            "-sn",
            "-dn"
        ]

        switch mode {
        case .remux:
            arguments += [
                "-c", "copy"
            ]
        case .transcode:
            arguments += ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"]
            switch videoEncoder {
            case .videoToolbox:
                arguments += [
                    "-c:v", "h264_videotoolbox",
                    "-allow_sw", "1",
                    "-q:v", "65",
                    "-profile:v", "high",
                    "-pix_fmt", "yuv420p"
                ]
            case .libx264:
                arguments += [
                    "-c:v", "libx264",
                    "-preset", "medium",
                    "-crf", "16",
                    "-profile:v", "high",
                    "-pix_fmt", "yuv420p"
                ]
            case .mpeg4:
                arguments += [
                    "-c:v", "mpeg4",
                    "-q:v", "2",
                    "-pix_fmt", "yuv420p"
                ]
            }
            arguments += [
                "-c:a", "aac",
                "-b:a", "256k"
            ]
        }

        arguments += [
            "-movflags", "+faststart",
            "-f", "mov",
            outputURL.path
        ]
        return arguments
    }

    static func cacheKey(
        sourceURL: URL,
        mode: FFmpegPreparationMode,
        fileManager: FileManager
    ) throws -> String {
        let canonicalURL = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        let attributes = try fileManager.attributesOfItem(atPath: canonicalURL.path)
        let size = attributes[.size] as? NSNumber ?? 0
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        let identity = [
            canonicalURL.path,
            size.stringValue,
            String(modified.timeIntervalSince1970),
            mode.rawValue,
            "phosphor-ffmpeg-v1"
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func defaultCacheDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appending(path: "com.joeyazizoff.Phosphor", directoryHint: .isDirectory)
            .appending(path: "PreparedMedia", directoryHint: .isDirectory)
    }

    private static func hasUsableFile(
        at url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 0
    }
}

private enum FFmpegProcess {
    static func run(
        executableURL: URL,
        arguments: [String]
    ) async throws -> Int32 {
        let handle = RunningProcessHandle()

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()

                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try handle.start(process)
                defer { handle.clear(process) }

                process.waitUntilExit()
                try Task.checkCancellation()
                return process.terminationStatus
            }.value
        } onCancel: {
            handle.cancel()
        }
    }
}

private final class RunningProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    func start(_ process: Process) throws {
        lock.lock()
        if isCancelled {
            lock.unlock()
            throw CancellationError()
        }
        self.process = process
        do {
            try process.run()
            lock.unlock()
        } catch {
            self.process = nil
            lock.unlock()
            throw error
        }
    }

    func clear(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let process = process
        lock.unlock()

        if process?.isRunning == true {
            process?.terminate()
        }
    }
}

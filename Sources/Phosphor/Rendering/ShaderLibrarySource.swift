import Foundation
import Metal

enum ShaderLibrarySource {
    enum Error: Swift.Error {
        case resourceMissing
    }

    static func load() throws -> String {
        guard let url = Bundle.module.url(
            forResource: "PhosphorShaders",
            withExtension: "metal"
        ) else {
            throw Error.resourceMissing
        }

        return try String(contentsOf: url, encoding: .utf8)
    }

    static func makeLibrary(
        device: any MTLDevice
    ) throws -> any MTLLibrary {
        if let precompiledURL = Bundle.module.url(
            forResource: "PhosphorShaders",
            withExtension: "metallib"
        ) {
            return try device.makeLibrary(URL: precompiledURL)
        }

        return try device.makeLibrary(source: load(), options: nil)
    }
}

import Foundation

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
}

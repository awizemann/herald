import Foundation
import Testing

/// Structural guards. These fail on a source-tree property that no runtime test
/// can see: that the generated OpenAPI types stay contained, and that the
/// project's concurrency/logging conventions are not quietly broken.
@Suite struct SourceBoundaryTests {
    /// Only these two files are allowed to know that `HeraldAPI` exists.
    static let generatedTypeGatekeepers: Set<String> = ["Mapping.swift", "HQBaseAPIClient.swift"]

    private static var sourcesDirectory: URL {
        // .../HeraldKit/Tests/HeraldKitTests/SourceBoundaryTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/HeraldKit")
    }

    private static func swiftFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: sourcesDirectory, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    @Test("Generated HeraldAPI types stay behind the mapping boundary")
    func generatedTypesDoNotLeak() throws {
        let offenders = try Self.swiftFiles().filter { url in
            guard !Self.generatedTypeGatekeepers.contains(url.lastPathComponent) else { return false }
            let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return source.contains("import HeraldAPI")
        }
        // A DTO or protocol importing HeraldAPI is how generated types escape into
        // the app; catching it here is cheaper than an audit later.
        #expect(offenders.map(\.lastPathComponent).sorted() == [])
    }

    @Test("No print() in shipped sources")
    func noPrintStatements() throws {
        let offenders = try Self.swiftFiles().filter { url in
            let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return source.contains("print(")
        }
        #expect(offenders.map(\.lastPathComponent).sorted() == [])
    }

    @Test("Loggers are declared nonisolated so actors can use them")
    func loggersAreNonisolated() throws {
        let offenders = try Self.swiftFiles().filter { url in
            let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return source
                .split(separator: "\n")
                .contains { $0.contains("= Logger(") && !$0.contains("nonisolated") }
        }
        #expect(offenders.map(\.lastPathComponent).sorted() == [])
    }
}

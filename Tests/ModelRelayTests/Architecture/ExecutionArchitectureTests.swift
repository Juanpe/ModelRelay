import Foundation
import Testing

@Suite struct ExecutionArchitectureTests {
    private static let facadeLimit: Int = 200
    private static let reviewLimit: Int = 400
    private static let repository: URL = .init(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func executorFacadeStaysSmall() throws {
        let file: URL = Self.repository.appending(path: "Sources/ModelRelay/Execution/WorkflowExecutor.swift")
        #expect(try lineCount(in: file) <= Self.facadeLimit, "Keep execution mechanics out of the facade")
    }

    @Test func productionFilesStayFocused() throws {
        try checkFileSizes(in: "Sources")
    }

    @Test func testFilesStayFocused() throws {
        try checkFileSizes(in: "Tests")
    }

    @Test func coreFilesLiveInFeatureDirectories() throws {
        let core: URL = Self.repository.appending(path: "Sources/ModelRelay")
        let files: [URL] = try FileManager.default.contentsOfDirectory(at: core, includingPropertiesForKeys: nil)
        #expect(files.allSatisfy { $0.pathExtension != "swift" }, "Place source files with the feature they belong to")
    }

    private func checkFileSizes(in directory: String) throws {
        let root: URL = Self.repository.appending(path: directory)
        let enumerator: FileManager.DirectoryEnumerator = try #require(FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))
        let files: [URL] = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)

        for file in files {
            let name: String = file.path.replacingOccurrences(of: Self.repository.path + "/", with: "")
            #expect(try lineCount(in: file) <= Self.reviewLimit, "\(name): split responsibilities before adding more code")
        }
    }

    private func lineCount(in file: URL) throws -> Int {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

import Foundation
import Testing

@testable import MapAutomation

/// F-INT-4, ADR-0030: the helper ↔ app Unix-domain socket — a round trip
/// against a fake app endpoint, plus the refused-connection path (app
/// closed) that the helper falls back from.
struct UnixSocketTests {
    /// A fake app endpoint: it answers `list_maps` from a canned record
    /// and fails everything else, exactly the shapes the app handler
    /// produces.
    private static func fakeHandler(request: SocketToolRequest) async -> SocketToolResponse {
        if request.tool == "list_maps" {
            return .success(
                .object([("maps", .array([.object([("docID", .string("fake-doc"))])]))]))
        }
        return .failure(ToolFailure(kind: .notFound, message: "fake endpoint only answers list_maps"))
    }

    @Test func roundTripWithAFakeAppEndpoint() throws {
        let directory = try FixtureMap.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = AutomationPaths.socketURL(directory: directory).path

        let server = UnixSocketServer(path: socketPath, handler: Self.fakeHandler)
        try server.start()
        defer { server.stop() }

        let client = SocketToolClient(path: socketPath, timeout: 10)
        let response = try #require(
            try client.perform(SocketToolRequest(tool: "list_maps", arguments: .object([:]))))
        #expect(response.result?["maps"]?.array?.first?["docID"]?.string == "fake-doc")

        let failure = try #require(
            try client.perform(SocketToolRequest(tool: "read_map", arguments: .object([:]))))
        #expect(failure.failure?.kind == .notFound)
    }

    @Test func socketFileIsPrivate() throws {
        let directory = try FixtureMap.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = AutomationPaths.socketURL(directory: directory).path

        let server = UnixSocketServer(path: socketPath, handler: Self.fakeHandler)
        try server.start()
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func unreachableSocketReturnsNilForLocalFallback() throws {
        let directory = try FixtureMap.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = SocketToolClient(
            path: AutomationPaths.socketURL(directory: directory).path, timeout: 1)
        let response = try client.perform(
            SocketToolRequest(tool: "list_maps", arguments: .object([:])))
        #expect(response == nil)
    }

    @Test func appOrLocalBackendFallsBackToTheFileSpace() async throws {
        let directory = try FixtureMap.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let policyDirectory = try FixtureMap.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: policyDirectory) }
        try MCPEditPolicy.save(
            MCPEditPolicy.Settings(allowEdits: false), directory: policyDirectory)
        try FixtureMap.write(at: directory.appendingPathComponent("Reno.arbor"))

        // No app listening: the backend answers from files.
        let local = MapAutomationEngine(
            space: LocalDocumentSpace(
                directory: FileSystemMapDirectory(roots: [directory]),
                defaultFolder: directory,
                policyDirectory: policyDirectory,
                appVersion: "0.1.0"))
        let backend = AppOrLocalBackend(
            socketPath: AutomationPaths.socketURL(directory: directory).path,
            policyDirectory: policyDirectory,
            local: local)
        #expect(await backend.editsAllowed() == false)
        let result = try await backend.perform(
            ToolCall(name: "read_map", arguments: .object([("doc", .string("fixture-doc"))])))
        #expect(result["content"]?.string?.contains("Kitchen Reno") == true)
    }

    /// The real socket location has to fit `sun_path`. The old one in
    /// `…/Data/Library/Application Support/Arbor/` was 106 bytes under
    /// `/Users/amarnadh`, so the app never bound and the helper always
    /// fell back to file access.
    @Test func containerSocketPathFitsSunPath() {
        let home = "/Users/a-rather-long-user-name"
        let containerHome = URL(fileURLWithPath: "\(home)/Library/Containers/com.example.arbor/Data")
        let socket = AutomationPaths.socketURL(directory: containerHome).path
        #expect(UnixSocket.makeAddress(for: socket) != nil)

        let stateDirectory = containerHome.appendingPathComponent("Library/Application Support/Arbor")
        #expect(UnixSocket.makeAddress(for: AutomationPaths.socketURL(directory: stateDirectory).path) == nil)

        #expect(
            AutomationPaths.containerHome(bundleIdentifier: "com.example.arbor").path.hasSuffix(
                "/Library/Containers/com.example.arbor/Data"))
    }
}

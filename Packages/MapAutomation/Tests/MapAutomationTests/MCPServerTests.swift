import Foundation
import MapCore
import Testing

@testable import MapAutomation

/// F-INT-4: the MCP stdio protocol — newline-delimited JSON-RPC 2.0
/// framing, the `initialize` handshake, `tools/list` read-only vs edit
/// mode, every tool against the fixture package, and the error responses
/// for bad input.
struct MCPServerTests {
    /// A local (file-backed) space over a temp directory with the
    /// fixture package, plus a policy file the test can flip.
    struct World {
        let directory: URL
        let policyDirectory: URL
        let space: LocalDocumentSpace
        let server: MCPServer

        init(allowEdits: Bool) throws {
            directory = try FixtureMap.makeTempDirectory()
            try FixtureMap.write(at: directory.appendingPathComponent("Reno.arbor"))
            policyDirectory = try FixtureMap.makeTempDirectory()
            try MCPEditPolicy.save(
                MCPEditPolicy.Settings(allowEdits: allowEdits), directory: policyDirectory)
            space = LocalDocumentSpace(
                directory: FileSystemMapDirectory(roots: [directory]),
                defaultFolder: directory,
                policyDirectory: policyDirectory,
                appVersion: "0.1.0")
            server = MCPServer(backend: MapAutomationEngine(space: space, author: .mcp))
        }

        func teardown() {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: policyDirectory)
        }

        /// Sends one method (with optional params JSON) and returns the
        /// result object.
        func request(_ method: String, params: String? = nil) async throws -> [String: JSONValue] {
            let paramsPiece = params.map { ",\"params\":\($0)" } ?? ""
            let line = #"{"jsonrpc":"2.0","id":1,"method":"\#(method)"\#(paramsPiece)}"#
            let response = try #require(await server.handle(line))
            let payload = try JSONLine.decode(response)
            return try #require(payload.object?["result"]?.object)
        }

        /// Calls a tool and returns its result: the envelope's
        /// `structuredContent` on success, or the envelope itself when the
        /// tool failed in-band (`isError: true`, with the message in
        /// `content`).
        func tool(_ name: String, _ arguments: String) async throws -> [String: JSONValue] {
            let envelope = try await request(
                "tools/call",
                params: #"{"name":"\#(name)","arguments":\#(arguments)}"#)
            if envelope["isError"]?.bool == true {
                return envelope
            }
            return try #require(envelope["structuredContent"]?.object)
        }

        /// Sends a raw `tools/call` params object (full
        /// `{"name":…,"arguments":…}` JSON) and returns the whole
        /// response payload — the tests inspect whichever of result/error
        /// it carries.
        func callRaw(_ params: String) async throws -> [String: JSONValue] {
            let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":\#(params)}"#
            let response = try #require(await server.handle(line))
            return try JSONLine.decode(response).object ?? [:]
        }
    }

    // MARK: framing

    @Test func messageReaderSplitsNewlineDelimitedMessages() {
        var reader = MessageReader()
        #expect(reader.feed(#"{"a":1}"#) == [])
        #expect(reader.feed("\n[1,") == [#"{"a":1}"#])
        #expect(reader.feed("2]\n") == ["[1,2]"])
    }

    @Test func messageReaderToleratesCRLFAndSkipsBlankLines() {
        var reader = MessageReader()
        #expect(reader.feed("{\"a\":1}\r\n\r\n{\"b\":2}\n") == ["{\"a\":1}", "{\"b\":2}"])
    }

    // MARK: handshake

    @Test func initializeHandshakeEchoesKnownProtocolVersion() async throws {
        let world = try World(allowEdits: false)
        defer { world.teardown() }
        let result = try await world.request(
            "initialize",
            params: #"{"protocolVersion":"2025-06-18"}"#
        )
        #expect(result["protocolVersion"]?.string == "2025-06-18")
        #expect(result["serverInfo"]?["name"]?.string == "arbor")
        #expect(result["capabilities"]?["tools"]?["listChanged"]?.bool == false)
    }

    @Test func initializeFallsBackToLatestForUnknownVersion() async throws {
        let world = try World(allowEdits: false)
        defer { world.teardown() }
        let result = try await world.request(
            "initialize", params: #"{"protocolVersion":"1999-01-01"}"#)
        #expect(result["protocolVersion"]?.string == MCPServer.latestVersion)
    }

    @Test func initializedNotificationGetsNoResponse() async throws {
        let world = try World(allowEdits: false)
        defer { world.teardown() }
        let line = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        #expect(await world.server.handle(line) == nil)
    }

    @Test func malformedJSONIsAParseErrorWithNullID() async throws {
        let world = try World(allowEdits: false)
        defer { world.teardown() }
        let response = try #require(await world.server.handle(#"{"jsonrpc":"2.0""#))
        let payload = try JSONLine.decode(response).object ?? [:]
        #expect(payload["id"]?.isNull == true)
        #expect(payload["error"]?["code"]?.intValue == JSONRPC.Code.parseError.rawValue)
    }

    @Test func unknownMethodIsMethodNotFound() async throws {
        let world = try World(allowEdits: false)
        defer { world.teardown() }
        let response = try #require(
            await world.server.handle(#"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#))
        let payload = try JSONLine.decode(response).object ?? [:]
        #expect(payload["error"]?["code"]?.intValue == JSONRPC.Code.methodNotFound.rawValue)
        #expect(payload["id"]?.intValue == 7)
    }

    @Test func nonJSONRPCMessageIsInvalidRequest() async throws {
        let world = try World(allowEdits: false)
        defer { world.teardown() }
        let response = try #require(
            await world.server.handle(#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#))
        let payload = try JSONLine.decode(response).object ?? [:]
        #expect(payload["error"]?["code"]?.intValue == JSONRPC.Code.invalidRequest.rawValue)
    }

    // MARK: tools/list read-only vs edit mode

    @Test func readOnlyModeHidesMutatingTools() async throws {
        let world = try World(allowEdits: false)
        defer { world.teardown() }
        let result = try await world.request("tools/list")
        let tools = try #require(result["tools"]?.array)
        let names = tools.compactMap(\.object?["name"]?.string)
        #expect(names == ["list_maps", "read_map", "search_nodes", "get_due_cards"])
    }

    @Test func editModeListsAllEightTools() async throws {
        let world = try World(allowEdits: true)
        defer { world.teardown() }
        let result = try await world.request("tools/list")
        #expect(result["tools"]?.array?.count == 8)
    }

    // MARK: read-only tools against the fixture

    @Test func listMapsSeesTheFixture() async throws {
        let world = try World(allowEdits: false)
        defer { world.teardown() }
        let result = try await world.tool("list_maps", "{}")
        let maps = try #require(result["maps"]?.array)
        #expect(maps.count == 1)
        #expect(maps[0]["docID"]?.string == "fixture-doc")
        #expect(maps[0]["title"]?.string == "Kitchen Reno")
    }

    @Test func readMapOutlineAndMarkdown() async throws {
        let world = try World(allowEdits: false)
        defer { world.teardown() }
        let outline = try await world.tool("read_map", #"{"doc":"fixture-doc"}"#)
        #expect(outline["format"]?.string == "outline")
        let content = try #require(outline["content"]?.string)
        #expect(content.contains("Kitchen Reno"))
        #expect(content.contains("Sage maybe?"))

        let markdown = try await world.tool(
            "read_map", #"{"doc":"Reno.arbor","format":"markdown"}"#)
        #expect(markdown["content"]?.string?.contains("Kitchen Reno") == true)
    }

    @Test func searchNodesAcrossFilters() async throws {
        let world = try World(allowEdits: false)
        defer { world.teardown() }
        let byTask = try await world.tool("search_nodes", #"{"task":"done"}"#)
        #expect(byTask["nodes"]?.array?.first?["title"]?.string == "Paint colors")
        let byTag = try await world.tool("search_nodes", #"{"tag":"money"}"#)
        #expect(byTag["nodes"]?.array?.count == 1)
    }

    @Test func getDueCardsForOneMap() async throws {
        let world = try World(allowEdits: false)
        defer { world.teardown() }
        let result = try await world.tool("get_due_cards", #"{"doc":"fixture-doc"}"#)
        // Root, paint and sage are all never-reviewed cards.
        #expect(result["total"]?.intValue == 3)
    }

    // MARK: mutating tools: refused read-only, applied with edits on

    @Test func mutatingToolRefusedInReadOnlyMode() async throws {
        let world = try World(allowEdits: false)
        defer { world.teardown() }
        let result = try await world.tool("add_nodes", #"{"doc":"fixture-doc","text":"nope"}"#)
        #expect(result["isError"]?.bool == true)
        #expect(result["content"]?.array?.first?["text"]?.string?.contains("read-only") == true)
        // The file was not touched.
        let contents = try HeadlessMapEditor.read(
            at: world.directory.appendingPathComponent("Reno.arbor"))
        #expect(contents.model.nodes.count == 4)
    }

    @Test func addNodesUnderParentAndAsRoot() async throws {
        let world = try World(allowEdits: true)
        defer { world.teardown() }
        let result = try await world.tool(
            "add_nodes", #"{"doc":"fixture-doc","parent":"Budget","text":"Quotes\n\tAsk Ada"}"#)
        #expect(result["added"]?.intValue == 2)

        let contents = try HeadlessMapEditor.read(
            at: world.directory.appendingPathComponent("Reno.arbor"))
        #expect(contents.validationErrors.isEmpty)
        // Appended under "Budget", in the imported hierarchy.
        let budgetChildren = contents.model.nodes["budget"]?.children ?? []
        #expect(budgetChildren.count == 1)
        let added = budgetChildren[0]
        #expect(contents.model.nodes[added]?.title.text == "Quotes")
        #expect(contents.model.nodes[added]?.children.count == 1)
        // MCP edits are marked.
        #expect(contents.model.nodes[added]?.modifiedBy == .mcp)
    }

    @Test func updateNodeTitleNoteAndTask() async throws {
        let world = try World(allowEdits: true)
        defer { world.teardown() }
        let result = try await world.tool(
            "update_node",
            #"{"doc":"fixture-doc","node":"Budget","title":"Budget 2","note":"tighten","taskDone":true}"#)
        #expect(result["isError"]?.bool != true)
        #expect(result["updated"]?.array?.count == 3)

        let contents = try HeadlessMapEditor.read(
            at: world.directory.appendingPathComponent("Reno.arbor"))
        #expect(contents.model.nodes["budget"]?.title.text == "Budget 2")
        #expect(contents.model.nodes["budget"]?.note == "tighten")
        #expect(contents.model.nodes["budget"]?.task?.done == true)
    }

    @Test func moveNodeToAnotherParent() async throws {
        let world = try World(allowEdits: true)
        defer { world.teardown() }
        let result = try await world.tool(
            "move_node", #"{"doc":"fixture-doc","node":"Budget","parent":"Paint colors"}"#)
        #expect(result["parent"]?.string == "paint")
        let contents = try HeadlessMapEditor.read(
            at: world.directory.appendingPathComponent("Reno.arbor"))
        #expect(contents.model.nodes["budget"]?.parent == "paint")
        #expect(contents.model.nodes["paint"]?.children.contains("budget") == true)
        #expect(contents.model.nodes["root"]?.children.contains("budget") == false)
    }

    @Test func createMapWritesAPackage() async throws {
        let world = try World(allowEdits: true)
        defer { world.teardown() }
        let result = try await world.tool(
            "create_map", #"{"title":"Reading list","outline":"Books\n\tEssays"}"#)
        let path = try #require(result["path"]?.string)
        #expect(path.hasSuffix(".arbor"))
        let contents = try HeadlessMapEditor.read(at: URL(fileURLWithPath: path))
        #expect(contents.model.title == "Reading list")
        #expect(contents.validationErrors.isEmpty)
    }

    // MARK: bad input

    @Test func unknownToolIsInvalidParams() async throws {
        let world = try World(allowEdits: true)
        defer { world.teardown() }
        let payload = try await world.callRaw(#"{"name":"frobnicate"}"#)
        #expect(payload["error"]?["code"]?.intValue == JSONRPC.Code.invalidParams.rawValue)
    }

    @Test(arguments: [
        #"{"name":"read_map"}"#,
        #"{"name":"search_nodes","arguments":{}}"#,
        #"{"name":"read_map","arguments":{"doc":"fixture-doc","format":"bogus"}}"#,
        #"{"name":"update_node","arguments":{"doc":"fixture-doc","node":"budget"}}"#,
    ]) func badArgumentsReportInvalidParams(json: String) async throws {
        let world = try World(allowEdits: true)
        defer { world.teardown() }
        let payload = try await world.callRaw(json)
        #expect(payload["error"]?["code"]?.intValue == JSONRPC.Code.invalidParams.rawValue)
    }

    @Test func missingDocReportsInBandNotFound() async throws {
        let world = try World(allowEdits: true)
        defer { world.teardown() }
        let result = try await world.tool("read_map", #"{"doc":"missing-map"}"#)
        #expect(result["isError"]?.bool == true)
        #expect(result["content"]?.array?.first?["text"]?.string?.contains("missing-map") == true)
    }
}

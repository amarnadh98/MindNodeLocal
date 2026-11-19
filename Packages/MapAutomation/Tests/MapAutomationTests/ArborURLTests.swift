import Foundation
import Testing

@testable import MapAutomation

/// F-INT-5: every `x-arbor://` route, percent-encoding, and the graceful
/// failures for malformed input.
struct ArborURLTests {
    @Test func openRouteWithNode() throws {
        let route = try ArborURL.parse("x-arbor://open?doc=ABC-123&node=n9")
        #expect(route == .open(doc: "ABC-123", node: "n9"))
    }

    @Test func openRouteWithoutNode() throws {
        let route = try ArborURL.parse("x-arbor://open?doc=abc")
        #expect(route == .open(doc: "abc", node: nil))
    }

    @Test func percentEncodedParameters() throws {
        let route = try ArborURL.parse("x-arbor://add?doc=a&parent=B%20ranch&text=Hello%20%26%20goodbye")
        #expect(route == .add(doc: "a", parent: "B ranch", text: "Hello & goodbye"))
    }

    @Test func newRouteWithBothParameters() throws {
        let route = try ArborURL.parse("x-arbor://new?title=Trip%20ideas&outline=%23%20Trip")
        #expect(route == .newDocument(title: "Trip ideas", outline: "# Trip"))
    }

    @Test func newRouteWithNothing() throws {
        let route = try ArborURL.parse("x-arbor://new")
        #expect(route == .newDocument(title: nil, outline: nil))
    }

    @Test func studyRoute() throws {
        let route = try ArborURL.parse("x-arbor://study?doc=d")
        #expect(route == .study(doc: "d"))
    }

    @Test func schemeIsCaseInsensitive() throws {
        let route = try ArborURL.parse("X-ARBOR://open?doc=a")
        #expect(route == .open(doc: "a", node: nil))
    }

    @Test(arguments: [
        ("x-arbor://", ArborURL.ParseError.missingRoute),
        ("x-arbor://frobnicate?doc=a", .unknownRoute("frobnicate")),
        ("x-arbor://open", .missingParameter("doc")),
        ("x-arbor://open?node=n", .missingParameter("doc")),
        ("x-arbor://add?doc=a", .missingParameter("text")),
        ("x-arbor://study", .missingParameter("doc")),
    ]) func malformedInput(parameter: (String, ArborURL.ParseError)) throws {
        #expect(throws: parameter.1) { try ArborURL.parse(parameter.0) }
    }

    @Test func wrongSchemeIsRefused() throws {
        #expect(throws: ArborURL.ParseError.self) { try ArborURL.parse("https://arbor.example/open?doc=a") }
    }

    @Test func errorMessagesAreUserReadable() throws {
        let error: any Error = ArborURL.ParseError.missingParameter("doc")
        #expect(String(describing: error).contains("\"doc\""))
    }
}

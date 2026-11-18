import Foundation
import Testing

@testable import MapLibrary

@Test func entryCodableRoundTrip() throws {
    let entry = LibraryEntry(
        docID: "6C74A1E2-1E52-4DFB-9A21-1D33CB0F6B8F",
        path: "/Users/me/Maps/Roadmap.arbor",
        title: "Roadmap",
        modified: Date(timeIntervalSinceReferenceDate: 2_000)
    )
    let data = try JSONEncoder().encode(entry)
    let decoded = try JSONDecoder().decode(LibraryEntry.self, from: data)
    #expect(decoded == entry)
}

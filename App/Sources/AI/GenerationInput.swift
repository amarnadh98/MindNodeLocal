import Foundation
import MapAI
import PDFKit

/// F-AI-3's App-layer input resolution: turning a PDF or a URL into
/// plain text BEFORE MapAI ever sees it — MapAI never fetches
/// (SPEC §12: network only for user-initiated imports).
enum GenerationInput {
    /// PDFKit text extraction: every page's string, page breaks kept as
    /// newlines. Long PDFs are truncated by the prompt builder, not
    /// here (the caller may want the full text elsewhere someday).
    static func pdfText(at url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw AIError.invalidResponse("could not read the PDF")
        }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            if let pageText = document.page(at: index)?.string {
                pages.append(pageText)
            }
        }
        let text = pages.joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.invalidResponse("the PDF has no extractable text")
        }
        return text
    }

    /// A plain URLSession GET (SPEC §12: user-initiated only) plus
    /// crude HTML→text extraction: scripts and styles dropped, tags
    /// stripped, entities decoded, whitespace squeezed. Good enough to
    /// feed a summarizer; nothing here is rendered.
    static func fetchText(from url: URL) async throws -> String {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw AIError.invalidResponse("the URL did not return text")
            }
            guard
                let raw = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
            else {
                throw AIError.invalidResponse("the URL did not return text")
            }
            return htmlToText(raw)
        } catch let error as AIError {
            throw error
        } catch {
            throw AIError.network(String(describing: (error as NSError).code))
        }
    }

    static func htmlToText(_ html: String) -> String {
        var text = html
        for pattern in [
            #"(?s)<script.*?</script>"#, #"(?s)<style.*?</style>"#,
            #"(?s)<!--.*?-->"#,
        ] {
            text = text.replacingOccurrences(
                of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(
            of: #"</\s*(p|div|h[1-6]|li|tr|br)"#,
            with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(
            of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        // Common entities; anything else is left as-is (harmless).
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
        ]
        for (entity, character) in entities {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = text.replacingOccurrences(
            of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

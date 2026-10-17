import Foundation
import Testing
@testable import ModelRelay

@Suite struct PageReadingTests {
    static let article = """
        <!doctype html><html><head><title>Apple ships a new model</title>
        <style>body { color: red }</style><script>alert("x")</script></head>
        <body><nav>Home · News · About</nav>
        <article><h1>Apple ships a new model</h1><p>It runs <b>on device</b> &amp; stays private.</p>
        <ul><li>Fast</li><li>Small</li></ul><p>Try today&#8217;s build.</p></article>
        <footer>© 2026</footer></body></html>
        """

    @Test func aPageIsReadAsItsText() async throws {
        let server = FakeServer(json: Self.article)
        let workflow = Workflow(name: "Read", steps: [
            Step("page", .request(HTTPRequest(url: "{{input}}", reading: .page))),
        ])
        let report = try await WorkflowExecutor(requests: server).run(workflow, input: .text(" https://example.com/news?id=1 "))
        #expect(server.requests.first?.url.absoluteString == "https://example.com/news?id=1")
        let text = report.output.textValue
        #expect(text.hasPrefix("Apple ships a new model"))
        #expect(text.contains("It runs on device & stays private."))
        #expect(text.contains("• Fast"))
        #expect(text.contains("today’s build"))
        for gone in ["alert", "color: red", "Home · News", "©", "<"] { #expect(!text.contains(gone)) }
    }

    @Test func aWholeAddressValueMustStillBeAWebAddress() async {
        let workflow = Workflow(name: "Read", steps: [
            Step("page", .request(HTTPRequest(url: "{{input}}", reading: .page))),
        ])
        for bad in ["file:///etc/passwd", "not a link", ""] {
            await #expect(throws: RelayError.self) {
                try await WorkflowExecutor(requests: FakeServer(json: "{}")).run(workflow, input: .text(bad))
            }
        }
    }

    @Test func valuesInsideAnAddressAreStillEncoded() async throws {
        let server = FakeServer(json: "{}")
        let workflow = Workflow(name: "Search", steps: [
            Step("s", .request(HTTPRequest(url: "https://example.com/search?q={{input}}"))),
        ])
        _ = try await WorkflowExecutor(requests: server).run(workflow, input: .text("https://evil.example/&x=1"))
        #expect(server.requests.first?.url.host() == "example.com")
        #expect(server.requests.first?.url.query()?.contains("&x=1") == false)
    }

    @Test func aPageWithNoTextFails() async {
        let workflow = Workflow(name: "Read", steps: [
            Step("page", .request(HTTPRequest(url: "https://example.com", reading: .page))),
        ])
        await #expect(throws: expectedOperationFailure(step: "page", reason: "The page has no readable text", category: .invalidOutput)) {
            try await WorkflowExecutor(requests: FakeServer(json: "<html><body><script>x</script></body></html>"))
                .run(workflow, input: .text(""))
        }
    }

    @Test func requestsWithoutReadingStillDecodeAsBefore() throws {
        let old = #"{"method":"GET","url":"https://x.dev","headers":[]}"#
        let request = try JSONDecoder().decode(HTTPRequest.self, from: Data(old.utf8))
        #expect(request.reading == nil)
        #expect(!String(decoding: try JSONEncoder().encode(request), as: UTF8.self).contains("reading"))
    }

    @Test func longPagesAreCut() throws {
        let body = "<html><body><p>" + String(repeating: "word ", count: 20000) + "</p></body></html>"
        let value = try RequestBuilder.value(from: HTTPResponse(status: 200, body: Data(body.utf8)), reading: .page)
        #expect(value.textValue.count <= PageText.maxCharacters + 1)
    }
}

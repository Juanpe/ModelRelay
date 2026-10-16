import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ModelRelay

/// A white picture with `text` in large black letters, as PNG.
func picture(_ text: String = "", width: Int = 900, height: Int = 220) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 80, nil)
    let string = NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
    ])
    context.textPosition = CGPoint(x: 40, y: 80)
    CTLineDraw(CTLineCreateWithAttributedString(string), context)
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

@Suite struct ImageReadingTests {
    private func reader(_ instruction: String = "", model: ModelID = "eyes", fallback: ModelID? = nil) -> Workflow {
        Workflow(name: "OCR", steps: [Step("read", .readImage(instruction: instruction), model: model, fallback: fallback)])
    }

    @Test func theModelSeesTheImageAndTheInstruction() async throws {
        let model = ScriptedModel("eyes", replies: ["TOTAL 8.30"])
        let executor = WorkflowExecutor(catalog: .scripted(["eyes": model]))
        let image = ImageValue(data: picture(), contentType: "image/png")
        let report = try await executor.run(reader(), input: .image(image))
        #expect(report.output == .text("TOTAL 8.30"))
        #expect(model.images.count == 1)
        #expect(model.images.first.flatMap { image in
            if case .data(let data, _) = image.source { return ImageCoding.picture(from: data)?.width }
            return nil
        } == 900)
        #expect(model.prompts.first?.contains("all the text in the image") == true)
        // The record says what was read, never the bytes.
        let input = try #require(report.records.first?.input)
        #expect(input.contains("Image: PNG"))
        #expect(input.count < 400)
    }

    @Test func instructionsCanUseTheTextThatCameWithTheImage() async throws {
        let model = ScriptedModel("eyes", replies: ["8.30"])
        let executor = WorkflowExecutor(catalog: .scripted(["eyes": model]))
        let image = ImageValue(data: picture(), contentType: "image/png", text: "the total")
        _ = try await executor.run(reader("Find {{input}} on this receipt."), input: .image(image))
        #expect(model.prompts.first == "Find the total on this receipt.")
    }

    @Test func textInsteadOfAnImageFailsClearly() async throws {
        let model = ScriptedModel("eyes", replies: ["never"])
        let executor = WorkflowExecutor(catalog: .scripted(["eyes": model]))
        await #expect(throws: RelayError.stepFailed(step: "read", reason: "it needs an image, and got text")) {
            try await executor.run(reader(), input: .text("A web page"))
        }
        #expect(model.callCount == 0)
    }

    @Test func aModelThatCantSeeImagesGoesToTheFallback() async throws {
        let blind = ScriptedModel("blind", replies: ["guess"], seesImages: false)
        let eyes = ScriptedModel("eyes", replies: ["Hello"])
        let executor = WorkflowExecutor(catalog: .scripted(["blind": blind, "eyes": eyes]))
        let image = ImageValue(data: picture(), contentType: "image/png")
        let report = try await executor.run(reader(model: "blind", fallback: "eyes"), input: .image(image))
        #expect(report.output == .text("Hello"))
        #expect(report.records.first?.usedFallback == true)
        #expect(blind.callCount == 0)

        await #expect(throws: WorkflowValidationError(issues: [.init(step: "read", kind: .incompatibleModel, detail: "no configured model supports this step")])) {
            try await executor.run(reader(model: "blind"), input: .image(image))
        }
    }

    @Test func aBrokenImageFails() async throws {
        let executor = WorkflowExecutor(catalog: .scripted(["eyes": ScriptedModel("eyes", replies: ["x"])]))
        await #expect(throws: expectedOperationFailure(step: "read", reason: "The image couldn't be opened", category: .invalidOutput)) {
            try await executor.run(reader(), input: .image(ImageValue(data: Data("not a picture".utf8), contentType: "image/png")))
        }
    }

    @Test func appleTextRecognitionOnlyReadsImages() async throws {
        let workflow = Workflow(name: "Ask", steps: [Step("ask", .prompt(instruction: "Say hi."), model: .appleTextRecognition)])
        do {
            _ = try await WorkflowExecutor().run(workflow, input: .text(""))
            Issue.record("A text prompt should fail")
        } catch let error as WorkflowValidationError {
            #expect(error.issues.contains { $0.step == "ask" && $0.kind == .incompatibleModel })
        }
    }

    @Test func textOnTheSameRowBecomesOneLine() {
        // A receipt: items on the left, prices on the right, a title above.
        let lines = TextRecognitionModel.Recognition.lines([
            ("Latte", CGRect(x: 0.1, y: 0.60, width: 0.2, height: 0.04)),
            ("4.50", CGRect(x: 0.7, y: 0.605, width: 0.1, height: 0.04)),
            ("Croissant", CGRect(x: 0.1, y: 0.50, width: 0.3, height: 0.04)),
            ("BLUE BOTTLE", CGRect(x: 0.1, y: 0.80, width: 0.5, height: 0.05)),
            ("3.80", CGRect(x: 0.7, y: 0.495, width: 0.1, height: 0.04)),
        ])
        #expect(lines == ["BLUE BOTTLE", "Latte 4.50", "Croissant 3.80"])
    }

    @Test func imagesSaveAndReadAsTheirText() throws {
        let value = Value.image(ImageValue(data: Data([1, 2, 3]), contentType: "image/jpeg", text: "caption"))
        let decoded = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
        #expect(value.textValue == "caption")
        #expect(value.jsonText == #""caption""#)
    }

    @Test func imagesAreSentUprightAndSmall() throws {
        let wide = try #require(ImageCoding.picture(from: picture(width: 4000, height: 1000)))
        let flat = try #require(ImageCoding.encoded(wide))
        #expect(flat.contentType == "image/jpeg")
        let sent = try #require(ImageCoding.picture(from: flat.data))
        #expect(sent.width == 2048 && sent.height == 512)

        // A photo taken sideways is turned before it's sent.
        let turned = try #require(ImageCoding.encoded(wide, orientation: .right))
        let upright = try #require(ImageCoding.picture(from: turned.data))
        #expect(upright.width == 512 && upright.height == 2048)
    }
}

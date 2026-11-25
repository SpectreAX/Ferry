import XCTest
@testable import Ferry

final class ClipboardRendererTests: XCTestCase {
    func testHTMLEscaping() {
        XCTAssertEqual(ClipboardRenderer.escape(#"a < b && c > "d" 'e'"#),
                       "a &lt; b &amp;&amp; c &gt; &quot;d&quot; &#39;e&#39;")
    }

    func testFileURLIsPercentEncoded() {
        XCTAssertEqual(ClipboardRenderer.fileURLString("/Users/me/My Notes/assets/猫 1.png"),
                       "file:///Users/me/My%20Notes/assets/%E7%8C%AB%201.png")
    }

    func testHTMLRendering() {
        let fragment = Fragment(segments: [
            .init(text: "<b>x</b> & y\nline 2\r\nline 3"),
            .init(image: .init(path: "/tmp/a b/图.png", alt: #"say "hi""#)),
        ])
        XCTAssertEqual(ClipboardRenderer.html(fragment),
                       #"<meta charset="utf-8">&lt;b&gt;x&lt;/b&gt; &amp; y<br>line 2<br>line 3"#
                       + #"<img src="file:///tmp/a%20b/%E5%9B%BE.png" alt="say &quot;hi&quot;">"#)
        XCTAssertFalse(ClipboardRenderer.html(fragment).contains("base64"))
    }

    func testImagePlaceholdersFollowAttachmentOrder() {
        let fragment = Fragment(segments: [
            .init(text: "A "), .init(image: .init(path: "/a.png", alt: "")),
            .init(text: " B "), .init(image: .init(path: "/b.png", alt: "chart")),
            .init(text: " again "), .init(image: .init(path: "/a.png", alt: "")),
            .init(text: " gone "), .init(image: .init(path: "/missing.png", alt: "m")),
        ])
        XCTAssertEqual(ClipboardRenderer.textWithImagePlaceholders(fragment, attached: ["/a.png", "/b.png"]),
                       "A [Image 1] B [Image 2: chart] again [Image 1] gone ![m](</missing.png>)")
    }

    func testAIMarkdownUsesAbsoluteAngleBracketPaths() {
        let fragment = Fragment(segments: [.init(text: "See "), .init(image: .init(path: "/abs/x.png", alt: "x"))])
        XCTAssertEqual(ClipboardRenderer.aiMarkdown(fragment), "See ![x](</abs/x.png>)")
    }
}

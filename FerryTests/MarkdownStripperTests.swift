import XCTest
@testable import Ferry

/// "Ignore Markdown Syntax When Copying": markup goes, words (and code) stay.
final class MarkdownStripperTests: XCTestCase {
    private func strip(_ markdown: String) -> String { MarkdownStripper.strip(markdown) }

    func testHeadingsAndRules() {
        XCTAssertEqual(strip("# Title #\n\nSetext\n===\n\nTwo\n---\nText"), "Title\n\nSetext\n\nTwo\nText")
        XCTAssertEqual(strip("a\n\n---\n\nb\n* * *\n"), "a\n\n\nb\n")
    }

    func testQuotesListsAndTasks() {
        XCTAssertEqual(strip("> quoted **bold**\n- item\n  * nested\n- [ ] todo\n- [x] done\n1. first\n2) second\n3. [ ] numbered task"),
                       "quoted bold\nitem\n  nested\ntodo\ndone\n1. first\n2) second\n3. numbered task")
    }

    func testTableCellsBecomeTabSeparated() {
        XCTAssertEqual(strip("| Name | Qty |\n|:--|--:|\n| **Apple** | 3 |\n| a \\| b | 4 |\n\nafter | not a table"),
                       "Name\tQty\nApple\t3\na | b\t4\n\nafter | not a table")
    }

    func testEmphasisStrikethroughAndNesting() {
        XCTAssertEqual(strip("**bold** *it* _it2_ __b2__ ~~gone~~ ***both*** **bold *nested***"),
                       "bold it it2 b2 gone both bold nested")
        XCTAssertEqual(strip("snake_case_name, snake__double__name and 2*3*4"), "snake_case_name, snake__double__name and 2*3*4")
    }

    func testCodeIsKeptExactly() {
        XCTAssertEqual(strip("Use `**not bold**` and `a\\_b`\n```swift\nlet x = **y** // # not a heading\n```\nAfter **b**"),
                       "Use **not bold** and a\\_b\nlet x = **y** // # not a heading\nAfter b")
        XCTAssertEqual(strip("```\n# kept\n**kept**"), "# kept\n**kept**", "an unclosed fence runs to the end")
    }

    func testLinksImagesAutolinksAndEscapes() {
        XCTAssertEqual(strip("[site](https://x.com/a_b_c) ![alt](missing.png) <https://ex.com> \\*literal\\*"),
                       "site alt https://ex.com *literal*")
    }

    func testPrivateUseCharactersInTheTextAreLeftAlone() {
        XCTAssertEqual(strip("odd \u{E010}7\u{E011} and `code`"), "odd \u{E010}7\u{E011} and code")
    }

    func testChineseText() {
        XCTAssertEqual(strip("## 你好 **世界**\n- 列表 *斜体* 和 `代码`"), "你好 世界\n列表 斜体 和 代码")
    }

    func testFragmentKeepsImagesInPlace() {
        let image = Fragment.Image(path: "/tmp/a.png", alt: "a")
        let fragment = Fragment(segments: [.init(text: "- see "), .init(image: image), .init(text: " **here**\n# Title")])
        XCTAssertEqual(fragment.strippingMarkdown().segments, [.init(text: "see "), .init(image: image), .init(text: " here\nTitle")])
    }

    func testOnePastePayloadText() throws {
        let dir = try makeTempDirectory(self)
        let url = try writePNG(at: dir.appendingPathComponent("a.png"))
        let image = Fragment.Image(path: url.path, alt: "")
        let fragment = Fragment(segments: [.init(text: "# Plan **now**\n"), .init(image: image)])
        XCTAssertEqual(OnePastePayload(fragment: fragment, stripMarkdown: true)?.text, "Plan now\n[Image 1]")
        XCTAssertEqual(OnePastePayload(fragment: fragment)?.text, "# Plan **now**\n[Image 1]")
        XCTAssertNil(OnePastePayload(fragment: Fragment(segments: [.init(text: "# "), .init(image: image)]), stripMarkdown: true),
                     "nothing but syntax: an images-only copy")
    }
}

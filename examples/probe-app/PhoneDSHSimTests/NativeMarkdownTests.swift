// SPDX-License-Identifier: MIT

import XCTest

final class NativeMarkdownTests: XCTestCase {
    func testGfmBlocksAndInlineStructure() {
        let blocks = NativeMarkdownParser.parse("""
        # 标题

        正文 **加粗** *斜体* ~~删除~~ `code` [链接](https://example.com)。

        - [x] 已完成
        - [ ] 待办
          1. 嵌套

        > 引用

        | 左 | 右 |
        |:--|--:|
        | A | B |

        ---
        """)

        XCTAssertTrue(blocks.contains { if case .heading(level: 1, _) = $0 { true } else { false } })
        XCTAssertTrue(blocks.contains { if case .list(_, _, let items) = $0 { items[0].checked == true && items[1].checked == false } else { false } })
        XCTAssertTrue(blocks.contains { if case .blockquote = $0 { true } else { false } })
        XCTAssertTrue(blocks.contains { if case .table(_, _, let alignments) = $0 { alignments.count == 2 } else { false } })
        XCTAssertTrue(blocks.contains { if case .thematicBreak = $0 { true } else { false } })
    }

    func testSettledMathAndFootnotesRenderButStreamingMathStaysLiteral() {
        let source = "行内 $x^2$。\n\n$$\ny=mx+b\n$$\n\n引用[^a]\n\n[^a]: 脚注正文"
        let settled = NativeMarkdownParser.parse(source)
        let streaming = NativeMarkdownParser.parse(source, streaming: true)

        XCTAssertTrue(settled.contains { if case .math = $0 { true } else { false } })
        XCTAssertTrue(settled.contains { block in
            guard case .paragraph(let inline) = block else { return false }
            return inline.contains { if case .math = $0 { true } else { false } }
        })
        XCTAssertTrue(settled.contains { block in
            guard case .paragraph(let inline) = block else { return false }
            return inline.contains { if case .footnote = $0 { true } else { false } }
        })
        XCTAssertFalse(streaming.contains { if case .math = $0 { true } else { false } })
    }

    func testRawHTMLAndUnsafeLinkStayInertText() {
        let blocks = NativeMarkdownParser.parse("<b>不执行</b> [危险](javascript:alert(1))")
        guard case .paragraph(let inline) = blocks[0] else {
            return XCTFail("Expected paragraph")
        }
        XCTAssertTrue(inline.contains { if case .html = $0 { true } else { false } })
        XCTAssertTrue(inline.contains { if case .link(let destination, _) = $0 { destination.hasPrefix("javascript:") } else { false } })
    }

    func testDiffKeepsContextAndBothChangeKinds() {
        let lines = nativeDiffLines(old: "one\ntwo", new: "one\nthree")
        XCTAssertEqual(lines.map(\.kind), [.context, .deleted, .added])
    }
}

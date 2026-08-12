import XCTest
@testable import FantaLogcat

final class LogSearchBuilderTests: XCTestCase {
    func testAddingDraftBuildsQueryWithSelectedOperator() {
        var builder = LogSearchBuilder()
        builder.draft = " Unity "
        builder.addDraft()
        builder.nextOperator = .and
        builder.draft = "Exception"
        builder.addDraft()

        XCTAssertEqual(builder.query, "Unity AND Exception")
        XCTAssertEqual(builder.draft, "")
    }

    func testAddingKeywordTrimsValuesAndPreservesDuplicates() {
        var builder = LogSearchBuilder()

        builder.addKeyword(" Unity ")
        builder.addKeyword("Unity")
        builder.addKeyword("  \n ")

        XCTAssertEqual(builder.keywords.map(\.value), ["Unity", "Unity"])
        XCTAssertEqual(builder.query, "Unity OR Unity")
    }

    func testRemovingFirstKeywordNormalizesNewFirstRelation() {
        let first = SelectedKeyword(value: "Unity", relation: nil)
        let second = SelectedKeyword(value: "Exception", relation: .and)
        var builder = LogSearchBuilder(keywords: [first, second])

        builder.remove(id: first.id)

        XCTAssertEqual(builder.keywords, [SelectedKeyword(id: second.id, value: "Exception", relation: nil)])
        XCTAssertEqual(builder.query, "Exception")
    }

    func testClearRemovesDraftKeywordsAndRestoresDefaultOperator() {
        var builder = LogSearchBuilder(
            draft: "pending",
            keywords: [.init(value: "Unity", relation: nil)],
            nextOperator: .and
        )

        builder.clear()

        XCTAssertEqual(builder, LogSearchBuilder())
    }
}

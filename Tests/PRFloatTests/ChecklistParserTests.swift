import XCTest
@testable import PRFloatCore

final class ChecklistParserTests: XCTestCase {
    func testEmptyBody() {
        let r = ChecklistParser.parse(nil)
        XCTAssertEqual(r.done, 0)
        XCTAssertEqual(r.total, 0)

        let r2 = ChecklistParser.parse("")
        XCTAssertEqual(r2.done, 0)
        XCTAssertEqual(r2.total, 0)
    }

    func testMixedChecked() {
        let body = """
        ## Checklist
        - [x] Tests
        - [ ] Docs
        - [X] Lint
        * [ ] Changelog
        """
        let r = ChecklistParser.parse(body)
        XCTAssertEqual(r.total, 4)
        XCTAssertEqual(r.done, 2)
    }

    func testIndentedTasks() {
        let body = """
          - [ ] nested style
            - [x] deeper
        """
        let r = ChecklistParser.parse(body)
        XCTAssertEqual(r.total, 2)
        XCTAssertEqual(r.done, 1)
    }

    func testNoTasks() {
        let body = """
        Just a description.

        - regular bullet
        * another bullet
        """
        let r = ChecklistParser.parse(body)
        XCTAssertEqual(r.total, 0)
        XCTAssertEqual(r.done, 0)
    }

    func testOrderedListTasks() {
        let body = """
        1. [x] First
        2. [ ] Second
        """
        let r = ChecklistParser.parse(body)
        XCTAssertEqual(r.total, 2)
        XCTAssertEqual(r.done, 1)
    }
}

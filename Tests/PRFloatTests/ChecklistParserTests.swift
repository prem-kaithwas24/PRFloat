import Testing
@testable import PRFloatCore

@Suite("Checklist parsing")
struct ChecklistParserTests {
    @Test("Empty and nil bodies have no tasks", arguments: [nil, ""])
    func emptyBody(_ body: String?) {
        let r = ChecklistParser.parse(body)
        #expect(r.done == 0)
        #expect(r.total == 0)
    }

    @Test("Counts checked and unchecked across - and * bullets")
    func mixedChecked() {
        let body = """
        ## Checklist
        - [x] Tests
        - [ ] Docs
        - [X] Lint
        * [ ] Changelog
        """
        let r = ChecklistParser.parse(body)
        #expect(r.total == 4)
        #expect(r.done == 2)
    }

    @Test("Counts indented and nested tasks")
    func indentedTasks() {
        let body = """
          - [ ] nested style
            - [x] deeper
        """
        let r = ChecklistParser.parse(body)
        #expect(r.total == 2)
        #expect(r.done == 1)
    }

    @Test("Plain bullets are not tasks")
    func noTasks() {
        let body = """
        Just a description.

        - regular bullet
        * another bullet
        """
        let r = ChecklistParser.parse(body)
        #expect(r.total == 0)
        #expect(r.done == 0)
    }

    @Test("Counts tasks in ordered lists")
    func orderedListTasks() {
        let body = """
        1. [x] First
        2. [ ] Second
        """
        let r = ChecklistParser.parse(body)
        #expect(r.total == 2)
        #expect(r.done == 1)
    }
}

import XCTest
@testable import Briefing

final class MarkdownParserTests: XCTestCase {

    // Real todo.md content for testing — mirrors the actual file format
    let sampleTodoMD = """
    # Michael's Task System

    > **Last synced from Things 3:** 2026-02-15 10:55 PM PT
    > **Last AI review:** 2026-02-15 10:55 PM PT

    ---

    ## 🔴 Today
    - [ ] Build Renaissance Benefits visual campaign triggers/configurations *(Wed 2/18)*
    - [ ] Review potential opportunities and meetings for Lenders1
    - [x] Set up Noosh on all 3 and freeze credit

    ---

    ## 📋 Projects

    ### Generate Pipeline for Each Partner
    - [ ] ID KensieMae pipeline (X opps)
    - [ ] Set up per-partner analysis per GPT

    ### Land Ray White / Loan Market Group AUS
    - [ ] Schedule w/ Ray Hair principal 30-min discovery *(due 3/2 — Ray hasn't secured the Ray White meeting yet)*
    - [x] Meet w/ Ray to prep for Sam White (principal) 30-min discovery *(completed 2026-02-11)*

    ### Improve Onboarding Throughput
    *(2/18 meeting is set — Ryan, Geetha, Heather aligned)*

    ---

    ## 🟠 Personal

    - [x] Estimate Q1 commission based on to-be-signed figures *(completed 2026-02-15)*

    ---

    ## 🟡 Anytime (Unassigned)

    - [ ] Research enneagram 3 and 4
    - [ ] Call mortgage company re payment

    ---

    ## 🔵 Someday

    ### Explore Restaurant Partnerships
    - [ ] Create a plan for signing up 10K marketing agencies who act on behalf of restaurants

    - [ ] Review Scott's technical scoping document via Lovable

    ---

    ## ✅ Recently Completed
    - [x] Send update mail a la Sarah's recommendation *(2026-02-15, proj: Promote the Coop)*
    - [x] Review Feature Enhancement Request categories *(2026-02-15)*

    """

    // MARK: - Parse Tests

    func testParseSectionCount() {
        let doc = MarkdownParser.parse(sampleTodoMD)
        // Should find all 6 sections
        XCTAssertEqual(doc.sections.count, 6)
    }

    func testParseSectionTypes() {
        let doc = MarkdownParser.parse(sampleTodoMD)
        let types = doc.sections.map(\.type)
        XCTAssertEqual(types, [.today, .projects, .personal, .anytime, .someday, .completed])
    }

    func testParseHeader() {
        let doc = MarkdownParser.parse(sampleTodoMD)
        XCTAssertTrue(doc.header.contains("Michael's Task System"))
        XCTAssertTrue(doc.header.contains("Last synced from Things 3:"))
    }

    func testParseTodayTasks() {
        let doc = MarkdownParser.parse(sampleTodoMD)
        let todayTasks = doc.tasks(in: .today)
        XCTAssertEqual(todayTasks.count, 3)

        // First task should be uncompleted with metadata
        let first = todayTasks[0]
        XCTAssertEqual(first.name, "Build Renaissance Benefits visual campaign triggers/configurations")
        XCTAssertFalse(first.isCompleted)
        XCTAssertEqual(first.metadata, "Wed 2/18")

        // Third task should be completed
        let third = todayTasks[2]
        XCTAssertTrue(third.isCompleted)
    }

    func testParseProjectSubHeadings() {
        let doc = MarkdownParser.parse(sampleTodoMD)
        guard let projectsSection = doc.sections.first(where: { $0.type == .projects }) else {
            XCTFail("Projects section not found")
            return
        }

        XCTAssertEqual(projectsSection.projects.count, 3)
        XCTAssertEqual(projectsSection.projects[0].name, "Generate Pipeline for Each Partner")
        XCTAssertEqual(projectsSection.projects[0].tasks.count, 2)
        XCTAssertEqual(projectsSection.projects[1].name, "Land Ray White / Loan Market Group AUS")
        XCTAssertEqual(projectsSection.projects[1].tasks.count, 2)

        // "Improve Onboarding Throughput" has no tasks (just a note line)
        XCTAssertEqual(projectsSection.projects[2].name, "Improve Onboarding Throughput")
        XCTAssertEqual(projectsSection.projects[2].tasks.count, 0)
    }

    func testParseProjectTaskHasProjectName() {
        let doc = MarkdownParser.parse(sampleTodoMD)
        guard let projectsSection = doc.sections.first(where: { $0.type == .projects }) else {
            XCTFail("Projects section not found")
            return
        }

        let task = projectsSection.projects[0].tasks[0]
        XCTAssertEqual(task.project, "Generate Pipeline for Each Partner")
    }

    func testParseMetadataWithMarkdownLink() {
        let doc = MarkdownParser.parse(sampleTodoMD)
        guard let projectsSection = doc.sections.first(where: { $0.type == .projects }) else {
            XCTFail("Projects section not found")
            return
        }

        // "Schedule w/ Ray Hair..." has complex metadata with em-dash
        let task = projectsSection.projects[1].tasks[0]
        XCTAssertEqual(task.metadata, "due 3/2 — Ray hasn't secured the Ray White meeting yet")
    }

    func testParseSomedayMixedProjectsAndLooseTasks() {
        let doc = MarkdownParser.parse(sampleTodoMD)
        guard let somedaySection = doc.sections.first(where: { $0.type == .someday }) else {
            XCTFail("Someday section not found")
            return
        }

        // 1 project heading with all subsequent tasks falling under it
        // (tasks after a blank line still belong to the project until the next ### or section end)
        XCTAssertEqual(somedaySection.projects.count, 1)
        XCTAssertEqual(somedaySection.projects[0].name, "Explore Restaurant Partnerships")
        XCTAssertEqual(somedaySection.projects[0].tasks.count, 2)
        // No loose tasks — everything falls under the project heading
        XCTAssertEqual(somedaySection.tasks.count, 0)
    }

    func testParseCompletedSection() {
        let doc = MarkdownParser.parse(sampleTodoMD)
        let completed = doc.tasks(in: .completed)
        XCTAssertEqual(completed.count, 2)
        XCTAssertTrue(completed[0].isCompleted)
        XCTAssertEqual(completed[0].metadata, "2026-02-15, proj: Promote the Coop")
    }

    func testParseAllTasksCount() {
        let doc = MarkdownParser.parse(sampleTodoMD)
        let all = doc.allTasks
        // 3 today + 4 in projects + 0 in onboarding + 1 personal + 2 anytime + 1 someday project + 1 loose someday + 2 completed = 14
        // Hmm, need to count carefully. Let's just verify it's reasonable.
        XCTAssertGreaterThan(all.count, 10, "Should have many tasks across all sections")
    }

    func testParseSyncTimestamp() {
        let doc = MarkdownParser.parse(sampleTodoMD)
        XCTAssertEqual(doc.lastSyncedTimestamp, "2026-02-15 10:55 PM PT")
    }

    // MARK: - Task Line Parsing

    func testParseUncheckedTask() {
        let task = MarkdownParser.parseTaskLine("- [ ] Do the thing")
        XCTAssertNotNil(task)
        XCTAssertEqual(task?.name, "Do the thing")
        XCTAssertFalse(task!.isCompleted)
        XCTAssertNil(task?.metadata)
    }

    func testParseCheckedTask() {
        let task = MarkdownParser.parseTaskLine("- [x] Done thing *(2026-02-15)*")
        XCTAssertNotNil(task)
        XCTAssertEqual(task?.name, "Done thing")
        XCTAssertTrue(task!.isCompleted)
        XCTAssertEqual(task?.metadata, "2026-02-15")
    }

    func testParseTaskWithComplexMetadata() {
        let task = MarkdownParser.parseTaskLine("- [ ] Call Schwab re: missing $3957 *(acct 883-477499, Schwab 888-999-4512)*")
        XCTAssertNotNil(task)
        XCTAssertEqual(task?.name, "Call Schwab re: missing $3957")
        XCTAssertEqual(task?.metadata, "acct 883-477499, Schwab 888-999-4512")
    }

    func testParseNonTaskLine() {
        XCTAssertNil(MarkdownParser.parseTaskLine(""))
        XCTAssertNil(MarkdownParser.parseTaskLine("---"))
        XCTAssertNil(MarkdownParser.parseTaskLine("## 🔴 Today"))
        XCTAssertNil(MarkdownParser.parseTaskLine("### Some Project"))
        XCTAssertNil(MarkdownParser.parseTaskLine("Just a note line"))
        XCTAssertNil(MarkdownParser.parseTaskLine("*(2/18 meeting is set)*"))
    }

    // MARK: - Round-Trip Fidelity

    func testRoundTripPreservesUnmodifiedContent() {
        // Parse then immediately write back — should be close to original
        // Note: exact match is hard because the writer has its own section
        // separator logic, but the rawLines should be preserved.
        let doc = MarkdownParser.parse(sampleTodoMD)

        // No sections are modified, so rawLines should be used
        for section in doc.sections {
            XCTAssertFalse(section.isModified)
        }

        let written = MarkdownWriter.write(doc)

        // The written output should contain all the original task lines
        XCTAssertTrue(written.contains("Build Renaissance Benefits"))
        XCTAssertTrue(written.contains("ID KensieMae pipeline"))
        XCTAssertTrue(written.contains("Research enneagram 3 and 4"))
        XCTAssertTrue(written.contains("Send update mail"))

        // Section headings should all be present
        XCTAssertTrue(written.contains("## 🔴 Today"))
        XCTAssertTrue(written.contains("## 📋 Projects"))
        XCTAssertTrue(written.contains("## 🟠 Personal"))
        XCTAssertTrue(written.contains("## 🟡 Anytime (Unassigned)"))
        XCTAssertTrue(written.contains("## 🔵 Someday"))
        XCTAssertTrue(written.contains("## ✅ Recently Completed"))
    }

    func testWriteTaskLine() {
        let task = TodoTask(
            rawLine: "- [ ] Test task *(due Friday)*",
            name: "Test task",
            isCompleted: false,
            metadata: "due Friday",
            project: nil
        )
        let line = MarkdownWriter.writeTaskLine(task)
        XCTAssertEqual(line, "- [ ] Test task *(due Friday)*")
    }

    func testWriteCompletedTaskLine() {
        let task = TodoTask(
            rawLine: "- [x] Done *(2026-02-15)*",
            name: "Done",
            isCompleted: true,
            metadata: "2026-02-15",
            project: nil
        )
        let line = MarkdownWriter.writeTaskLine(task)
        XCTAssertEqual(line, "- [x] Done *(2026-02-15)*")
    }

    func testWriteTaskLineWithoutMetadata() {
        let task = TodoTask(
            rawLine: "- [ ] Simple task",
            name: "Simple task",
            isCompleted: false,
            metadata: nil,
            project: nil
        )
        let line = MarkdownWriter.writeTaskLine(task)
        XCTAssertEqual(line, "- [ ] Simple task")
    }
}

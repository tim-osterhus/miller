import Foundation
import MillerCore
import Testing
@testable import MillerApp

@Suite
struct CapabilityActivityPresentationTests {
    @Test
    func stateStartsCollapsedAndCollapsesOnlyWhenInactivityElapses() {
        var state = CapabilityActivityPresentationState()

        #expect(!state.isExpanded)
        state.receivedNewActivity()
        #expect(state.isExpanded)
        state.inactivityElapsed()
        #expect(!state.isExpanded)
    }

    @Test
    func stateToggleRemainsAvailableAfterAutomaticCollapse() {
        var state = CapabilityActivityPresentationState()

        state.receivedNewActivity()
        state.inactivityElapsed()
        state.toggle()
        #expect(state.isExpanded)
        state.toggle()
        #expect(!state.isExpanded)
    }

    @Test
    @MainActor
    func retainedRowsExposeOnlyTheNewestEightWithoutChangingRowData() {
        let rows = (0..<10).map { index in
            CapabilityActivityRow(
                callID: CapabilityCallID(),
                origin: "Origin \(index)",
                server: "Server \(index)",
                tool: "Tool \(index)",
                outcome: .succeeded
            )
        }

        let view = CapabilityActivityView(rows: rows)

        #expect(Array(view.retainedRows) == Array(rows.suffix(8)))
    }

    @Test
    func activityStateDeclaresApprovedBoundsAndTransitions() throws {
        let source = try presentationSource()

        #expect(source.contains("struct CapabilityActivityPresentationState"))
        #expect(source.contains("static let retainedRowLimit = 8"))
        #expect(source.contains("static let visibleRowLimit = 3"))
        #expect(source.contains("static let autoCollapseDelay = Duration.seconds(15)"))
        #expect(source.contains("private(set) var isExpanded = false"))
        #expect(source.contains("mutating func receivedNewActivity()"))
        #expect(source.contains("mutating func toggle()"))
        #expect(source.contains("mutating func inactivityElapsed()"))
        #expect(source.contains(#"return "\(count) recent action\(count == 1 ? "" : "s")""#))
    }

    @Test
    @MainActor
    func activityKeepsNewestRowsAndDoesNotRenderAnEmptyPanel() throws {
        let source = try presentationSource()
        let emptyView = CapabilityActivityView(rows: [])

        #expect(emptyView.retainedRows.isEmpty)
        #expect(emptyView.maximumExpandedHeight == 96)
        #expect(source.contains("if retainedRows.isEmpty"))
        #expect(!source.contains("if rows.isEmpty"))
        #expect(source.contains("rows.suffix(CapabilityActivityPresentationState.retainedRowLimit)"))
        #expect(source.contains("ForEach(retainedRows)"))
        #expect(source.contains(".lineLimit(2)"))
        #expect(source.contains("var maximumExpandedHeight: CGFloat"))
        #expect(source.contains(
            "CGFloat(CapabilityActivityPresentationState.visibleRowLimit * 32)"
        ))
        #expect(source.contains(".frame(maxHeight: maximumExpandedHeight)"))
    }

    @Test
    func activityUsesAnIndependentBoundedTaskAndDisclosureControl() throws {
        let source = try presentationSource()
        let task = sourceBlock(
            startingWith: ".task(id: rows.last?.id)",
            in: source
        )

        #expect(!task.isEmpty)
        #expect(task.contains("presentationState.receivedNewActivity()"))
        #expect(task.contains(
            "Task.sleep(for: CapabilityActivityPresentationState.autoCollapseDelay)"
        ))
        #expect(task.contains("catch is CancellationError {\n                    return"))
        #expect(source.contains("ScrollView(.vertical)"))
        #expect(source.contains(".frame(maxHeight:"))
        #expect(source.contains("Show capability activity"))
        #expect(source.contains("Hide capability activity"))

        let receivedActivity = task.range(
            of: "presentationState.receivedNewActivity()"
        )
        let sleep = task.range(
            of: "Task.sleep(for: CapabilityActivityPresentationState.autoCollapseDelay)"
        )
        let cancellationCatch = task.range(of: "catch is CancellationError")
        let firstCancellationGuard = task.range(
            of: "guard !Task.isCancelled else { return }"
        )
        let finalCancellationGuard = task.range(
            of: "guard !Task.isCancelled else { return }",
            options: .backwards
        )
        let inactivity = task.range(
            of: "presentationState.inactivityElapsed()"
        )

        #expect(receivedActivity != nil)
        #expect(sleep != nil)
        #expect(cancellationCatch != nil)
        #expect(firstCancellationGuard != nil)
        #expect(finalCancellationGuard != nil)
        #expect(inactivity != nil)
        if let receivedActivity, let sleep, let cancellationCatch,
           let firstCancellationGuard, let finalCancellationGuard, let inactivity {
            #expect(firstCancellationGuard.lowerBound < receivedActivity.lowerBound)
            #expect(receivedActivity.lowerBound < sleep.lowerBound)
            #expect(sleep.lowerBound < cancellationCatch.lowerBound)
            #expect(cancellationCatch.lowerBound < finalCancellationGuard.lowerBound)
            #expect(finalCancellationGuard.lowerBound < inactivity.lowerBound)
        }

        for forbiddenToken in [
            "UserDefaults",
            "AppStorage",
            "SQLite",
            "CapabilityController",
            "CapabilityBroker",
            "Provider",
            "Timer",
            "NSPasteboard",
            "SelectableTranscriptSurface",
        ] {
            #expect(!source.contains(forbiddenToken))
        }
    }

    private func presentationSource() throws -> String {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repository = tests.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: repository
                .appendingPathComponent("Sources/MillerApp/Presentation")
                .appendingPathComponent("CapabilityActivityView.swift"),
            encoding: .utf8
        )
    }

    private func sourceBlock(startingWith marker: String, in source: String) -> String {
        guard
            let markerRange = source.range(of: marker),
            let openingBrace = source[markerRange.upperBound...].firstIndex(of: "{")
        else {
            return ""
        }

        var depth = 0
        var index = openingBrace
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}": depth -= 1
            default: break
            }
            if depth == 0 {
                return String(source[openingBrace...index])
            }
            index = source.index(after: index)
        }
        return ""
    }
}

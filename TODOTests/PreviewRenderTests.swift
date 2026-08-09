import Testing
import Foundation
import SwiftUI
import SwiftData
@testable import TODO

/// Renders each previewed view so a crash shows up here rather than as a blank
/// canvas in Xcode.
///
/// `#Preview` bodies cannot be called directly, so these rebuild the same view
/// with the same fixture and force a layout pass with `ImageRenderer`. That
/// exercises `body`, which is where a bad fixture lookup or a missing
/// environment value actually fails.
@MainActor
struct PreviewRenderTests {

    /// Force SwiftUI to evaluate `body` and lay the view out.
    private func render(_ view: some View) {
        let renderer = ImageRenderer(
            content: view
                .frame(width: 390, height: 700)
                .modelContainer(PreviewData.container)
                .environment(AppSettings.shared)
        )
        #if os(macOS)
        #expect(renderer.nsImage != nil)
        #else
        #expect(renderer.uiImage != nil)
        #endif
    }

    // MARK: Rows

    @Test func todoRowRenders() {
        render(TodoRowRenderHost(todo: PreviewData.todo(titled: "Review")))
    }

    @Test func todoRowRendersEveryState() {
        for state in CompletionState.allCases {
            let todo = Todo(title: "\(state.label) item")
            PreviewData.context.insert(todo)
            todo.setState(state)
            render(TodoRowRenderHost(todo: todo))
        }
    }

    @Test func todoRowRendersLongTitle() {
        render(TodoRowRenderHost(todo: PreviewData.longTitled))
    }

    @Test func pendingReminderRowRenders() {
        render(
            PendingReminderRow(reminder: PreviewData.pendingReminders[0]) {}
        )
    }

    // MARK: Screens

    @Test func todoListRendersEveryDestination() {
        let destinations: [ListDestination] = [
            .inbox, .today, .thisWeek, .anytime, .logbook,
            .project(PreviewData.project.uuid),
            .space(PreviewData.space.uuid),
        ]

        for destination in destinations {
            render(TodoListRenderHost(destination: destination))
        }
    }

    @Test func sidebarRenders() {
        render(SidebarRenderHost())
    }

    @Test func detailRendersForTodoAndProject() {
        render(NavigationStack { TodoDetailView(todo: PreviewData.todo(titled: "Review")) })
        // Projects add the colour picker section.
        render(NavigationStack { TodoDetailView(todo: PreviewData.project) })
    }

    @Test func calendarRenders() {
        render(CalendarRenderHost())
    }

    @Test func sidePanelRenders() {
        render(SidePanelRenderHost())
    }

    @Test func spaceEditorRenders() {
        render(NavigationStack { SpaceEditorView(space: PreviewData.space) })
    }

    @Test func settingsRenders() {
        render(NavigationStack { SettingsView() })
    }

    @Test func rootRenders() {
        render(RootView())
    }

    // MARK: Components

    @Test func checkboxRendersEveryState() {
        for state in CompletionState.allCases {
            render(TodoCheckbox(state: state, tint: .blue, onToggle: {}, onSelect: { _ in }))
        }
    }

    @Test func suggestionBarRenders() {
        let suggestions = TitleParser().suggestions(for: "Clean car tomorrow 30m")
        #expect(!suggestions.isEmpty)
        render(SuggestionBar(suggestions: suggestions) { _ in })
    }

    @Test func colorPickerRenders() {
        render(ColorPickerRenderHost())
    }

    @Test func markdownTextRenders() {
        render(InlineMarkdownText(markdown: "Call **Dana** about the *invoice*"))
        render(BlockMarkdownText(markdown: "# Heading\n\n- one\n- two\n\n`code`"))
    }
}

// MARK: - Hosts for views needing bindings

@MainActor
private struct TodoRowRenderHost: View {
    let todo: Todo
    @FocusState private var focused: UUID?

    var body: some View {
        TodoRow(
            todo: todo,
            showsSpace: true,
            onToggle: {},
            onSelectState: { _ in },
            focusedTodoID: $focused
        )
    }
}

@MainActor
private struct TodoListRenderHost: View {
    let destination: ListDestination
    @State private var selected: Todo?

    var body: some View {
        NavigationStack {
            TodoListView(destination: destination, selectedTodo: $selected)
        }
    }
}

@MainActor
private struct SidebarRenderHost: View {
    @State private var selection: ListDestination? = .today
    @State private var selectedTodo: Todo?

    var body: some View {
        NavigationStack {
            SidebarView(selection: $selection, selectedTodo: $selectedTodo)
        }
    }
}

@MainActor
private struct CalendarRenderHost: View {
    @State private var selected: Todo?

    var body: some View {
        NavigationStack { CalendarView(selectedTodo: $selected) }
    }
}

@MainActor
private struct SidePanelRenderHost: View {
    @State private var selected: Todo?

    var body: some View {
        SidePanelView(selectedTodo: $selected)
    }
}

@MainActor
private struct ColorPickerRenderHost: View {
    @State private var color: String? = Theme.Palette.spaceColors.first

    var body: some View {
        ColorSwatchPicker(selection: $color, allowsNoColor: true)
    }
}

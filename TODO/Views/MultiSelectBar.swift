import SwiftUI

/// The action bar that appears once rows are selected.
///
/// Everything the row's own context menu offers, applied to the whole
/// selection. The split between the buttons on the bar and the items behind
/// the ellipsis is by *frequency*, not by importance: complete, schedule,
/// move and delete are what a batch is usually gathered up for, and putting
/// the rest one press deeper keeps the bar readable on a phone.
///
/// Deliberately a dumb view over a list of closures. It has no access to the
/// store and does not know what a `Todo` is — the list owns the selection and
/// the actions, and passes down only what to draw. That is what lets the bar
/// be previewed, and keeps the "what does this button do" decisions in one
/// place next to the single-row menu they mirror.
struct MultiSelectBar: View {
    /// How many rows the actions will apply to.
    let count: Int
    /// Whether the selection is entirely resolved, which flips the check
    /// button between completing and reopening.
    let allResolved: Bool
    /// Whether every selected row is already a project, likewise.
    let allProjects: Bool
    /// The spaces offered by "Move to Space".
    let spaces: [Space]

    var onToggleAll: () -> Void
    var onSetState: (CompletionState) -> Void
    var onSchedule: () -> Void
    var onMove: () -> Void
    var onMoveToSpace: (Space?) -> Void
    var onDuplicate: () -> Void
    var onSetIsProject: (Bool) -> Void
    var onDelete: () -> Void
    var onSelectAll: () -> Void
    var onDone: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            countLabel

            Spacer(minLength: 8)

            HStack(spacing: barSpacing) {
                action(
                    allResolved ? "Reopen" : "Complete",
                    systemImage: allResolved ? "arrow.uturn.backward.circle" : "checkmark.circle",
                    action: onToggleAll
                )

                action("When", systemImage: "calendar", action: onSchedule)

                action("Move", systemImage: "folder", action: onMove)

                action(
                    "Delete",
                    systemImage: "trash",
                    role: .destructive,
                    action: onDelete
                )

                overflowMenu
            }

            Spacer(minLength: 8)

            doneButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: Theme.Metrics.panelCornerRadius)
        // Disabled rather than hidden while the count is zero: the bar is on
        // screen because iOS's Select mode is on, and a bar whose buttons
        // vanished as the last row was deselected would jump about as the user
        // built their selection up.
        .disabled(count == 0)
        .animation(Theme.Animation.quick, value: count == 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(count) selected")
    }

    /// Buttons are tighter on a phone, where five of them plus the count and
    /// Done have to fit across the narrowest screen the app runs on.
    #if os(macOS)
    private var barSpacing: CGFloat { 4 }
    #else
    private var barSpacing: CGFloat { 2 }
    #endif

    private var countLabel: some View {
        Text("\(count)")
            .font(.callout.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(count == 0 ? .secondary : .primary)
            // Fixed width so the bar's buttons do not shift sideways as the
            // count crosses from one digit to two.
            .frame(minWidth: 22, alignment: .leading)
            .contentTransition(.numericText())
            .animation(Theme.Animation.quick, value: count)
            .accessibilityHidden(true)
    }

    private var doneButton: some View {
        Button("Done", action: onDone)
            .font(.callout.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            // The row of glyph buttons will happily squeeze this to a couple of
            // characters wide and wrap it onto two lines; the word is the way
            // out of the mode and has to stay readable.
            .fixedSize()
            .layoutPriority(1)
            // Always live: it is the way out of the mode, including out of an
            // empty selection, so it is deliberately outside the disable above.
            .disabled(false)
            .accessibilityHint("Leave multiple selection")
    }

    /// The actions that did not earn a place on the bar itself.
    ///
    /// Same order as the row's context menu, so someone who knows where
    /// "Make Project" is for one to-do finds it in the same place for ten.
    private var overflowMenu: some View {
        Menu {
            ControlGroup {
                // Start and Cancel have no button of their own; the check
                // button covers only the open/completed pair.
                ForEach(CompletionState.allCases, id: \.self) { state in
                    Button {
                        onSetState(state)
                    } label: {
                        Label(state.label, systemImage: state.symbolName)
                    }
                }
            }
            .controlGroupStyle(.menu)

            Divider()

            Button {
                onDuplicate()
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square.dashed")
            }

            Button {
                onSetIsProject(!allProjects)
            } label: {
                Label(
                    allProjects ? "Demote to To-Dos" : "Make Projects",
                    systemImage: allProjects ? "arrow.down.square" : "arrow.up.square"
                )
            }

            Divider()

            Menu("Move to Space") {
                Button("None") { onMoveToSpace(nil) }
                ForEach(spaces) { space in
                    Button(space.name) { onMoveToSpace(space) }
                }
            }

            Divider()

            Button("Select All", systemImage: "checklist", action: onSelectAll)
        } label: {
            barLabel("More", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions")
    }

    private func action(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            barLabel(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : Color.accentColor)
        .accessibilityLabel(title)
    }

    /// Glyph over caption, the shape a bottom action bar has on both
    /// platforms. The title stays visible rather than becoming a tooltip: five
    /// unlabelled glyphs is a puzzle, and the bar is only on screen briefly.
    private func barLabel(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(.system(size: 16))
                .frame(height: 18)
            Text(title)
                .font(.caption2)
                // Shrink rather than wrap or truncate on the narrowest phones,
                // where five captions plus the count and Done are tight.
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 44)
        .contentShape(Rectangle())
    }
}

extension View {
    /// Float the multi-select bar above this view.
    ///
    /// An overlay rather than a `safeAreaInset`: the bar is transient, and an
    /// inset would resize the list — pushing every row up as the bar appeared
    /// and dropping them back as it left, which is a lot of movement in answer
    /// to a single click. The list already reserves clearance at its bottom
    /// for the floating create button, which is the space this sits in.
    @ViewBuilder
    func multiSelectBar(isPresented: Bool, @ViewBuilder bar: () -> MultiSelectBar) -> some View {
        overlay(alignment: .bottom) {
            if isPresented {
                bar()
                    .padding(.horizontal, Theme.Metrics.panelInset)
                    .padding(.bottom, Theme.Metrics.panelInset)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Theme.Animation.panel, value: isPresented)
    }
}

extension View {
    /// The panels the bar raises: scheduling, moving, and the delete warning.
    ///
    /// Gathered into one modifier because they are three presentations over
    /// one selection and belong together — and because attaching them inline
    /// pushed the list's `body`, already at the type-checker's limit, over it.
    ///
    /// The pickers are the same ones a single row uses. They take a `todo` only
    /// to title themselves, and what they report back is a date or a
    /// destination — which is a value, not something bound to one row — so
    /// nothing about them needed a bulk variant.
    func multiSelectPanels(
        isScheduling: Binding<Bool>,
        isMoving: Binding<Bool>,
        isConfirmingDelete: Binding<Bool>,
        deletePrompt: String,
        onPickDate: @escaping (Date?, Bool) -> Void,
        onPickWeek: @escaping (WeekSchedule) -> Void,
        onPickDestination: @escaping (MoveDestinationView.Destination) -> Void,
        onConfirmDelete: @escaping () -> Void
    ) -> some View {
        modifier(
            MultiSelectPanels(
                isScheduling: isScheduling,
                isMoving: isMoving,
                isConfirmingDelete: isConfirmingDelete,
                deletePrompt: deletePrompt,
                onPickDate: onPickDate,
                onPickWeek: onPickWeek,
                onPickDestination: onPickDestination,
                onConfirmDelete: onConfirmDelete
            )
        )
    }
}

private struct MultiSelectPanels: ViewModifier {
    @Binding var isScheduling: Bool
    @Binding var isMoving: Bool
    @Binding var isConfirmingDelete: Bool
    let deletePrompt: String
    let onPickDate: (Date?, Bool) -> Void
    let onPickWeek: (WeekSchedule) -> Void
    let onPickDestination: (MoveDestinationView.Destination) -> Void
    let onConfirmDelete: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isScheduling) {
                SchedulePickerView(
                    onPick: { date, hasTime in
                        onPickDate(date, hasTime)
                        isScheduling = false
                    },
                    onPickWeek: { week in
                        onPickWeek(week)
                        isScheduling = false
                    },
                    onDismiss: { isScheduling = false }
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isMoving) {
                MoveDestinationView(
                    onPick: { destination in
                        onPickDestination(destination)
                        isMoving = false
                    },
                    onDismiss: { isMoving = false }
                )
                .presentationDetents([.medium])
            }
            .confirmationDialog(
                deletePrompt,
                isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive, action: onConfirmDelete)
                Button("Cancel", role: .cancel) { isConfirmingDelete = false }
            }
    }
}

#if DEBUG
#Preview("Multi-select bar") {
    VStack {
        Spacer()
        MultiSelectBar(
            count: 4,
            allResolved: false,
            allProjects: false,
            spaces: [],
            onToggleAll: {},
            onSetState: { _ in },
            onSchedule: {},
            onMove: {},
            onMoveToSpace: { _ in },
            onDuplicate: {},
            onSetIsProject: { _ in },
            onDelete: {},
            onSelectAll: {},
            onDone: {}
        )
        .padding()
    }
    .frame(width: 500, height: 200)
    .background(Color.gray.opacity(0.2))
}
#endif

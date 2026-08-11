//
//  TodoRow_new.swift
//  TODO
//
//  Created by John Rizkalla on 8/10/26.
//

import SwiftUI

/*
 TodoRow(
     todo: todo,
     showsSpace: showsSpaceBadge,
     isSelected: selectedTodo?.uuid == todo.uuid,
     isCursor: cursor.selection == todo.uuid,
     onToggle: { handleToggle(todo) },
     onSelectState: { handleSetState(todo, to: $0) },
     onTitleChange: { handleTitleChange($0, for: todo) },
     onNotesChange: { store.save() },
     focusedTodoID: $focusedTodoID,
     menu: { AnyView(rowMenu(for: todo)) },
     onSubmitTitle: { createTodoAfterSubmit(from: todo) },
     onShowDetail: { showDetail(for: todo) },
     onSelect: { selectRow(todo) }
 )
 */

struct TodoRowV2 : View {
    var todo: Todo
    let showsSpace: Bool
    @Binding var selectedTodo: Todo?
    var onToggle: (Todo) -> Void
    var onSelectState: (CompletionState) -> Void
    var onTitleChange: (String) -> Void
    var onNotesChange: (Todo) -> Void
    var menu: () -> AnyView
    var onSubmitTitle: () -> Void
    var onShowDetail : (Todo) -> Void

    @State var todoTitle = ""
    @State var todoDescription = ""
    
    @FocusState var isTitleFocused: Bool
    @FocusState var isDescriptionFocused: Bool

    var isSelected: Bool {
        selectedTodo.map { $0.uuid == todo.uuid } ?? false
    }
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .top) {
                TodoCheckbox(
                    state: todo.state,
                    tint: todo.color,
                    onToggle: { onToggle(todo) },
                    onSelect: { _ in }
                ).padding([.top], isSelected ? 3 : 0) // TODO: Tune for macos?
                
                VStack(alignment: .leading) {
                    if isSelected {
                        TextField("TODO title", text: $todoTitle, axis: .vertical)
                            .focused($isTitleFocused)
                            .textFieldStyle(.plain)
                            .lineLimit(1...6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        statusLine
                        TextField("TODO description", text: $todoDescription, axis: .vertical)
                            .focused($isDescriptionFocused)
                            .textFieldStyle(.plain)
                            .lineLimit(1...6)
                    } else {
                        Text((try? AttributedString(markdown: todo.title)) ?? AttributedString(todo.title))
                            .lineLimit(1...6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        statusLine
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation {
                        selectedTodo = todo
                    }
                }

                if isSelected {
                    Image(systemName: "chevron.right")
                        .padding()
                        .foregroundStyle(todo.color)
                        .onTapGesture {
                            onShowDetail(todo)
                        }
                }
            }
        }
        .contextMenu {
            menu()
        }
        .padding(.init(top: 10, leading: 7, bottom: 10, trailing: 7))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
        .overlay(borderOverlay)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.1), radius: 20)
                    .shadow(color: todo.color.opacity(0.1), radius: 10)
            } else {
                EmptyView()
            }
        }
        .onAppear {
            todoTitle = todo.title
            todoDescription = todo.notes
        }.onChange(of: isSelected) { oldValue, newValue in
            guard oldValue && !newValue else { return }
            isTitleFocused = false
            isDescriptionFocused = false
        }.onChange(of: isTitleFocused) { oldValue, newValue in
            guard oldValue && newValue else { return }
            todo.title = todoTitle
            onTitleChange(todoTitle)
        }.onChange(of: isDescriptionFocused) { oldValue, newValue in
            guard oldValue && newValue else { return }
            todo.notes = todoDescription
            onNotesChange(todo)
        }
    }
    
    @ViewBuilder
    var borderOverlay: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius)
                .strokeBorder(todo.color)
        } else {
            EmptyView()
        }
    }
    
    private struct Badge: Identifiable {
        let id = UUID()
        let text: String
        let symbol: String
        let color: Color
    }

    /// Only the fields that are actually set produce a badge, keeping rows
    /// uncluttered.
    private var badges: [Badge] {
        var badges: [Badge] = []

        if let assigned = todo.assignedDate {
            badges.append(Badge(
                text: ParsedSuggestion.describe(assigned, hasTime: todo.assignedHasTime),
                symbol: "calendar",
                color: .secondary
            ))
        }

        if let due = todo.dueDate {
            badges.append(Badge(
                text: ParsedSuggestion.describe(due, hasTime: todo.dueHasTime),
                symbol: "target",
                color: todo.isOverdue ? Theme.Palette.overdue : .secondary
            ))
        }

        if let duration = todo.duration {
            badges.append(Badge(
                text: ParsedSuggestion.describe(duration: duration),
                symbol: "clock",
                color: .secondary
            ))
        }

        if !todo.reminderList.isEmpty {
            badges.append(Badge(
                text: "\(todo.reminderList.count)",
                symbol: "bell",
                color: .secondary
            ))
        }

        let subtasks = todo.subtaskList
        if !subtasks.isEmpty {
            let done = subtasks.filter { $0.state.isResolved }.count
            badges.append(Badge(
                text: "\(done)/\(subtasks.count)",
                symbol: "checklist",
                color: .secondary
            ))
        }

        if showsSpace, let space = todo.space {
            badges.append(Badge(text: space.name, symbol: space.symbolName, color: Color(hex: space.colorHex)))
        }

        return badges
    }
    
    @ViewBuilder
    var statusLine: some View {
        HStack {
            ForEach(badges) { badge in
                HStack {
                    Image(systemName: badge.symbol)
                        .foregroundStyle(badge.color.opacity(0.85))
                        .font(.footnote)
                    Text(badge.text)
                        .foregroundStyle(Color.secondary)
                        .font(.footnote)
                }
            }
        }
        .padding([.top], 1)
    }
}


#if DEBUG

struct TodoRowHost : View {
    
    var todos: [Todo]
    
    @State var selectedTodo: Todo?
    
    var body: some View {
        VStack(alignment: .leading) {
            ForEach(todos) { todo in
                TodoRowV2(
                    todo: todo,
                    showsSpace: true,
                    selectedTodo: $selectedTodo,
                    onToggle: { todo in
                        switch todo.state {
                        case .open, .cancelled, .started:
                            todo.state = .completed
                        case .completed:
                            todo.state = .open
                        }
                    },
                    onSelectState: { _ in
                        print("state changed")
                    },
                    onTitleChange: {
                        print("Title changed: \($0)")
                    }, onNotesChange: {
                        print("Notes changed: \($0.notes)")
                    }, menu: {
                        AnyView(EmptyView())
                    },
                    onSubmitTitle: {},
                    onShowDetail: {_ in }
                )
            }
            Spacer()
        }
        .padding([.top], 30)
        .padding([.leading, .trailing])
    }
}

#Preview {
    let focused = PreviewData.todo(titled: "Renew passport")
    TodoRowHost(
        todos: [
            PreviewData.todo(titled: "Review"),
            PreviewData.todo(titled: "Standup"),
            PreviewData.todo(titled: "Pay the"),
            focused,

            PreviewData.project,
            PreviewData.imported,
        ],
        selectedTodo: focused
    )
}

#endif

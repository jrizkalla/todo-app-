//
//  TodayView.swift
//  TODO
//
//  Created by John Rizkalla on 8/8/26.
//
import SwiftUI

enum TodayViewTab : CaseIterable {
    case summary, list, calendar
}

extension TodayViewTab: Identifiable {
    var id: Self { self }
}

extension TodayViewTab {
    var title: String {
        switch self {
        case .summary: "Summary"
        case .list: "List"
        case .calendar: "Calendar"
        }
    }
    
    var icon : String {
        switch self {
        case .summary: "sparkles"
        case .list: "list.bullet"
        case .calendar: "calendar"
        }
    }
}

struct TodayView: View {
    @State private var tab: TodayViewTab = .summary
    
    @Binding var selectedTodo: Todo?

    @ViewBuilder
    func view(for tab: TodayViewTab) -> some View {
        switch tab {
        case .summary:
            AISummaryView()
        case .list:
            VStack(alignment: .leading) {
                Text("Today")
                    .font(.largeTitle)
                    .padding()
                TodoListView(destination: .today, selectedTodo: $selectedTodo)
            }
        case .calendar:
            CalendarView(selectedTodo: $selectedTodo, destination: .today)
        }
    }
    
    var body: some View {
        
        TabView(selection: $tab) {
            ForEach(TodayViewTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.icon, value: tab) {
                    view(for: tab)
                }
            }
        }
    }
}


#if DEBUG
struct TodayViewHost : View {
    
    @State var selected: Todo?
    
    var body: some View {
        NavigationStack {
            TodayView(selectedTodo: $selected)
        }
    }
}

#Preview {
    TodayViewHost()
        .previewEnvironment()
}

#endif

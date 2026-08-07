import SwiftUI
import SwiftData
import CoreLocation
import MapKit

/// Reminder list and editor inside the todo detail view.
struct RemindersSection: View {
    let todo: Todo

    @Environment(\.modelContext) private var context
    @State private var isAddingLocation = false
    @State private var locationQuery = ""
    @State private var searchResults: [MKMapItem] = []

    private var store: TodoStore { TodoStore(context: context) }

    var body: some View {
        Section("Reminders") {
            ForEach(todo.reminderList) { reminder in
                HStack {
                    Image(systemName: reminder.kind == .dateTime ? "bell" : "mappin.and.ellipse")
                        .foregroundStyle(.secondary)
                    Text(reminder.summary)
                    Spacer()
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    let reminder = todo.reminderList[index]
                    NotificationScheduler.shared.cancel(reminder)
                    store.delete(reminder)
                }
            }

            Button {
                let date = Date().addingTimeInterval(3600)
                let reminder = store.addDateReminder(to: todo, at: date)
                Task {
                    await NotificationScheduler.shared.requestNotificationAuthorization()
                    await NotificationScheduler.shared.syncAll(reminders: [reminder])
                }
            } label: {
                Label("Add Time Reminder", systemImage: "bell.badge")
            }

            Button {
                isAddingLocation = true
                NotificationScheduler.shared.requestLocationAuthorization()
            } label: {
                Label("Add Location Reminder", systemImage: "mappin.circle")
            }
        }
        .sheet(isPresented: $isAddingLocation) {
            locationPicker
        }
    }

    /// Place search backed by MapKit, so a location reminder can be attached to
    /// a real address rather than raw coordinates.
    private var locationPicker: some View {
        NavigationStack {
            List {
                ForEach(searchResults, id: \.self) { item in
                    Button {
                        addLocationReminder(for: item)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name ?? "Place")
                            if let address = item.address?.fullAddress {
                                Text(address)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $locationQuery, prompt: "Search for a place")
            .onSubmit(of: .search) { runSearch() }
            .onChange(of: locationQuery) { _, newValue in
                if newValue.isEmpty { searchResults = [] }
            }
            .navigationTitle("Choose a Place")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isAddingLocation = false }
                }
            }
        }
    }

    private func runSearch() {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = locationQuery

        MKLocalSearch(request: request).start { response, _ in
            searchResults = response?.mapItems ?? []
        }
    }

    private func addLocationReminder(for item: MKMapItem) {
        let coordinate = item.location.coordinate
        let reminder = store.addLocationReminder(
            to: todo,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            placeName: item.name
        )
        isAddingLocation = false

        Task {
            await NotificationScheduler.shared.requestNotificationAuthorization()
            await NotificationScheduler.shared.syncAll(reminders: [reminder])
        }
    }
}

import Foundation

struct TripPlanningOptions: Equatable {
    var days = 7
    var startHour = 9
    var endHour = 20
    /// The complete block, including travel in both directions.
    var durationMinutes = 60
    var timezone = TimeZone.current.identifier

    func validate() throws {
        guard (1...14).contains(days), (0...23).contains(startHour),
              (1...24).contains(endHour), startHour < endHour,
              (15...240).contains(durationMinutes), TimeZone(identifier: timezone) != nil else {
            throw BrowserError("invalid_trip_options", "Choose 1–14 days, valid daily hours, and a duration of 15–240 minutes including travel.")
        }
    }
}

struct TripListItem: Decodable, Identifiable {
    let id: UUID
    let title: String
    let quantity: Double
    let unit: String?
    let note: String?
    let explanation: String?
    let neededBy: Date?
    let checked: Bool
}

struct TripList: Decodable, Identifiable {
    let id: UUID
    let householdId: UUID
    let name: String
    let merchant: InventoryMerchant?
    let status: String
    let source: String
    let neededBy: Date?
    let openCount: Int
    let items: [TripListItem]
    // Preserve the server's complete precision for the approval/version precondition.
    let updatedAt: String

    var storeName: String { merchant?.label ?? name }
    var openItems: [TripListItem] { items.filter { !$0.checked } }
}

struct TripRecord: Decodable, Identifiable {
    let id: UUID
    let householdId: UUID
    let listId: UUID
    let userId: UUID
    let mine: Bool
    let listName: String
    // Original RFC3339 strings are also the deterministic Calendar request fingerprint.
    let start: String
    let end: String
    let timezone: String
    let title: String
    let description: String
    let location: String
    var status: String
    var eventId: String?
    var eventUrl: String?
    let createdAt: String
    let updatedAt: String

    var startDate: Date? { CalendarCall.date(start) }
    var endDate: Date? { CalendarCall.date(end) }
    var isActive: Bool { ["reserved", "scheduled", "outcome_unknown"].contains(status) }
    var isUncertain: Bool { ["reserved", "outcome_unknown"].contains(status) }
    func blocksNewTrip(at now: Date) -> Bool {
        isUncertain || (status == "scheduled" && (endDate.map { $0 > now } ?? true))
    }
    var calendarArguments: [String: Any] {
        ["start": start, "end": end, "timezone": timezone, "title": title,
         "description": description, "location": location]
    }
    func calendarCall() throws -> CalendarCall {
        try CalendarCall(["name": "calendar_create_event", "args": calendarArguments])
    }
}

struct TripProposal: Identifiable {
    let list: TripList
    let start: Date?
    let end: Date?
    let timezone: String
    let warning: String?
    let explanation: String
    let context: UUID
    /// An approval gets one reservation key, even when an HTTP response is lost.
    let reservationKey = UUID().uuidString
    var id: UUID { list.id }
    var canSchedule: Bool { start != nil && end != nil }
    var title: String { String("Shopping · \(list.storeName)".prefix(200)) }
    var location: String { String((list.merchant?.label ?? "").prefix(500)) }
    var description: String {
        let lines = list.openItems.map { "• \($0.title): \($0.quantity.formatted())\($0.unit.map { " " + $0 } ?? "")" }
        return String((["Shopping list: \(list.name)", "Includes travel time."] + lines).joined(separator: "\n").prefix(4000))
    }
    func calendarCall() throws -> CalendarCall {
        guard let start, let end else { throw BrowserError("no_trip_slot") }
        return try CalendarCall(["name": "calendar_create_event", "args": [
            "start": TripPlanner.timestamp(start, timezone: timezone),
            "end": TripPlanner.timestamp(end, timezone: timezone), "timezone": timezone,
            "title": title, "description": description, "location": location
        ]])
    }
}

struct TripBusyInterval: Equatable {
    let start: Date
    let end: Date

    static func decode(_ response: [String: Any]) throws -> [TripBusyInterval] {
        guard let rows = response["busy"] as? [[String: Any]], rows.count <= 10000,
              response["errors"] == nil || (response["errors"] as? [Any])?.isEmpty == true else {
            throw BrowserError("availability_unknown", "Calendar availability could not be verified. Try again.")
        }
        return try rows.map { row in
            guard let rawStart = row["start"] as? String, let rawEnd = row["end"] as? String,
                  let start = CalendarCall.date(rawStart), let end = CalendarCall.date(rawEnd), start < end else {
                throw BrowserError("availability_unknown", "Calendar returned an invalid busy interval. Try again.")
            }
            return TripBusyInterval(start: start, end: end)
        }
    }
}

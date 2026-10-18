import Foundation

enum TripPlanner {
    static func timestamp(_ date: Date, timezone: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: timezone)
        return formatter.string(from: date)
    }

    static func window(options: TripPlanningOptions, now: Date) throws -> TripBusyInterval {
        try options.validate()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: options.timezone)!
        // Always round forward; a proposed trip never begins in the past.
        let start = Date(timeIntervalSince1970: ceil(now.addingTimeInterval(5 * 60).timeIntervalSince1970 / 60) * 60)
        guard let end = calendar.date(byAdding: .day, value: options.days, to: start) else {
            throw BrowserError("invalid_trip_options")
        }
        return TripBusyInterval(start: start, end: end)
    }

    static func propose(lists: [TripList], trips: [TripRecord] = [], busy: [TripBusyInterval]?,
                        options: TripPlanningOptions, now: Date = Date(), context: UUID = UUID()) throws -> [TripProposal] {
        let window = try window(options: options, now: now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: options.timezone)!
        let activeLists = Set(trips.filter { $0.blocksNewTrip(at: now) }.map(\.listId))
        let eligible = lists.filter { $0.status == "open" && !$0.openItems.isEmpty && !activeLists.contains($0.id) }
            .sorted {
                let lhs = $0.neededBy ?? .distantFuture, rhs = $1.neededBy ?? .distantFuture
                return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs < rhs
            }
        var occupied = busy ?? []
        occupied += trips.filter(\.isActive).compactMap {
            guard let start = $0.startDate, let end = $0.endDate, start < end else { return nil }
            return TripBusyInterval(start: start, end: end)
        }
        return eligible.map { list in
            guard busy != nil else {
                return TripProposal(list: list, start: nil, end: nil, timezone: options.timezone, warning: nil,
                                    explanation: "Availability is unknown. Check Calendar again before planning.", context: context)
            }
            let duration = TimeInterval(options.durationMinutes * 60)
            var day = calendar.startOfDay(for: window.start)
            var result: TripBusyInterval?
            while day < window.end {
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
                      let opening = calendar.date(bySettingHour: options.startHour, minute: 0, second: 0, of: day,
                                                  matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
                      let closing = options.endHour == 24 ? nextDay : calendar.date(bySettingHour: options.endHour, minute: 0, second: 0, of: day,
                                                  matchingPolicy: .nextTime, repeatedTimePolicy: .last, direction: .forward) else { break }
                var candidate = max(opening, window.start)
                let limit = min(closing, window.end)
                for interval in occupied.sorted(by: { $0.start < $1.start }) {
                    if interval.end <= candidate { continue }
                    if interval.start >= candidate.addingTimeInterval(duration) { break }
                    candidate = max(candidate, interval.end)
                }
                if candidate.addingTimeInterval(duration) <= limit {
                    result = TripBusyInterval(start: candidate, end: candidate.addingTimeInterval(duration)); break
                }
                day = nextDay
            }
            if let result {
                occupied.append(result)
                let late = list.neededBy.map { result.end > $0 } ?? false
                return TripProposal(list: list, start: result.start, end: result.end, timezone: options.timezone,
                                    warning: late ? "This trip finishes after the list’s needed-by time. Some items may run out first." : nil,
                                    explanation: "Earliest available \(options.durationMinutes)-minute block, including travel.", context: context)
            }
            return TripProposal(list: list, start: nil, end: nil, timezone: options.timezone, warning: nil,
                                explanation: "No \(options.durationMinutes)-minute opening during your preferred hours in the next \(options.days) days. Try a longer window or different hours.", context: context)
        }
    }
}

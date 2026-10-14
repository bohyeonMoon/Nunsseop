import SwiftUI

/// The week, then Events or Reminders for the chosen day, as ledger rows.
struct CalendarPanel: View {
    @ObservedObject var calendar: CalendarModel
    let showsReminders: Bool
    /// How many days of the week there is room for.
    var days = 7
    @State private var showingReminders = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WeekStrip(calendar: calendar, days: days)
            PanelHLine()
            if showsReminders && calendar.access == .granted {
                HStack(spacing: 14) {
                    PanelSwitch(title: String(localized: "Events"), count: calendar.items.count,
                                selected: !showingReminders) { showingReminders = false }
                    PanelSwitch(title: String(localized: "Reminders"), count: calendar.reminders.count,
                                selected: showingReminders) { showingReminders = true }
                }
                .frame(height: 24)
            }
            switch calendar.access {
            case .granted:
                ScrollView(.vertical, showsIndicators: false) {
                    if showsReminders && showingReminders {
                        ReminderList(calendar: calendar)
                    } else {
                        EventList(items: calendar.items)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .panelFadeBottom(12)
            case .unknown, .denied:
                VStack(alignment: .leading, spacing: 6) {
                    Text(calendar.access == .denied
                         ? String(localized: "Calendar access is off")
                         : String(localized: "Allow calendar access to see your events"))
                        .font(.system(size: 11))
                        .foregroundStyle(PanelInk.secondary)
                        .lineLimit(2)
                    PanelAction(title: calendar.access == .denied ? "Open System Settings" : "Allow Access") {
                        calendar.requestAccess()
                    }
                }
                .padding(.horizontal, 8).padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .foregroundStyle(.white)
    }
}

/// The month, then the days with a dot under those that have events. Today is a white capsule, the chosen day a faint one.
private struct WeekStrip: View {
    @ObservedObject var calendar: CalendarModel
    let days: Int

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            Text(calendar.week.first ?? .now, format: .dateTime.month(.abbreviated))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 32, alignment: .leading)
            ForEach(calendar.week.prefix(days), id: \.self) { day in
                let today = Calendar.current.isDate(day, inSameDayAs: calendar.today)
                let selected = Calendar.current.isDate(day, inSameDayAs: calendar.selectedDay)
                Button { calendar.selectedDay = day } label: {
                    VStack(spacing: 1) {
                        Text(day, format: .dateTime.weekday(.abbreviated))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(selected || today ? 0.85 : 0.6))
                            .lineLimit(1)
                            .fixedSize()
                        Text(String(format: "%02d", Calendar.current.component(.day, from: day)))
                            .font(.system(size: 12, weight: today ? .bold : .medium).monospacedDigit())
                            .foregroundStyle(today ? Color.black : Color.white.opacity(selected ? 1 : 0.85))
                            .frame(width: 24, height: 17)
                            .background(Capsule().fill(today ? Color.white : selected ? Color.white.opacity(0.18) : .clear))
                        Circle()
                            .fill(.white.opacity(calendar.busyDays.contains(day) ? 0.6 : 0))
                            .frame(width: 3, height: 3)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(day, format: .dateTime.weekday(.wide).month().day()))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(height: 34)
    }
}

/// Events and Reminders: the chosen one a capsule, the other quiet. 24 pt tall to hit.
private struct PanelSwitch: View {
    let title: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: count > 0 ? "\(title) \(count)" : title)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(.white.opacity(selected ? 0.95 : 0.6))
                .padding(.horizontal, 8).frame(height: 18)
                .background(Capsule().fill(.white.opacity(selected ? 0.14 : 0)))
                .frame(height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ReminderList: View {
    @ObservedObject var calendar: CalendarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch calendar.reminderAccess {
            case .granted:
                if calendar.reminders.isEmpty {
                    Text("No reminders").font(.system(size: 11)).foregroundStyle(PanelInk.secondary)
                        .padding(.horizontal, 8).frame(height: 24)
                }
                ForEach(calendar.reminders) { item in
                    LedgerRow {
                        HStack(spacing: 6) {
                            Button { calendar.complete(item) } label: {
                                Image(systemName: "circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.75))
                                    .frame(width: 16, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(Text("Mark as completed"))
                            .accessibilityLabel(Text("Mark as completed"))
                            Text(verbatim: item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 4)
                            if let due = item.due {
                                Text.panel(due.formatted(date: .omitted, time: .shortened), size: 11, opacity: due < .now ? 1 : 0.6, mono: true)
                                    .foregroundStyle(due < .now ? PanelInk.waiting : .white.opacity(0.6))
                                    .lineLimit(1).fixedSize()
                            }
                        }
                    }
                }
            case .unknown, .denied:
                PanelAction(title: calendar.reminderAccess == .denied ? "Open System Settings" : "Allow Reminders") {
                    calendar.requestReminderAccess()
                }
                .padding(.horizontal, 8).padding(.top, 4)
            }
        }
    }
}

private struct EventList: View {
    let items: [CalendarItem]

    var body: some View {
        if items.isEmpty {
            Text("No events")
                .font(.system(size: 11))
                .foregroundStyle(PanelInk.secondary)
                .padding(.horizontal, 8).frame(height: 24)
        } else {
            // Checked every minute, so join buttons go away when their event ends with the tab open.
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        LedgerRow {
                            HStack(spacing: 8) {
                                Text.panel(item.isAllDay ? String(localized: "All day") : item.start.formatted(date: .omitted, time: .shortened),
                                           size: 11, opacity: 0.6, mono: true)
                                    .lineLimit(1).frame(width: 60, alignment: .leading)
                                Text(verbatim: item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    .help(Text(verbatim: "\(item.start.formatted(date: .omitted, time: .shortened)) – \(item.end.formatted(date: .omitted, time: .shortened))"))
                                Spacer(minLength: 4)
                                if let url = item.joinURL, item.canJoin(at: context.date) {
                                    PanelAction(title: "Join", symbol: "video.fill") { NSWorkspace.shared.open(url) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

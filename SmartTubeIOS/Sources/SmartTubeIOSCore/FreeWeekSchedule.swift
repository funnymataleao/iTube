import Foundation

/// Pure timing policy for iTube's non-blocking welcome week.
///
/// This is deliberately not a StoreKit entitlement: everyone can keep using
/// the free tier after the welcome week. The end date only controls when the
/// app may present a dismissible Plus offer.
public struct FreeWeekSchedule: Equatable, Sendable {
    public static let duration: TimeInterval = 7 * 24 * 60 * 60
    public static let reminderCooldown: TimeInterval = 7 * 24 * 60 * 60

    public let startDate: Date

    public init(startDate: Date) {
        self.startDate = startDate
    }

    public var endDate: Date {
        startDate.addingTimeInterval(Self.duration)
    }

    public func isActive(at date: Date) -> Bool {
        date < endDate
    }

    public func daysRemaining(at date: Date) -> Int {
        guard isActive(at: date) else { return 0 }
        let remaining = endDate.timeIntervalSince(date)
        return min(7, max(1, Int(ceil(remaining / (24 * 60 * 60)))))
    }

    public func shouldPresentOffer(
        at date: Date,
        lastPresentedAt: Date?,
        hasPaidAccess: Bool
    ) -> Bool {
        guard !hasPaidAccess, !isActive(at: date) else { return false }
        guard let lastPresentedAt else { return true }
        guard date >= lastPresentedAt else { return false }
        return date.timeIntervalSince(lastPresentedAt) >= Self.reminderCooldown
    }
}

import Foundation
import Testing
@testable import SmartTubeIOSCore

@Suite("Free week schedule")
struct FreeWeekScheduleTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("First seven days never present a paywall")
    func activeWeek() {
        let schedule = FreeWeekSchedule(startDate: start)
        let almostExpired = start.addingTimeInterval(FreeWeekSchedule.duration - 1)

        #expect(schedule.isActive(at: start))
        #expect(schedule.isActive(at: almostExpired))
        #expect(!schedule.shouldPresentOffer(
            at: almostExpired,
            lastPresentedAt: nil,
            hasPaidAccess: false
        ))
    }

    @Test("Offer becomes eligible exactly when the week ends")
    func expiryBoundary() {
        let schedule = FreeWeekSchedule(startDate: start)

        #expect(!schedule.isActive(at: schedule.endDate))
        #expect(schedule.daysRemaining(at: schedule.endDate) == 0)
        #expect(schedule.shouldPresentOffer(
            at: schedule.endDate,
            lastPresentedAt: nil,
            hasPaidAccess: false
        ))
    }

    @Test("Paid access always suppresses the offer")
    func paidAccess() {
        let schedule = FreeWeekSchedule(startDate: start)
        let expired = schedule.endDate.addingTimeInterval(1)

        #expect(!schedule.shouldPresentOffer(
            at: expired,
            lastPresentedAt: nil,
            hasPaidAccess: true
        ))
    }

    @Test("Dismissed offer respects the weekly cooldown")
    func reminderCooldown() {
        let schedule = FreeWeekSchedule(startDate: start)
        let firstPrompt = schedule.endDate

        #expect(!schedule.shouldPresentOffer(
            at: firstPrompt.addingTimeInterval(FreeWeekSchedule.reminderCooldown - 1),
            lastPresentedAt: firstPrompt,
            hasPaidAccess: false
        ))
        #expect(schedule.shouldPresentOffer(
            at: firstPrompt.addingTimeInterval(FreeWeekSchedule.reminderCooldown),
            lastPresentedAt: firstPrompt,
            hasPaidAccess: false
        ))
    }

    @Test("Future clock changes cannot create more than seven displayed days")
    func futureClockChange() {
        let schedule = FreeWeekSchedule(startDate: start)
        let earlierDate = start.addingTimeInterval(-30 * 24 * 60 * 60)

        #expect(schedule.daysRemaining(at: earlierDate) == 7)
    }
}

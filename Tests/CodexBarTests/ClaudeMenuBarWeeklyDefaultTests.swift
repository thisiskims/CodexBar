import CodexBarCore
import Foundation
import Testing

struct ClaudeMenuBarWeeklyDefaultTests {
    @Test
    func `claude automatic menu bar window prefers weekly while explicit primary stays session`() {
        let now = Date(timeIntervalSince1970: 1_795_420_000)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 87,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 16,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(86400),
                resetDescription: nil),
            updatedAt: now)

        let autoWindow = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .claude,
            snapshot: snapshot,
            supportsAverage: false,
            antigravityPrioritizeExhaustedQuotas: false,
            now: now)
        #expect(autoWindow?.windowMinutes == 10080)
        #expect(autoWindow?.remainingPercent == 84)

        let sessionWindow = MenuBarMetricWindowResolver.rateWindow(
            preference: .primary,
            provider: .claude,
            snapshot: snapshot,
            supportsAverage: false,
            antigravityPrioritizeExhaustedQuotas: false,
            now: now)
        #expect(sessionWindow?.windowMinutes == 300)
        #expect(sessionWindow?.remainingPercent == 13)
    }
}

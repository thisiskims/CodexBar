import Foundation

public enum ColabProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .colab,
            menuBarMetrics: ProviderMenuBarMetricCapabilities(supported: [.automatic]),
            metadata: ProviderMetadata(
                id: .colab,
                displayName: "Colab",
                shortDisplayName: "Colab",
                sessionLabel: "Compute Units",
                weeklyLabel: "Compute Units",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Compute units from Google Colab.",
                toggleTitle: "Show Google Colab compute units",
                cliName: "colab",
                defaultEnabled: false,
                widgetSelectable: false,
                burnDownWidgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                balanceOnly: true,
                dashboardURL: "https://colab.research.google.com",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .colab),
                iconResourceName: "ProviderIcon-colab",
                color: ProviderColor(hex: 0xF9AB00),
                confettiPalette: [
                    ProviderColor(hex: 0xF9AB00),
                    ProviderColor(hex: 0xE8710A),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "No cost history data." }),
            pace: .calendarMonthResetWindow,
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "colab",
                versionDetector: nil))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        switch context.sourceMode {
        case .auto, .api:
            [ColabUsageFetchStrategy()]
        case .web, .cli, .oauth:
            []
        }
    }
}

private struct ColabBridgeResponse: Decodable {
    let currentBalance: Double
    let maxComputeUnits: Double
    let consumptionRateHourly: Double
    let assignmentsCount: Int
    let eligibleGpus: [String]
    let eligibleTpus: [String]
    let nextResetUnix: Double?

    enum CodingKeys: String, CodingKey {
        case currentBalance = "current_balance"
        case maxComputeUnits = "max_compute_units"
        case consumptionRateHourly = "consumption_rate_hourly"
        case assignmentsCount = "assignments_count"
        case eligibleGpus = "eligible_gpus"
        case eligibleTpus = "eligible_tpus"
        case nextResetUnix = "next_reset_unix"
    }
}

struct ColabUsageFetchStrategy: ProviderFetchStrategy {
    let id: String = "colab.usage"
    let kind: ProviderFetchKind = .apiToken

    private var bridgeURL: URL {
        URL(string: "http://127.0.0.1:18492/colab")!
    }

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        var request = URLRequest(url: self.bridgeURL)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "ColabUsage",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Colab usage bridge returned HTTP \(http.statusCode)"])
        }

        let payload = try JSONDecoder().decode(ColabBridgeResponse.self, from: data)
        let now = Date()
        let maxUnits = max(payload.maxComputeUnits, payload.currentBalance, 1.0)
        let usedUnits = max(0, maxUnits - payload.currentBalance)
        let usedPct = max(0, min(100, (usedUnits / maxUnits) * 100))

        let nextReset = payload.nextResetUnix.map { Date(timeIntervalSince1970: $0) }

        let primary = RateWindow(
            usedPercent: usedPct,
            windowMinutes: nextReset != nil ? ProviderPaceCapability.monthlyWindowSentinelMinutes : nil,
            resetsAt: nextReset,
            resetDescription: nil)

        var rows: [ProviderDetailSection.Row] = [
            ProviderDetailSection.makeRow(
                label: "Balance",
                value: String(format: "%.2f / %.0f CU", payload.currentBalance, maxUnits),
                progress: .makeProgress(used: payload.currentBalance, total: maxUnits)),
            ProviderDetailSection.makeRow(
                label: "Usage rate",
                value: String(format: "%.2f CU/hr", payload.consumptionRateHourly)),
            ProviderDetailSection.makeRow(
                label: "Active runtimes",
                value: "\(payload.assignmentsCount)"),
        ]
        if !payload.eligibleGpus.isEmpty {
            rows.append(ProviderDetailSection.makeRow(
                label: "GPUs",
                value: payload.eligibleGpus.joined(separator: ", ")))
        }
        if !payload.eligibleTpus.isEmpty {
            rows.append(ProviderDetailSection.makeRow(
                label: "TPUs",
                value: payload.eligibleTpus.joined(separator: ", ")))
        }

        let section = ProviderDetailSection.makeSection(
            title: "Compute Units",
            rows: rows)

        let identity = ProviderIdentitySnapshot(
            providerID: .colab,
            accountEmail: nil,
            accountOrganization: "Google AI Pro",
            loginMethod: "Colab OAuth")

        let snapshot = UsageSnapshot(
            primary: primary,
            secondary: nil,
            providerCost: nil,
            details: [section],
            updatedAt: now,
            identity: identity,
            dataConfidence: .exact)

        return self.makeResult(usage: snapshot, sourceLabel: "colab")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

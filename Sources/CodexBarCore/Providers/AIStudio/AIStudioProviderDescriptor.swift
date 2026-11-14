import Foundation

public enum AIStudioProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .aistudio,
            menuBarMetrics: ProviderMenuBarMetricCapabilities(supported: [.automatic]),
            metadata: ProviderMetadata(
                id: .aistudio,
                displayName: "AI Studio",
                shortDisplayName: "AI Studio",
                sessionLabel: "GCP Credits",
                weeklyLabel: "GCP Credits",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "GCP Credits from Google AI Studio billing.",
                toggleTitle: "Show Google AI Studio credits",
                cliName: "aistudio",
                defaultEnabled: false,
                widgetSelectable: false,
                burnDownWidgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                balanceOnly: true,
                dashboardURL: "https://aistudio.google.com/billing",
                statusPageURL: nil,
                statusLinkURL: "https://aistudio.google.com/status"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .aistudio),
                iconResourceName: "ProviderIcon-aistudio",
                color: ProviderColor(hex: 0x4285F4),
                confettiPalette: [
                    ProviderColor(hex: 0x4285F4),
                    ProviderColor(hex: 0x8AB4F8),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "No cost history data." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "aistudio",
                versionDetector: nil))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        switch context.sourceMode {
        case .auto, .api:
            [AIStudioCreditsFetchStrategy()]
        case .web, .cli, .oauth:
            []
        }
    }
}

private struct AIStudioBridgeGrant: Decodable {
    let name: String
    let total: Double
    let used: Double
    let available: Double
    let expiresUnix: Double?

    enum CodingKeys: String, CodingKey {
        case name, total, used, available
        case expiresUnix = "expires_unix"
    }
}

private struct AIStudioBridgeResponse: Decodable {
    let accountId: String
    let accountName: String
    let currency: String
    let totalGrant: Double
    let totalUsed: Double
    let totalAvailable: Double
    let soonestExpiryUnix: Double?
    let grants: [AIStudioBridgeGrant]

    enum CodingKeys: String, CodingKey {
        case currency, grants
        case accountId = "account_id"
        case accountName = "account_name"
        case totalGrant = "total_grant"
        case totalUsed = "total_used"
        case totalAvailable = "total_available"
        case soonestExpiryUnix = "soonest_expiry_unix"
    }
}

struct AIStudioCreditsFetchStrategy: ProviderFetchStrategy {
    let id: String = "aistudio.credits"
    let kind: ProviderFetchKind = .apiToken

    private var bridgeURL: URL {
        URL(string: "http://127.0.0.1:18492/credits")!
    }

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        var request = URLRequest(url: self.bridgeURL)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "AIStudioCredits",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "AI Studio credits bridge returned HTTP \(http.statusCode)"])
        }

        let payload = try JSONDecoder().decode(AIStudioBridgeResponse.self, from: data)
        let now = Date()
        let soonestExpiry = payload.soonestExpiryUnix.map { Date(timeIntervalSince1970: $0) }
        let usedPct = payload.totalGrant > 0
            ? max(0, min(100, (payload.totalUsed / payload.totalGrant) * 100))
            : 0

        let primary = RateWindow(
            usedPercent: usedPct,
            windowMinutes: nil,
            resetsAt: soonestExpiry,
            resetDescription: nil)

        let cost = ProviderCostSnapshot(
            used: payload.totalUsed,
            limit: payload.totalGrant,
            currencyCode: payload.currency,
            period: "GCP Credits",
            resetsAt: soonestExpiry,
            balance: payload.totalAvailable,
            updatedAt: now)

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = payload.currency
        formatter.maximumFractionDigits = 0
        let fmt: (Double) -> String = { val in
            formatter.string(from: NSNumber(value: val)) ?? "\(payload.currency) \(Int(val))"
        }

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "MMM d, yyyy"

        var rows: [ProviderDetailSection.Row] = [
            ProviderDetailSection.makeRow(label: "Available", value: fmt(payload.totalAvailable)),
            ProviderDetailSection.makeRow(label: "Used", value: fmt(payload.totalUsed)),
        ]
        for grant in payload.grants.prefix(20) {
            let label = grant.expiresUnix.map {
                "Exp \(dateFmt.string(from: Date(timeIntervalSince1970: $0)))"
            } ?? "Grant"
            let val = "\(fmt(grant.available)) / \(fmt(grant.total))"
            let progress: ProviderDetailSection.Row.Progress? = grant.total > 0
                ? .makeProgress(used: grant.available, total: grant.total)
                : nil
            rows.append(ProviderDetailSection.makeRow(label: label, value: val, progress: progress))
        }

        let section = ProviderDetailSection.makeSection(
            title: "Eligible Grants (\(payload.grants.count))",
            rows: rows)

        let identity = ProviderIdentitySnapshot(
            providerID: .aistudio,
            accountEmail: nil,
            accountOrganization: payload.accountName,
            loginMethod: "Chrome Session")

        let snapshot = UsageSnapshot(
            primary: primary,
            secondary: nil,
            providerCost: cost,
            details: [section],
            updatedAt: now,
            identity: identity,
            dataConfidence: .exact)

        return self.makeResult(usage: snapshot, sourceLabel: "aistudio")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

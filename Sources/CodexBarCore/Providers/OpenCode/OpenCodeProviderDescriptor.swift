import Foundation

public enum OpenCodeProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(tokenAccountSupport: TokenAccountSupport(
        title: "Session tokens",
        subtitle: "Store multiple OpenCode Cookie headers.",
        placeholder: "Cookie: …",
        injection: .cookieHeader,
        requiresManualCookieSource: true,
        cookieName: nil))

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .opencode,
            settingsSection: .init(
                OpenCodeProviderSettingsKey.self,
                cookieSettings: { settings in
                    CookieProviderSettings(
                        cookieSource: settings.cookieSource,
                        manualCookieHeader: settings.manualCookieHeader)
                },
                credentialSettings: { context in
                    let settings = context.cookieSettings(for: .opencode)
                    return OpenCodeProviderSettings(
                        cookieSource: settings.cookieSource,
                        manualCookieHeader: settings.manualCookieHeader,
                        workspaceID: context.config?.workspaceID)
                }),
            credentials: self.credentials,
            config: ProviderConfigCapabilities(workspaceIDValidationOrder: 2),
            metadata: ProviderMetadata(
                id: .opencode,
                displayName: "OpenCode",
                sessionLabel: "5-hour",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show OpenCode usage",
                cliName: "opencode",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "OpenCode debug log not yet implemented",
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://opencode.ai/auth",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .opencode),
                iconResourceName: "ProviderIcon-opencode",
                color: ProviderColor(hex: 0x3B82F6),
                confettiPalette: [
                    ProviderColor(hex: 0x211E1E),
                    ProviderColor(hex: 0xCFCECD),
                    ProviderColor(hex: 0xFAB283),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "OpenCode cost summary is not supported." }),
            pace: ProviderPaceCapability(secondary: .weekly),
            presentation: ProviderUsagePresentation(costPresenter: { snapshot in
                // A pay-as-you-go workspace with no configured limit has no percentage to show,
                // so it renders spend and remaining balance instead of the generic budget bar.
                let style: ProviderCostMenuCardStyle = (snapshot.providerCost?.limit ?? 1) <= 0
                    ? .payAsYouGoSpend
                    : .generic
                return ProviderCostPresentation(menuCardStyle: style)
            }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [OpenCodeUsageFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "opencode",
                versionDetector: nil))
    }
}

struct OpenCodeUsageFetchStrategy: ProviderFetchStrategy {
    let id: String = "opencode.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        if context.settings?.opencode?.cookieSource != .off {
            return true
        }
        return OpenCodeFreeUsageReader.hasLocalSource()
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let now = Date()
        let freeSummary = OpenCodeFreeUsageReader.load(now: now)
        let freeSection = OpenCodeFreeUsageReader.detailSection(from: freeSummary, now: now)
        let cookieSource = context.settings?.opencode?.cookieSource ?? .auto

        if cookieSource == .off {
            if let freeSection {
                return self.makeResult(
                    usage: Self.localOnlySnapshot(freeSection: freeSection, now: now),
                    sourceLabel: "local")
            }
            throw OpenCodeSettingsError.missingCookie
        }

        let workspaceOverride = context.settings?.opencode?.workspaceID
            ?? context.env["CODEXBAR_OPENCODE_WORKSPACE_ID"]
        do {
            let cookieHeader = try Self.resolveCookieHeader(context: context, allowCached: true)
            let snapshot = try await OpenCodeUsageFetcher.fetchUsage(
                cookieHeader: cookieHeader,
                timeout: context.webTimeout,
                workspaceIDOverride: workspaceOverride)
            return self.makeResult(
                usage: Self.attachingFreeSection(freeSection, to: snapshot.toUsageSnapshot()),
                sourceLabel: "web")
        } catch OpenCodeUsageError.invalidCredentials where cookieSource != .manual {
            #if os(macOS)
            do {
                CookieHeaderCache.clear(provider: .opencode)
                let cookieHeader = try Self.resolveCookieHeader(context: context, allowCached: false)
                let snapshot = try await OpenCodeUsageFetcher.fetchUsage(
                    cookieHeader: cookieHeader,
                    timeout: context.webTimeout,
                    workspaceIDOverride: workspaceOverride)
                return self.makeResult(
                    usage: Self.attachingFreeSection(freeSection, to: snapshot.toUsageSnapshot()),
                    sourceLabel: "web")
            } catch {
                if let freeSection {
                    return self.makeResult(
                        usage: Self.localOnlySnapshot(freeSection: freeSection, now: now),
                        sourceLabel: "local")
                }
                throw error
            }
            #else
            if let freeSection {
                return self.makeResult(
                    usage: Self.localOnlySnapshot(freeSection: freeSection, now: now),
                    sourceLabel: "local")
            }
            throw OpenCodeUsageError.invalidCredentials
            #endif
        } catch {
            if let freeSection {
                return self.makeResult(
                    usage: Self.localOnlySnapshot(freeSection: freeSection, now: now),
                    sourceLabel: "local")
            }
            throw error
        }
    }

    private static func localOnlySnapshot(freeSection: ProviderDetailSection, now: Date) -> UsageSnapshot {
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: nil,
            details: [freeSection],
            updatedAt: now,
            identity: nil)
    }

    private static func attachingFreeSection(
        _ freeSection: ProviderDetailSection?,
        to snapshot: UsageSnapshot) -> UsageSnapshot
    {
        guard let freeSection else { return snapshot }
        return UsageSnapshot(
            primary: snapshot.primary,
            secondary: snapshot.secondary,
            tertiary: snapshot.tertiary,
            extraRateWindows: snapshot.extraRateWindows,
            providerCost: snapshot.providerCost,
            details: snapshot.details + [freeSection],
            updatedAt: snapshot.updatedAt,
            identity: snapshot.identity,
            dataConfidence: snapshot.dataConfidence)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveCookieHeader(context: ProviderFetchContext, allowCached: Bool) throws -> String {
        try OpenCodeWebCookieSupport.resolveCookieHeader(
            context: OpenCodeWebCookieSupport.Context(
                settings: context.settings?.opencode,
                provider: .opencode,
                browserDetection: context.browserDetection,
                allowCached: allowCached),
            invalidCookie: OpenCodeSettingsError.invalidCookie,
            missingCookie: OpenCodeSettingsError.missingCookie)
    }
}

enum OpenCodeSettingsError: LocalizedError {
    case missingCookie
    case invalidCookie

    var errorDescription: String? {
        switch self {
        case .missingCookie:
            "No OpenCode session cookies found in browsers."
        case .invalidCookie:
            "OpenCode cookie header is invalid."
        }
    }
}

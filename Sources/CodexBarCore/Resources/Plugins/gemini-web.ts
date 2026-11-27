defineProvider({
  id: "gemini",
  name: "Gemini app",
  endpoints: ["https://gemini.google.com"],
  settings: [],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["gemini.google.com", "google.com"],
  cookiePolicy: { selection: "request-url", cache: "nonpersistent", imports: "access-gated" },
  async fetchUsage(ctx) {
    const domain = "gemini.google.com";
    if (ctx.browser.availability(domain) === "off")
      throw ctx.fail.missingCredential("Gemini app cookies are disabled.");
    // UsagePageQuery from the public UsagePageSurface bundle; this is separate from Gemini CLI quotas.
    const signature = "2/oee4e7iJB+YlSRDtGuxpv36rfWVddgii370z2JvCuVM=";
    const variables = JSON.stringify({
      g1Request: { entrypoints: ["GEMINI_USAGE_SETTINGS_UPGRADE_BANNER"] },
      workspaceRequest: { recommendationsForSurfaceRequests: [] },
    });
    const url =
      `https://${domain}/_/BardChatUi/graphql/schemas/GEMINI_WEB_GRAPHQL/executeQuery` +
      `?query_signature=${encodeURIComponent(signature)}&variables=${encodeURIComponent(variables)}`;
    const invalid = (): never => {
      throw ctx.fail.parseFailure("Gemini app usage response changed. Update CodexBar or report this.");
    };
    const object = (value: unknown): Record<string, unknown> | undefined =>
      value !== null && typeof value === "object" && !Array.isArray(value)
        ? (value as Record<string, unknown>)
        : undefined;
    let rejected = false;
    const sorrySources: string[] = [];
    for await (const session of ctx.browser.sessions(domain)) {
      const response = await ctx.http.get(url, {
        cookieSession: session.id,
        headers: { Accept: "application/json", Referer: `https://${domain}/usage` },
        retryPolicy: "transientIdempotent",
      });
      if (response.status >= 300 && response.status < 400) {
        const headers = object(response.headers);
        const location = typeof headers?.location === "string" ? headers.location : "";
        if (location.includes("/sorry/")) {
          if (!sorrySources.includes(session.source)) sorrySources.push(session.source);
          continue;
        }
        ctx.browser.rejectCookie(domain, session);
        rejected = true;
        continue;
      }
      if (
        response.status === 401 ||
        response.status === 403 ||
        (response.status === 200 && response.bodyText.trimStart().startsWith("<"))
      ) {
        ctx.browser.rejectCookie(domain, session);
        rejected = true;
        continue;
      }
      if (response.status === 429) throw ctx.fail.rateLimited("Gemini app usage is rate limited.");
      if (response.status >= 500) throw ctx.fail.providerUnavailable("Gemini app usage is temporarily unavailable.");
      if (response.status !== 200) throw ctx.fail.apiFailure(`Gemini app returned HTTP ${response.status}.`);
      let results: unknown;
      try {
        results = JSON.parse(response.bodyText.trim().replace(/^\)\]\}'\s*/, ""));
      } catch (error) {
        void error;
        return invalid();
      }
      if (!Array.isArray(results)) return invalid();
      const viewerEntry = results
        .map(object)
        .find((entry) => {
          const entryData = object(entry?.data);
          return entryData !== undefined && Object.prototype.hasOwnProperty.call(entryData, "viewer");
        });
      const result = object(viewerEntry?.data);
      if (!result) return invalid();
      if (result.viewer === null) {
        ctx.browser.rejectCookie(domain, session);
        rejected = true;
        continue;
      }
      const viewer = object(result.viewer);
      if (!viewer) return invalid();
      const usage = object(object(viewer.rpcs)?.getUsageInfo);
      if (!usage) {
        const errors = Array.isArray(viewerEntry?.errors) ? viewerEntry.errors.map(object) : [];
        const isUnauthenticated = errors.some((err) => {
          const status = object(object(err?.extensions)?.status);
          if (status?.code === 16) return true;
          const details = Array.isArray(status?.details) ? status.details.map(object) : [];
          return details.some((detail) => detail?.reason === "UNAUTHENTICATED");
        });
        if (isUnauthenticated) {
          ctx.browser.rejectCookie(domain, session);
          rejected = true;
          continue;
        }
        return invalid();
      }
      if (!Array.isArray(usage.pools)) return invalid();
      const pools = usage.pools;
      const window = (type: string, minutes: number) => {
        const pool = pools.map(object).find((pool) => pool?.poolType === type);
        const percent = pool?.percentageUsed;
        if (typeof percent !== "number" || !Number.isFinite(percent) || percent < 0) return undefined;
        const rawReset = object(pool?.gxu)?.windowRefreshesAt;
        let resetsAt: Date | undefined;
        if (typeof rawReset === "string" && /^\d{4}-\d{2}-\d{2}T/.test(rawReset)) {
          try {
            const date = ctx.date.iso(rawReset);
            if (Number.isFinite(date.getTime())) resetsAt = date;
          } catch (error) {
            void error;
          }
        }
        return { usedPercent: Math.min(100, percent * 100), windowMinutes: minutes, resetsAt };
      };
      const primary = window("GXU_FIVE_HOURLY", 300);
      const secondary = window("GXU_WEEKLY", 10080);
      if (!primary && !secondary) {
        throw ctx.fail.providerUnavailable("This Google account reports no Gemini app usage windows.");
      }
      return {
        primary,
        secondary,
        identity: { loginMethod: usage.subscriptionTier === "TIER1" ? "Pro" : undefined },
        dataConfidence: "exact",
      };
    }
    if (rejected) throw ctx.fail.authenticationExpired("Sign in again at gemini.google.com/usage.");
    if (sorrySources.length > 0) {
      // Name the cookie source that hit /sorry: background refreshes may only reach Safari, not Chrome.
      throw ctx.fail.rateLimited(
        `Google redirected Gemini usage to a verification check (/sorry). Open gemini.google.com/usage in ${sorrySources.join(" and ")}, then refresh.`,
      );
    }
    throw ctx.fail.missingCredential(
      `Sign in at gemini.google.com/usage. Supported browsers: ${ctx.browser.supportedBrowsers}. Or paste its Cookie header.`,
    );
  },
});

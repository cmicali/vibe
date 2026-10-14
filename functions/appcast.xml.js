// The update feed's check counter, a Cloudflare Pages Function. Each request
// from Sparkle is one update check by an installed copy. It writes one
// Analytics Engine data point, then serves the static feed unchanged.
// Assets/Web/README.md (Update checks) has the setup, the columns and the
// queries. appcast-arm64.xml.js reuses this handler.

// Sparkle's User-Agent is "<app name>/<app version> Sparkle/<Sparkle version>".
const SPARKLE_USER_AGENT = /\/(\S{1,32}) Sparkle\//;

export function onRequestGet(context) {
    try {
        countCheck(context);
    } catch (error) {
        // TRAP: a failed count must never fail the feed. Every installed copy
        // reads it, and an error here would stop all updates.
        console.error("update check not counted", error);
    }
    return context.next();
}

function countCheck({ request, env }) {
    // Unbound in a preview deployment, and until the dashboard binding exists.
    const dataset = env.UPDATE_CHECKS;
    const version = SPARKLE_USER_AGENT.exec(request.headers.get("User-Agent") ?? "")?.[1];
    if (!dataset || !version) {
        return;
    }
    const url = new URL(request.url);
    // Anyone can send any query, so each value is capped.
    const param = (name) => (url.searchParams.get(name) ?? "").slice(0, 32);
    // A build without the lang parameter is counted by the first language
    // its request asks for, such as "de-CH" from "de-CH,de;q=0.9".
    const acceptLanguage = (request.headers.get("Accept-Language") ?? "").split(/[,;]/)[0].trim();
    dataset.writeDataPoint({
        blobs: [
            url.pathname === "/appcast-arm64.xml" ? "arm64" : "universal",
            version,
            param("os"),
            param("arch"),
            param("channel"),
            request.cf?.country ?? "",
            param("lang") || acceptLanguage.slice(0, 32),
        ],
    });
}

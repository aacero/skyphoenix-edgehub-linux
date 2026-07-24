import QtQuick

// Canonical state envelope for widgets backed by an external data provider.
// The provider owns the facts below. This component owns precedence, naming,
// and concise user-facing labels so connected widgets cannot drift apart.
QtObject {
    id: envelope

    property bool configured: false
    property bool available: true
    property string unavailableReason: ""
    property bool loading: false
    property bool hasData: false
    property string errorText: ""
    property double lastSuccessAt: 0
    property double nowMs: Date.now()
    property int staleAfterSec: 180

    readonly property int ageSec: envelope.lastSuccessAt > 0
        ? Math.max(0, Math.floor((envelope.nowMs - envelope.lastSuccessAt) / 1000))
        : -1
    readonly property bool isStale: envelope.ageSec >= Math.max(1, envelope.staleAfterSec)
    readonly property string normalizedError: envelope.errorText.trim().toLowerCase()

    readonly property string state: {
        if (!envelope.configured) return "unconfigured"
        if (!envelope.available) return "unavailable"
        if (envelope.loading) return "loading"
        if (envelope.normalizedError.length) {
            if (envelope.normalizedError.indexOf("blocked") >= 0
                    || envelope.normalizedError.indexOf("denied") >= 0
                    || envelope.normalizedError.indexOf("not allowed") >= 0)
                return "blocked"
            if (envelope.normalizedError.indexOf("offline") >= 0
                    || envelope.normalizedError.indexOf("disconnected") >= 0
                    || envelope.normalizedError.indexOf("unreachable") >= 0
                    || envelope.normalizedError.indexOf("timed out") >= 0
                    || envelope.normalizedError.indexOf("network") >= 0)
                return "disconnected"
            return "error"
        }
        if (envelope.isStale) return "stale"
        if (envelope.hasData) return "fresh"
        return "empty"
    }

    readonly property string badgeLabel: {
        switch (envelope.state) {
        case "unconfigured": return "Setup"
        case "loading": return "Loading"
        case "fresh": return ""
        case "stale": return "Stale"
        case "blocked": return "Blocked"
        case "disconnected": return "Offline"
        case "error": return "Error"
        case "empty": return "Empty"
        case "unavailable": return "Unavailable"
        default: return ""
        }
    }

    readonly property string detailText: {
        switch (envelope.state) {
        case "unconfigured": return "Setup required"
        case "loading": return "Refreshing"
        case "fresh": return envelope.freshnessText
        case "stale": return envelope.freshnessText
        case "blocked": return envelope.errorText
        case "disconnected": return envelope.errorText
        case "error": return envelope.errorText
        case "empty": return "No data"
        case "unavailable": return envelope.unavailableReason.length
            ? envelope.unavailableReason : "Provider unavailable"
        default: return ""
        }
    }

    function ageText(seconds) {
        if (seconds < 0) return "No successful refresh"
        if (seconds < 60) return "Updated " + seconds + "s ago"
        if (seconds < 3600) return "Updated " + Math.floor(seconds / 60) + "m ago"
        return "Updated " + Math.floor(seconds / 3600) + "h ago"
    }
    readonly property string freshnessText: envelope.ageText(envelope.ageSec)
}

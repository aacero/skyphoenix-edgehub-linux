import QtQuick
import QtTest
import "../../ui/qml/widgets" as W

Item {
    width: 320
    height: 200

    W.ProviderState {
        id: provider
        nowMs: 1000000
        staleAfterSec: 60
    }

    TestCase {
        name: "ProviderState"

        function init() {
            provider.configured = false
            provider.available = true
            provider.unavailableReason = ""
            provider.loading = false
            provider.hasData = false
            provider.errorText = ""
            provider.lastSuccessAt = 0
            provider.nowMs = 1000000
            provider.staleAfterSec = 60
        }

        function test_state_vocabulary_data() {
            return [
                { tag: "unconfigured", configured: false, expected: "unconfigured", badge: "Setup" },
                { tag: "loading", configured: true, loading: true, expected: "loading", badge: "Loading" },
                { tag: "fresh", configured: true, hasData: true, expected: "fresh", badge: "" },
                { tag: "stale", configured: true, hasData: true, at: 940000, expected: "stale", badge: "Stale" },
                { tag: "blocked", configured: true, error: "Blocked", expected: "blocked", badge: "Blocked" },
                { tag: "disconnected", configured: true, error: "Timed out", expected: "disconnected", badge: "Offline" },
                { tag: "error", configured: true, error: "Parse error", expected: "error", badge: "Error" },
                { tag: "empty", configured: true, expected: "empty", badge: "Empty" },
                { tag: "unavailable", configured: true, available: false, expected: "unavailable", badge: "Unavailable" }
            ]
        }

        function test_state_vocabulary(row) {
            provider.configured = row.configured
            provider.available = row.available === undefined ? true : row.available
            provider.loading = row.loading === true
            provider.hasData = row.hasData === true
            provider.errorText = row.error || ""
            provider.lastSuccessAt = row.at || 0
            compare(provider.state, row.expected)
            compare(provider.badgeLabel, row.badge)
        }

        function test_precedence_is_deterministic() {
            provider.errorText = "Blocked"
            provider.loading = true
            provider.hasData = true
            provider.lastSuccessAt = 1
            compare(provider.state, "unconfigured", "configuration is required first")

            provider.configured = true
            provider.available = false
            compare(provider.state, "unavailable", "missing provider capability is explicit")

            provider.available = true
            compare(provider.state, "loading", "an in-flight refresh is visible")

            provider.loading = false
            compare(provider.state, "blocked", "policy failures are distinct from generic errors")
        }

        function test_freshness_boundaries_and_text() {
            provider.configured = true
            provider.hasData = true
            provider.lastSuccessAt = 999000
            compare(provider.ageSec, 1)
            compare(provider.state, "fresh")
            compare(provider.freshnessText, "Updated 1s ago")

            provider.lastSuccessAt = 940000
            compare(provider.ageSec, 60)
            compare(provider.state, "stale")
            compare(provider.freshnessText, "Updated 1m ago")
        }

        function test_error_classification_is_case_insensitive() {
            provider.configured = true
            provider.errorText = "Request DENIED by policy"
            compare(provider.state, "blocked")
            provider.errorText = "Network unreachable"
            compare(provider.state, "disconnected")
        }

        function test_detail_text_preserves_the_provider_reason() {
            provider.configured = true
            provider.available = false
            provider.unavailableReason = "Calendar service is not installed"
            compare(provider.detailText, "Calendar service is not installed")

            provider.available = true
            provider.errorText = "Parse error"
            compare(provider.detailText, "Parse error")
        }
    }
}

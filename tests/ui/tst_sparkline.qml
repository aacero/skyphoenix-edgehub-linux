import QtQuick
import QtTest
import "../../ui/qml" as App
import "../../ui/qml/widgets" as Wg

// Sparkline (ui/qml/widgets/Sparkline.qml) - a Canvas history chart. Canvas does
// not paint offscreen, so we assert the DRIVING PROPERTIES and the in-place
// mutation signature (the mechanism that decides when to repaint), never pixels.
Item {
    id: root
    width: 300; height: 160

    // File-root `theme` so the directly-instantiated Sparkline resolves the
    // `theme` global (its default `color: theme.accent`).
    property alias theme: _theme
    App.Theme { id: _theme }

    Item {
        id: host
        width: 240; height: 80
        Wg.Sparkline { id: sl; anchors.fill: parent }
    }

    TestCase {
        name: "Sparkline"
        when: windowShown

        function init() {
            host.width = 240
            host.height = 80
            sl.values = []
            sl.comparisonValues = []
            sl.fill = true
            sl.color = _theme.accent
            sl.chartStyle = "line"
            sl.scaleMode = "fixed"
            sl.minimumValue = 0
            sl.maximumValue = 1
            sl.includeZero = true
            sl.sampleIntervalSeconds = 2
            sl.valueFormatter = null
        }

        // ── Driving props ────────────────────────────────────────────────────
        function test_default_color_is_theme_accent() {
            verify(Qt.colorEqual(sl.color, _theme.accent),
                   "default sparkline colour is theme.accent")
        }

        function test_values_property_roundtrips() {
            var v = [0.1, 0.4, 0.9, 0.3]
            sl.values = v
            compare(sl.values.length, 4, "values array is stored")
            compare(sl.values[2], 0.9, "value content preserved")
        }

        function test_color_property_settable() {
            sl.color = "#FF0000"
            verify(Qt.colorEqual(sl.color, "#FF0000"), "colour override applied")
        }

        function test_fill_toggle() {
            sl.fill = false
            compare(sl.fill, false, "fill can be turned off")
            sl.fill = true
            compare(sl.fill, true, "fill can be turned on")
        }

        function test_fixed_percentage_domain_does_not_exaggerate_small_changes() {
            sl.values = [0.41, 0.42, 0.415]
            sl.scaleMode = "fixed"
            sl.minimumValue = 0
            sl.maximumValue = 1
            compare(sl.domain.min, 0)
            compare(sl.domain.max, 1)
            compare(sl.primaryStats.min, 0.41)
            compare(sl.primaryStats.max, 0.42)
        }

        function test_automatic_from_zero_is_padded_and_truthful() {
            sl.values = [990, 991, 992]
            sl.scaleMode = "auto"
            sl.includeZero = true
            compare(sl.domain.min, 0, "from-zero mode keeps zero on the scale")
            verify(sl.domain.max > 992, "the automatic ceiling leaves headroom above the peak")
        }

        function test_rolling_range_is_explicit_and_labelled() {
            sl.values = [990, 991, 992]
            sl.scaleMode = "auto"
            sl.includeZero = false
            verify(sl.domain.min > 0, "rolling range may magnify a narrow non-zero band")
            verify(sl.domain.min < 990 && sl.domain.max > 992,
                   "rolling range pads both ends rather than pinning peaks to an edge")
        }

        function test_smoothing_preserves_raw_samples_and_reduces_a_single_peak() {
            var raw = [0, 0, 1, 0, 0]
            sl.values = raw
            sl.smoothingSamples = 4
            var smooth = sl._smoothed(raw)
            compare(sl.values[2], 1, "the raw peak remains untouched")
            verify(smooth[2] > 0 && smooth[2] < 1,
                   "the emphasized trend damps the visual jump without replacing raw data")
            compare(smooth.length, raw.length)
        }

        function test_all_three_visual_styles_are_selectable() {
            var styles = ["smooth", "line", "bars"]
            for (var i = 0; i < styles.length; i++) {
                sl.chartStyle = styles[i]
                compare(sl.chartStyle, styles[i])
            }
        }

        function test_time_axis_reports_real_retained_span() {
            sl.values = [0.1, 0.2, 0.3, 0.4]
            sl.sampleIntervalSeconds = 2
            compare(sl._spanSeconds(), 6)
            compare(sl._formatDuration(sl._spanSeconds()), "6s ago")
            sl.sampleIntervalSeconds = 60
            compare(sl._formatDuration(sl._spanSeconds()), "3m ago")
        }

        function test_value_formatter_drives_axes_and_accessibility() {
            sl.values = [10, 20]
            sl.valueFormatter = function (value) { return value.toFixed(0) + " req/s" }
            compare(sl._formatValue(15), "15 req/s")
            verify(sl.accessibleSummary.indexOf("peak 20 req/s") >= 0)
        }

        // ── Layout / implicit size ───────────────────────────────────────────
        function test_lays_out_at_host_size() {
            compare(sl.width, host.width, "sparkline fills its host width")
            compare(sl.height, host.height, "sparkline fills its host height")
        }

        function test_axes_and_statistics_only_use_readable_room() {
            sl.values = [0.1, 0.4, 0.2, 0.7]
            compare(sl.axesVisible, false,
                    "a short spark strip does not squeeze in unreadable labels")
            host.width = 420
            host.height = 180
            tryCompare(sl, "axesVisible", true)
            tryCompare(sl, "statisticsVisible", true)
            verify(sl.axisFontPixelSize >= 16,
                   "axis and statistics labels meet the chart legibility floor")
        }

        // ── Signature (repaint driver) ───────────────────────────────────────
        function test_empty_values_signature_is_stable() {
            sl.values = []
            compare(sl._signature(), "0:", "an empty array has the empty-length signature")
        }

        function test_null_values_signature_is_degenerate() {
            sl.values = null
            compare(sl._signature(), "0", "a null values input is a degenerate signature (draws nothing)")
        }

        function test_single_point_does_not_throw_and_signs() {
            var threw = false
            try { sl.values = [0.5] } catch (e) { threw = true }
            verify(!threw, "a single-point series must not throw (n<2 guard)")
            compare(sl._signature(), "1:0.5,", "single-point signature")
        }

        function test_signature_tracks_content() {
            sl.values = [0.2, 0.8]
            compare(sl._signature(), "2:0.2,0.8,", "signature encodes length + samples")
            sl.values = [0.2, 0.8, 0.5]
            compare(sl._signature(), "3:0.2,0.8,0.5,", "signature follows a reassignment")
        }

        function test_nonfinite_samples_marked_in_signature() {
            sl.values = [0.5, NaN, 0.7]
            compare(sl._signature(), "3:0.5,x,0.7,",
                    "a non-finite sample is encoded as 'x' so it is skipped, not drawn")
        }

        // _sig is refreshed on reassignment (onValuesChanged), so the poll timer
        // sees no spurious change on the next tick.
        function test_sig_refreshed_on_reassignment() {
            sl.values = [0.1, 0.9]
            compare(sl._sig, sl._signature(), "_sig is synced when values are reassigned")
        }

        // In-place mutation (history.push) fires no NOTIFY; the 100ms poll picks it
        // up and re-syncs _sig. This is the core "live sparkline" mechanism.
        function test_in_place_mutation_detected_by_poll() {
            sl.values = [0.1, 0.2]
            sl.values.push(0.3)                 // mutate in place, no reassignment
            verify(sl._sig !== sl._signature(), "the mutated array is not yet reflected in _sig")
            tryVerify(function () { return sl._sig === sl._signature() }, 1000,
                      "the poll timer re-syncs _sig after an in-place push")
        }

        function test_comparison_mutation_is_also_detected() {
            sl.values = [0.1, 0.2]
            sl.comparisonValues = [0.2, 0.3]
            sl.comparisonValues.push(0.4)
            verify(sl._sig !== sl._paintSignature())
            tryVerify(function () { return sl._sig === sl._paintSignature() }, 1000)
        }

        function test_in_place_mutation_recomputes_domain_and_statistics() {
            sl.scaleMode = "auto"
            sl.includeZero = true
            sl.values = [10, 20]
            var oldCeiling = sl.domain.max
            sl.values.push(90)
            tryVerify(function () { return sl.primaryStats.max === 90 }, 1000)
            verify(sl.domain.max > oldCeiling,
                   "an in-place peak expands the numeric scale as well as repainting")
            verify(sl.accessibleSummary.indexOf("peak 90") >= 0,
                   "the accessible statistics follow the in-place sample")
        }

        // ── Out-of-range values are tolerated (Canvas clamps internally) ──────
        function test_out_of_range_values_do_not_throw() {
            var threw = false
            try { sl.values = [-3, 0.5, 42] } catch (e) { threw = true }
            verify(!threw, "out-of-range samples are accepted (clamped inside the Canvas Y())")
            compare(sl.values.length, 3, "values still stored")
        }

        // The 100ms poll timer MUST stop when the sparkline is off-screen - an
        // ungated one kept firing on every persisted preview widget and made the
        // whole Manager scroll stutter. Guards that regression.
        function _pollTimer() {
            var kids = sl.data || []
            for (var i = 0; i < kids.length; i++)
                if (kids[i] && kids[i].interval !== undefined && kids[i].repeat !== undefined
                    && typeof kids[i].running === "boolean")
                    return kids[i]
            return null
        }
        function test_poll_timer_gated_on_visibility() {
            var t = _pollTimer()
            verify(t, "found the sparkline poll timer")
            sl.visible = true
            tryVerify(function () { return t.running === true }, 1000)
            sl.visible = false
            compare(t.running, false, "the poll timer stops when the sparkline is hidden")
            sl.visible = true
            compare(t.running, true, "…and resumes when visible")
        }
    }
}

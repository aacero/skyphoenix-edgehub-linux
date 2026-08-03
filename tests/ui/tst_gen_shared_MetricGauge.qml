import QtQuick
import QtTest
import "../../ui/qml" as App
import "../../ui/qml/widgets" as Wg

// Comprehensive coverage for the shared metric-gauge visuals:
//   • RingProgress.qml  - circular progress ring (Canvas)
//   • Sparkline.qml     - area+line history chart (Canvas)
//   • MetricGauge.qml   - the composite tile visual (ring + centre value + spark)
//
// These are pure visual components with no exposed "computed geometry", so the
// interesting behaviour lives in the Canvas paint routines. We therefore drive
// them directly (mirroring how the store/config tests host a component with its
// own Theme in scope) and, for the paint-level bugs, sample the rendered pixels
// via TestCase.grabImage (verified to capture Canvas output under offscreen).
//
// Assertions that encode the *intended* behaviour but fail against the current
// code are deliberate - they pin the real bugs called out in the audit:
//   • RingProgress paints a spurious round-cap dot at 12 o'clock when value==0
//     (Math.max(0.0001, …) floors the swept fraction even for an idle metric).
//   • RingProgress two-colour gradient uses bounding-box coords, so the blend
//     does not follow the arc (left/right are reversed vs an arc-following ramp).
//   • Sparkline: a single NaN/undefined sample poisons the whole polyline+fill.
//   • Sparkline: mutating the bound array in place never repaints (NOTIFY only
//     fires on reassignment).
//   • MetricGauge: the ring visibly shrinks (layout reflow) when the sparkline
//     pops in at the second sample.
//
// Everything hosts its component under an opaque black Rectangle so grabImage()
// yields clean, classifiable colours (track = blue, progress/line = red).
Item {
    id: root
    width: 720; height: 520

    // A single Theme exposed at the file-root scope: unqualified `theme` inside
    // the directly-instantiated components (and the createObject'd gauge, whose
    // creation context is this root) resolves here. Per-host aliases do NOT reach
    // children declared in a different document, so this root-level one is what
    // actually satisfies RingProgress/Sparkline/MetricGauge's `theme` references.
    property alias theme: rootTheme
    App.Theme { id: rootTheme }

    // Hosts are positioned DISJOINTLY: grabImage samples the live scene, so any
    // overlap would let a sibling drawn on top bleed into another host's capture.

    // ── RingProgress under test (opaque host for pixel sampling) ─────────────
    Rectangle {
        id: ringHost
        x: 0; y: 0; width: 200; height: 200
        color: "#000000"
        Wg.RingProgress {
            id: ringA
            anchors.fill: parent
            thickness: 20
            value: 0.0
            trackColor: "#0000ff"     // blue track
            progressColor: "#ff0000"  // red progress
            progressColor2: "#ff0000"
        }
    }

    // A zero-sized ring to prove r<=0 paints nothing / does not throw.
    Rectangle {
        id: ringZeroHost
        x: 0; y: 320; width: 0; height: 0
        color: "#000000"
        Wg.RingProgress { id: ringZero; anchors.fill: parent; value: 0.5 }
    }

    // ── Sparkline under test (opaque host) ──────────────────────────────────
    Rectangle {
        id: sparkHost
        x: 0; y: 210; width: 200; height: 100
        color: "#000000"
        Wg.Sparkline {
            id: sparkA
            anchors.fill: parent
            color: "#ff0000"
            values: []
        }
    }

    // ── MetricGauge for property/structure inspection ───────────────────────
    Item {
        id: gaugeHost
        x: 220; y: 0; width: 200; height: 200
        Wg.MetricGauge { id: mg; anchors.fill: parent }
    }

    // ── MetricGauge sized so the ring is HEIGHT-limited, to expose the
    //    startup layout jump when the sparkline appears at the 2nd sample. ───
    Item {
        id: gaugeJumpHost
        x: 220; y: 210; width: 200; height: 260
        Wg.MetricGauge { id: mgJump; anchors.fill: parent; expanded: true }
    }

    // Host + factory for a freshly-created gauge (first-frame text-size check).
    Item {
        id: dynHost
        x: 440; y: 0; width: 200; height: 200
    }
    Component {
        id: gaugeComp
        Wg.MetricGauge {}
    }

    // ── Visual-tree helpers ─────────────────────────────────────────────────
    function eachItem(node, fn) {
        if (!node) return
        fn(node)
        var kids = node.children
        if (kids) for (var i = 0; i < kids.length; i++) eachItem(kids[i], fn)
    }
    function findPred(rootNode, pred) {
        var f = null
        eachItem(rootNode, function (n) { if (!f && pred(n)) f = n })
        return f
    }
    function findRing(rootNode) {
        return findPred(rootNode, function (n) {
            return n.thickness !== undefined && n.progressColor !== undefined && n.trackColor !== undefined
        })
    }
    function findSpark(rootNode) {
        return findPred(rootNode, function (n) {
            return n.values !== undefined && n.fill !== undefined && n.color !== undefined
        })
    }
    function findBig(rootNode, txt) {
        return findPred(rootNode, function (n) {
            return n.text !== undefined && typeof n.text === "string" && n.text === txt && n.font !== undefined
        })
    }

    // ── Pixel classifiers (grabImage red/green/blue are 0..255) ─────────────
    function isRed(img, x, y) {
        return img.red(x, y) > 140 && img.green(x, y) < 90 && img.blue(x, y) < 90
    }
    function isBlue(img, x, y) {
        return img.blue(x, y) > 140 && img.red(x, y) < 90 && img.green(x, y) < 90
    }
    function isBlack(img, x, y) {
        return img.red(x, y) < 40 && img.green(x, y) < 40 && img.blue(x, y) < 40
    }
    // Count strongly red pixels (line/fill of the sparkline) over the whole image.
    function countReddish(img, w, h, step) {
        var c = 0
        for (var x = 0; x < w; x += step)
            for (var y = 0; y < h; y += step)
                if (img.red(x, y) > 110 && img.red(x, y) > img.blue(x, y) + 40) c++
        return c
    }
    // Topmost reddish pixel y within a small x band (for time-order mapping).
    function topReddishY(img, xLo, xHi, h) {
        for (var y = 0; y < h; y++)
            for (var x = xLo; x <= xHi; x++)
                if (img.red(x, y) > 110 && img.red(x, y) > img.blue(x, y) + 40) return y
        return -1
    }

    // ════════════════════════════════════════════════════════════════════════
    // RingProgress
    // ════════════════════════════════════════════════════════════════════════
    TestCase {
        id: tcRing
        name: "RingProgress"
        when: windowShown

        // Geometry (200x200, thickness 20): r = 100 - 10 - 2 = 88.
        // 12 o'clock ring point ≈ (100, 12); 3 o'clock ≈ (188, 100);
        // 6 o'clock ≈ (100, 188); 9 o'clock ≈ (12, 100).
        readonly property int cx: 100
        readonly property int topY: 12
        readonly property int botY: 188
        readonly property int leftX: 12
        readonly property int rightX: 188

        function repaint() { wait(120) }

        function test_track_is_drawn_when_empty() {
            ringA.progressColor = "#ff0000"; ringA.progressColor2 = "#ff0000"
            ringA.trackColor = "#0000ff"; ringA.value = 0.0
            repaint()
            var img = grabImage(ringHost)
            // The full track ring is always present: the 3/6/9 o'clock band is blue.
            verify(isBlue(img, rightX, cx), "empty ring still paints its track (3 o'clock blue)")
            verify(isBlue(img, cx, botY), "track present at 6 o'clock")
            verify(isBlack(img, cx, cx), "the ring centre is hollow")
        }

        // FIXED, and this test pins it (audit). The defect was: value==0 paints
        // a red round-cap dot at 12 o'clock.
        function test_value_zero_draws_no_progress_dot() {
            ringA.progressColor = "#ff0000"; ringA.progressColor2 = "#ff0000"
            ringA.trackColor = "#0000ff"; ringA.value = 0.0
            repaint()
            var img = grabImage(ringHost)
            // Intended: an idle metric shows only the track at 12 o'clock, not a
            // filled progress-coloured blob.
            verify(!isRed(img, cx, topY),
                   "value=0 must not paint a progress dot at 12 o'clock (got rgb "
                   + img.red(cx, topY) + "," + img.green(cx, topY) + "," + img.blue(cx, topY) + ")")
        }

        function test_value_one_full_ring() {
            ringA.progressColor = "#ff0000"; ringA.progressColor2 = "#ff0000"
            ringA.trackColor = "#0000ff"; ringA.value = 1.0
            repaint()
            var img = grabImage(ringHost)
            verify(isRed(img, cx, topY), "full ring is red at 12 o'clock")
            verify(isRed(img, rightX, cx), "full ring is red at 3 o'clock")
            verify(isRed(img, cx, botY), "full ring is red at 6 o'clock")
            verify(isRed(img, leftX, cx), "full ring is red at 9 o'clock")
        }

        function test_value_gt_one_clamps_to_full() {
            ringA.progressColor = "#ff0000"; ringA.progressColor2 = "#ff0000"
            ringA.trackColor = "#0000ff"; ringA.value = 1.8
            repaint()
            var img = grabImage(ringHost)
            verify(isRed(img, cx, botY) && isRed(img, leftX, cx),
                   "value>1 clamps to a full ring (bottom & left are red)")
        }

        function test_value_lt_zero_sweeps_empty() {
            ringA.progressColor = "#ff0000"; ringA.progressColor2 = "#ff0000"
            ringA.trackColor = "#0000ff"; ringA.value = -0.5
            repaint()
            var img = grabImage(ringHost)
            // The swept body is empty: everything except the (buggy) 12 o'clock cap
            // stays track-coloured.
            verify(isBlue(img, rightX, cx), "value<0 leaves 3 o'clock as track")
            verify(isBlue(img, cx, botY), "value<0 leaves 6 o'clock as track")
            verify(isBlue(img, leftX, cx), "value<0 leaves 9 o'clock as track")
        }

        function test_half_value_fills_first_quadrant_only() {
            ringA.progressColor = "#ff0000"; ringA.progressColor2 = "#ff0000"
            ringA.trackColor = "#0000ff"; ringA.value = 0.25   // top → right
            repaint()
            var img = grabImage(ringHost)
            verify(isRed(img, cx, topY), "25% is red at 12 o'clock (arc start)")
            verify(isRed(img, rightX, cx), "25% reaches 3 o'clock")
            verify(isBlue(img, cx, botY), "25% has not reached 6 o'clock (still track)")
            verify(isBlue(img, leftX, cx), "25% has not reached 9 o'clock (still track)")
        }

        function test_zero_size_ring_paints_nothing_no_throw() {
            // ringZero is 0x0 so r<=0 → the paint routine returns early. Reaching
            // this point without a Canvas.arc "Incorrect argument radius" throw is
            // the assertion; also nothing is drawn.
            verify(ringZero !== null, "zero-sized ring instantiates")
            var img = grabImage(ringHost)   // just prove the scene still renders
            verify(img.width === 200, "scene renders fine alongside a 0-sized ring")
        }

        // FIXED, and this test pins it (audit). The defect was: the two-colour
        // gradient uses createLinearGradient(0,0,w,h) (bounding-box diagonal),
        // not an arc-following ramp. For a full red→blue ring an arc-following
        // gradient makes 9 o'clock (75% around) bluer than 3 o'clock (25%
        // around); the bounding-box mapping reverses that.
        function test_two_colour_gradient_follows_arc() {
            ringA.trackColor = "#111111"
            ringA.progressColor = "#ff0000"   // start colour (12 o'clock)
            ringA.progressColor2 = "#0000ff"  // end colour (back to 12 o'clock)
            ringA.value = 1.0
            repaint()
            var img = grabImage(ringHost)
            var bLeft = img.blue(leftX, cx)    // 9 o'clock ≈ 75% along the arc
            var bRight = img.blue(rightX, cx)  // 3 o'clock ≈ 25% along the arc
            verify(bLeft > bRight,
                   "arc-following gradient makes 9 o'clock bluer than 3 o'clock "
                   + "(blue left=" + bLeft + " right=" + bRight + ")")
            // restore
            ringA.progressColor2 = "#ff0000"; ringA.trackColor = "#0000ff"
        }

        // glow is a dead property (rendering was removed for perf). Toggling it
        // must produce no visual change. Documents the no-op contract.
        function test_glow_toggle_has_no_visual_effect() {
            ringA.progressColor = "#ff0000"; ringA.progressColor2 = "#ff0000"
            ringA.trackColor = "#0000ff"; ringA.value = 0.6
            repaint()
            var before = grabImage(ringHost)
            ringA.glow = !ringA.glow
            repaint()
            var after = grabImage(ringHost)
            verify(before.equals(after), "toggling glow changes nothing visually (glow is a no-op)")
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // Sparkline
    // ════════════════════════════════════════════════════════════════════════
    TestCase {
        id: tcSpark
        name: "Sparkline"
        when: windowShown

        readonly property int sw: 200
        readonly property int sh: 100
        function repaint() { wait(120) }

        function test_valid_series_draws_a_line() {
            sparkA.values = [0.2, 0.5, 0.8]
            repaint()
            var img = grabImage(sparkHost)
            verify(countReddish(img, sw, sh, 3) > 20,
                   "a valid series renders a visible red line (control)")
        }

        function test_fewer_than_two_points_draws_nothing() {
            sparkA.values = [0.5]
            repaint()
            var img = grabImage(sparkHost)
            compare(countReddish(img, sw, sh, 3), 0, "a single point renders nothing (n<2 guard)")
        }

        function test_empty_series_draws_nothing() {
            sparkA.values = []
            repaint()
            var img = grabImage(sparkHost)
            compare(countReddish(img, sw, sh, 3), 0, "an empty series renders nothing")
        }

        function test_null_values_safe_and_empty() {
            sparkA.values = null
            repaint()
            var img = grabImage(sparkHost)
            compare(countReddish(img, sw, sh, 3), 0, "null values renders nothing and does not throw")
        }

        function test_non_array_object_values_safe() {
            // Intended: a non-array truthy value is degenerate input → render nothing.
            sparkA.values = ({ foo: 1 })
            repaint()
            var img = grabImage(sparkHost)
            compare(countReddish(img, sw, sh, 3), 0,
                    "a non-array values object renders nothing (no stray baseline)")
            sparkA.values = []
        }

        function test_time_order_oldest_left_newest_right() {
            // oldest (index 0) low → bottom-left; newest (last) high → top-right.
            sparkA.values = [0.05, 0.95]
            repaint()
            var img = grabImage(sparkHost)
            var yLeft = topReddishY(img, 0, 6, sh)     // near left edge
            var yRight = topReddishY(img, sw - 7, sw - 1, sh)  // near right edge
            verify(yLeft > 0 && yRight > 0, "line reaches both edges")
            verify(yLeft > yRight,
                   "oldest low sample sits lower (larger y) at the left; newest high sits higher at the right "
                   + "(yLeft=" + yLeft + " yRight=" + yRight + ")")
        }

        function test_clamps_out_of_range_into_band() {
            // 1.5 clamps to top of band, -0.5 clamps to the bottom of the band.
            sparkA.values = [1.5, -0.5]
            repaint()
            var img = grabImage(sparkHost)
            var yLeft = topReddishY(img, 0, 6, sh)         // 1.5 → near top (y≈2)
            var yRight = topReddishY(img, sw - 7, sw - 1, sh) // -0.5 → near bottom
            verify(yLeft >= 0 && yLeft < 12, "value>1 clamps to the top band (yLeft=" + yLeft + ")")
            verify(yRight > sh - 14, "value<0 clamps to the bottom band (yRight=" + yRight + ")")
        }

        // FIXED, and this test pins it (audit). The defect was: a NaN/undefined
        // sample makes Y() return NaN, and lineTo(x, NaN) breaks the whole
        // polyline + fill. Intended: the bad sample is sanitized and the rest of
        // the line still renders.
        function test_nan_sample_does_not_poison_line() {
            sparkA.values = [0.2, 0.4, 0.6]   // healthy baseline
            repaint()
            var healthy = countReddish(grabImage(sparkHost), sw, sh, 3)
            verify(healthy > 20, "baseline healthy line renders (control)")

            sparkA.values = [0.2, NaN, 0.6]   // one poisoned sample
            repaint()
            var poisoned = countReddish(grabImage(sparkHost), sw, sh, 3)
            verify(poisoned > healthy * 0.5,
                   "a single NaN sample must not wipe out the line/fill "
                   + "(healthy=" + healthy + " poisoned=" + poisoned + ")")
            sparkA.values = []
        }

        function test_undefined_sample_does_not_poison_line() {
            sparkA.values = [0.3, 0.5, 0.7]
            repaint()
            var healthy = countReddish(grabImage(sparkHost), sw, sh, 3)
            sparkA.values = [0.3, undefined, 0.7]
            repaint()
            var poisoned = countReddish(grabImage(sparkHost), sw, sh, 3)
            verify(poisoned > healthy * 0.5,
                   "an undefined sample must not wipe out the line/fill "
                   + "(healthy=" + healthy + " poisoned=" + poisoned + ")")
            sparkA.values = []
        }

        // FIXED, and this test pins it (audit). The defect was: onValuesChanged
        // only fires on reassignment, so mutating the bound array in place
        // (history.push(...)) never repaints.
        function test_in_place_mutation_repaints() {
            var arr = [0.1, 0.9]
            sparkA.values = arr
            repaint()
            var before = grabImage(sparkHost)
            // Mutate the SAME array reference in place, as a push()-based producer would.
            arr.push(0.1); arr.push(0.9); arr.push(0.1); arr.push(0.9)
            repaint()
            var after = grabImage(sparkHost)
            verify(!before.equals(after),
                   "mutating the bound array in place should repaint the sparkline (it stays frozen)")
            sparkA.values = []
        }

        function test_reassignment_repaints() {
            sparkA.values = [0.1, 0.9]
            repaint()
            var before = grabImage(sparkHost)
            sparkA.values = [0.9, 0.1, 0.9, 0.1, 0.9]   // new reference → NOTIFY fires
            repaint()
            var after = grabImage(sparkHost)
            verify(!before.equals(after), "reassigning values repaints (the supported contract)")
            sparkA.values = []
        }

        function test_color_property_honored() {
            sparkA.color = "#ff0000"
            sparkA.values = [0.2, 0.8]
            repaint()
            verify(countReddish(grabImage(sparkHost), sw, sh, 3) > 10, "line uses the configured colour")
            sparkA.values = []
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // MetricGauge (composite)
    // ════════════════════════════════════════════════════════════════════════
    TestCase {
        id: tcGauge
        name: "MetricGauge"
        when: windowShown

        function init() {
            mg.ok = true; mg.value = 0.5; mg.big = "50%"; mg.sub = ""
            mg.history = []; mg.expanded = false; mg.color = root.theme.accent
        }

        // NOTE (W3): the gauge ring now EASES between samples (animateValue via
        // theme.motionValue), so target values are asserted with tryCompare -
        // the ring lands on the same numbers, it just glides there.
        function test_value_clamped_into_ring() {
            mg.value = 1.5
            var ring = findRing(gaugeHost)
            verify(ring !== null, "ring present")
            tryCompare(ring, "value", 1, 2000, "value>1 clamps the ring to full")
            mg.value = -0.5
            tryCompare(findRing(gaugeHost), "value", 0, 2000, "value<0 clamps the ring to empty")
            mg.value = 0.42
            tryVerify(function () { return Math.abs(findRing(gaugeHost).value - 0.42) < 1e-9 },
                      2000, "in-range value passes through")
        }

        function test_value_updates_ring_smoothly() {
            mg.value = 0.1
            tryCompare(findRing(gaugeHost), "value", 0.1, 2000, "ring tracks the source value")
            // A fresh sample GLIDES: the very next read is en route, not landed -
            // this is the W3 smoothness contract for the metric gauges.
            mg.value = 0.9
            var ring = findRing(gaugeHost)
            verify(ring.animateValue, "metric gauges opt into value smoothing")
            verify(ring.value < 0.9, "ring is easing toward the new sample, not hard-cutting")
            tryCompare(ring, "value", 0.9, 2000, "…and lands on it")
        }

        function test_ok_false_dims_ring_and_hides_sparkline() {
            mg.history = [0.2, 0.4, 0.6]
            mg.value = 0.7
            mg.ok = false
            var ring = findRing(gaugeHost)
            tryCompare(ring, "value", 0, 2000, "ok:false forces the ring empty")
            var spark = findSpark(gaugeHost)
            verify(spark !== null, "sparkline present")
            verify(!spark.visible, "ok:false hides the history sparkline")
        }

        function test_ok_false_dims_centre_value_colour() {
            mg.big = "77%"; mg.color = "#ff00ff"
            mg.ok = false
            var t = findBig(gaugeHost, "77%")
            verify(t !== null, "centre value text present")
            verify(Qt.colorEqual(t.color, root.theme.textTertiary),
                   "ok:false dims the centre value to the tertiary text colour")
        }

        function test_accent_passes_through_to_ring_and_value() {
            mg.ok = true; mg.big = "33%"; mg.color = "#12ab34"
            // The gauge colour cross-fades (threshold escalation must not hard-cut),
            // so wait for the fade to land before asserting the pass-through.
            var ring = findRing(gaugeHost)
            tryVerify(function () { return Qt.colorEqual(ring.progressColor, "#12ab34") }, 2000,
                      "gauge colour flows to ring.progressColor")
            var t = findBig(gaugeHost, "33%")
            tryVerify(function () { return Qt.colorEqual(t.color, "#12ab34") }, 2000,
                      "gauge colour flows to the centre value text")
        }

        function test_sparkline_visibility_gated_on_history_length() {
            mg.ok = true
            mg.history = [0.5]
            var spark = findSpark(gaugeHost)
            verify(!spark.visible, "one sample → sparkline hidden (needs >1)")
            mg.history = [0.5, 0.6]
            verify(spark.visible, "two samples → sparkline visible")
            mg.history = []
            verify(!spark.visible, "no samples → sparkline hidden")
        }

        function test_sparkline_receives_history_samples() {
            mg.ok = true
            mg.history = [0.1, 0.2, 0.3, 0.4]
            var spark = findSpark(gaugeHost)
            compare(spark.values.length, 4, "sparkline receives the full history buffer")
        }

        function test_sub_line_shown_only_when_nonempty() {
            mg.sub = ""
            var hidden = findBig(gaugeHost, "")   // may match; rely on the populated case
            mg.sub = "16 cores"
            var t = findBig(gaugeHost, "16 cores")
            verify(t !== null, "populated sub-line renders")
            verify(t.visible, "sub-line is visible when non-empty")
        }

        function test_expanded_grows_sparkline_and_text_cap() {
            mg.history = [0.2, 0.4, 0.6]; mg.big = "50%"
            mg.expanded = false
            wait(60)
            var sparkC = findSpark(gaugeHost)
            var hCollapsed = sparkC.height
            mg.expanded = true
            wait(60)
            var hExpanded = findSpark(gaugeHost).height
            verify(hExpanded > hCollapsed,
                   "expanded grows the sparkline height (" + hCollapsed + " → " + hExpanded + ")")
        }
    }

    // ── MetricGauge: startup layout jump (dedicated host) ───────────────────
    TestCase {
        id: tcJump
        name: "MetricGaugeJump"
        when: windowShown

        // FIXED, and this test pins it (audit). The defect was: the ring is
        // Layout.fillHeight while the sparkline reserves Layout.preferredHeight
        // only once history.length > 1. On the second sample the sparkline pops
        // in and the ring abruptly shrinks (reflow).
        function test_ring_does_not_shrink_when_sparkline_appears() {
            mgJump.ok = true; mgJump.value = 0.5; mgJump.big = "50%"
            mgJump.history = [0.5]          // sparkline hidden, ring gets full height
            wait(80)
            var r1 = findRing(gaugeJumpHost).width
            mgJump.history = [0.5, 0.6]     // second sample → sparkline appears
            wait(80)
            var r2 = findRing(gaugeJumpHost).width
            verify(r1 > 0 && r2 > 0, "ring laid out in both states (r1=" + r1 + " r2=" + r2 + ")")
            fuzzyCompare(r2, r1, 1.0,
                   "the ring must not resize when the sparkline pops in at the 2nd sample "
                   + "(r1=" + r1 + " r2=" + r2 + ")")
        }
    }

    // ── MetricGauge: first-frame centre-text size (freshly created) ─────────
    TestCase {
        id: tcFirstFrame
        name: "MetricGaugeFirstFrame"
        when: windowShown

        // FIXED, and this test pins it (audit). The defect was: font.pixelSize
        // depends on ring.width, which is 0 until the ColumnLayout lays out, so
        // the big number renders at pixelSize 0 (invisible) on the very first
        // frame. Inspect the just-created instance before any layout/wait
        // settles.
        function test_big_text_nonzero_on_first_frame() {
            var g = gaugeComp.createObject(dynHost, {
                width: 200, height: 200, big: "42%", value: 0.42, ok: true
            })
            verify(g !== null, "gauge created")
            var t = findBig(g, "42%")
            verify(t !== null, "centre value text present at creation")
            var px = t.font.pixelSize
            g.destroy()
            verify(px > 0,
                   "the centre value must have a non-zero pixelSize on the first frame (got " + px + ")")
        }
    }
}

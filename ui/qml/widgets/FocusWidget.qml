import QtQuick
import QtQuick.Layouts

// Focus / Pomodoro - ADHD-friendly, feature-complete, fully persistent.
//
// All timer state lives in the store (phase, running, an absolute end-epoch,
// paused-remaining, sessions-done-today), so the tile and the expanded view are
// the SAME timer, a running session survives expand/collapse, and it resumes
// after a restart. Uses an absolute end time (not a decrementing counter) so it
// stays correct across backgrounding.
//
// Sizing (W1 wave 3): layout keys off the injected `sizeClass`. This widget
// declares only `1x1` and `1x1.5` because the ring needs a roughly SQUARE cell
// and a Pomodoro tile you cannot start is not a Pomodoro tile - every half size
// is wide-short or narrow-tall in one orientation, which collides the ring with
// the ≥52px control row. The two it does declare now earn their box:
//   • 1x1 (compact, both orientations) - the ring in a cell that STOPS above the
//     control row instead of running under it, with the clock sized from the
//     ring (it used to cap at 34px and float in a 819px box).
//   • 1x1.5 tall (portrait) - the same ring, plus the momentum readout that was
//     locked in the overlay (sessions/goal, dots, points) + the nudge, + "+5".
//   • 1x1.5 wide (landscape) - ring BESIDE that column, so 1269px of width is
//     content rather than air either side of a centred ring.
//   • full (overlay) - unchanged: the preset switcher and the 4-button row are
//     genuinely modal and stay there.
//
// Three things stay keyed off the MODE rather than the room, and all are correct:
// `showHeader: expanded` (chrome-header CONTENT, not a dimension), and the
// tile/overlay VIEW split (`visible: !expanded` / `visible: expanded`) - the
// overlay is a different view (preset switcher + big ring + a 4-button transport
// row), not the tile at a larger scale, so room does not turn one into the other.
// The one SIZE that was wearing the mode's clothes was the celebration banner -
// see celebratePx.
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""
    property bool foreground: true
    property var notificationBridge:
        (typeof notifications !== "undefined" ? notifications : null)

    title: "Focus Timer"; iconName: "focus"; accentColor: theme.catProductivity
    showHeader: expanded

    readonly property var presets: ({
        "classic": { work: 25, short: 5, long: 15, every: 4, label: "Classic" },
        "deep":    { work: 50, short: 10, long: 20, every: 3, label: "Deep" },
        "sprint":  { work: 15, short: 3, long: 10, every: 4, label: "Sprint" }
    })
    readonly property var nudges: [
        "One small step at a time.", "You've got this - stay with it.",
        "Progress over perfection.", "Just focus on this one thing.",
        "Breathe. Reset. Continue.", "Future you says thanks."
    ]

    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    property string presetName: cfg.preset || "classic"
    // Custom-preset durations (minutes); only used when presetName === "custom".
    readonly property int workMin: cfg.workMin !== undefined ? cfg.workMin : 25
    readonly property int breakMin: cfg.breakMin !== undefined ? cfg.breakMin : 5
    // Existing custom presets had one break length. Preserve that value until a
    // separate long break is explicitly configured.
    readonly property int longBreakMin: cfg.longBreakMin !== undefined ? cfg.longBreakMin : breakMin
    readonly property int longBreakEvery: cfg.longBreakEvery !== undefined ? cfg.longBreakEvery : 4
    readonly property bool autoStartBreak: cfg.autoStartBreak !== undefined ? cfg.autoStartBreak : false
    readonly property bool autoStartFocus: cfg.autoStartFocus !== undefined ? cfg.autoStartFocus : false
    readonly property bool notifyWhenHidden: cfg.notifyWhenHidden !== undefined
                                               ? cfg.notifyWhenHidden : false

    // ADHD-friendly "momentum" options (all honoured below).
    readonly property string behaviorProfile: cfg.behaviorProfile || "custom"
    readonly property int dailyGoal: cfg.dailyGoal !== undefined ? cfg.dailyGoal : 4
    readonly property bool celebrate: behaviorProfile === "calm" ? false
        : behaviorProfile === "momentum" ? true : (cfg.celebrate !== undefined ? cfg.celebrate : true)
    readonly property bool rewardPoints: behaviorProfile === "calm" ? false
        : behaviorProfile === "momentum" ? true : (cfg.rewardPoints !== undefined ? cfg.rewardPoints : true)
    readonly property bool showNudges: behaviorProfile === "calm" ? false
        : behaviorProfile === "momentum" ? true : (cfg.showNudges !== undefined ? cfg.showNudges : true)
    readonly property bool breakSuggestions: cfg.breakSuggestions !== undefined ? cfg.breakSuggestions : true
    readonly property bool celebrationMotionEnabled: !theme.effectiveReduceMotion
    readonly property int points: cfg.points || 0
    readonly property var breakIdeas: [
        "Stand up & stretch", "Drink some water", "Look 20ft away for 20s",
        "Roll your shoulders", "Take 5 slow breaths", "Quick walk around"
    ]
    property var p: presetName === "custom"
        ? ({ work: workMin, short: breakMin, long: longBreakMin, every: longBreakEvery, label: "Custom" })
        : (presets[presetName] || presets["classic"])
    property string phase: cfg.phase || "work"     // work | short | long
    property bool running: cfg.running || false
    // Ticks forward (each driving second) so `todayKey` / `completedWork` roll
    // over at midnight on this 24/7 device instead of freezing on the boot day.
    property int tick: 0
    readonly property string todayKey: { tick; return today() }
    property int completedWork: cfg.day === todayKey ? (cfg.doneToday || 0) : 0

    // A local pulse ticks each second (when this instance drives) to refresh
    // `remaining`, which is derived from the persisted absolute end time.
    property int pulse: 0
    property int phaseTotal: phaseSeconds(phase)
    // Ring fill fraction (elapsed). Denominator grows if "+5" pushes remaining
    // past a phase's nominal length, so the ring never underflows past 0.
    readonly property real ringValue: 1 - remaining / Math.max(1, phaseTotal, remaining)
    property int remaining: {
        pulse
        if (running && cfg.endEpoch)
            return Math.max(0, Math.round((cfg.endEpoch - Date.now()) / 1000))
        return cfg.pausedRemaining !== undefined ? cfg.pausedRemaining : phaseTotal
    }

    function today() { return Qt.formatDate(new Date(), "yyyy-MM-dd") }
    function phaseSeconds(ph) { return (ph === "work" ? p.work : ph === "short" ? p.short : p.long) * 60 }
    // Work phase follows the widget's effective accent (per-instance override
    // reaches the highlight content, not just the chrome header); breaks keep
    // their semantic colours.
    function phaseColor() { return phase === "work" ? w.effAccent : phase === "short" ? theme.success : theme.accent }
    function phaseLabel() { return phase === "work" ? "Focus" : phase === "short" ? "Short Break" : "Long Break" }
    function nextPhaseLabel() {
        if (phase !== "work") return "Focus"
        return (completedWork + 1) % p.every === 0 ? "Long break" : "Short break"
    }
    function cyclePosition() {
        if (phase === "work") return completedWork % p.every + 1
        return Math.max(1, completedWork % p.every || p.every)
    }
    function finishHint() {
        if (running && cfg.endEpoch)
            return "Ends " + Qt.formatTime(new Date(cfg.endEpoch), "HH:mm")
        return Math.max(1, Math.ceil(remaining / 60)) + " min planned"
    }
    function fmt(s) { var m = Math.floor(s / 60), sec = s % 60; return String(m).padStart(2, '0') + ":" + String(sec).padStart(2, '0') }

    function save(obj) { if (store) store.patchSettings(instanceId, obj) }

    function start() { save({ running: true, endEpoch: Date.now() + remaining * 1000 }) }
    function pause() { save({ running: false, pausedRemaining: remaining }) }
    function toggle() { running ? pause() : start() }
    function addFive() {
        // Running without a persisted endEpoch (e.g. state pushed mid-flight)
        // would make `cfg.endEpoch + 300000` NaN - rebuild it from `remaining`.
        if (running) save({ endEpoch: (cfg.endEpoch || Date.now() + remaining * 1000) + 300000 })
        else save({ pausedRemaining: remaining + 300 })
    }
    function loadPhase(ph, run) {
        var secs = phaseSeconds(ph)
        save({ phase: ph, pausedRemaining: secs, running: run, endEpoch: run ? Date.now() + secs * 1000 : 0 })
    }
    // Reset restarts the timer for the current phase; it must NOT wipe today's
    // session count / points - that's the day's earned momentum, not timer state.
    function reset() { loadPhase("work", false) }
    // Switching preset re-seeds the timer to the new work length but likewise
    // preserves today's count (changing technique mid-day shouldn't erase it).
    function applyPreset(name) { save({ preset: name }); loadPhase("work", false) }
    function advance(natural) {
        var cw = completedWork
        var nextPhase, done = cw, run
        var pts = points
        if (phase === "work") {
            // Only a timer-driven completion (natural) counts as a finished
            // session and earns rewards; a manual Skip must never count, reward,
            // or celebrate (the `natural` flag was previously dead).
            if (natural) {
                done = cw + 1
                // Reward: points per session (+ a ONE-TIME bonus for the session
                // that reaches the daily goal), and a celebration - a small, honest
                // dopamine hit. The goal bonus/celebration fires only on the session
                // that CROSSES the goal (done === dailyGoal), not on every session
                // at/after it; later sessions get the ordinary per-session reward.
                var hitGoal = (done === dailyGoal)
                if (rewardPoints) pts += 10 + (hitGoal ? 50 : 0)
                if (celebrate) celebrateNow(hitGoal ? "🎯 Goal reached!  +50" : "🎉 Nice! Session done")
            }
            nextPhase = (done > 0 && done % p.every === 0) ? "long" : "short"
            // Roll straight into the break only when the user opted in;
            // otherwise pause and wait for them to start it.
            run = autoStartBreak
        } else {
            nextPhase = "work"
            run = autoStartFocus
        }
        if (natural) notifyCompletion(phase, nextPhase)
        var secs = phaseSeconds(nextPhase)
        save({ phase: nextPhase, doneToday: done, day: today(), points: pts,
               running: run, endEpoch: run ? Date.now() + secs * 1000 : 0, pausedRemaining: secs })
        flash.restart()
    }

    // Celebration pop (message scales/fades in over a colour flash).
    property string celebrateMsg: ""
    function celebrateNow(msg) { celebrateMsg = msg; celebrateAnim.restart(); flash.restart() }
    function skip() { advance(false) }
    property bool skipArmed: false
    function requestSkip() {
        if (skipArmed) {
            skipArmed = false
            skipArmTimeout.stop()
            skip()
            return
        }
        skipArmed = true
        skipArmTimeout.restart()
    }
    function notifyCompletion(completedPhase, nextPhase) {
        if (!notifyWhenHidden || foreground || !notificationBridge
                || !notificationBridge.send)
            return false
        var summary = completedPhase === "work"
                ? "Focus session complete" : "Break complete"
        var body = nextPhase === "work"
                ? "Ready for another focus session."
                : (nextPhase === "long" ? "Your long break is ready."
                                        : "Your short break is ready.")
        return notificationBridge.send(summary, body)
    }
    Timer {
        id: skipArmTimeout
        interval: 3000
        onTriggered: w.skipArmed = false
    }
    onPhaseChanged: {
        skipArmed = false
        skipArmTimeout.stop()
    }

    // Keep the idle clock in sync with the chosen preset / custom lengths: when
    // the timer is NOT running, changing the preset (via the widget's segmented)
    // or the custom minutes (via the config panel) resets the shown time + ring to
    // the new phase length. Guarded so it's a no-op when already correct, and
    // deferred to avoid a binding loop with `p`.
    onPChanged: Qt.callLater(_syncIdleDuration)
    // Liveness flag for the deferred callback below. A tile that is replaced
    // (apply-preset, reset-layout, page rebuild) can be torn down between the
    // Qt.callLater() and its invocation, and the callback then runs against a
    // half-destroyed object: "Property 'phaseSeconds' ... is not a function
    // (exception occurred during delayed function evaluation)". Harmless in
    // effect - the save it was going to do is moot for a dying tile - but it is
    // a real uncaught exception, and now that widgets actually load in the test
    // suites the diagnostics gate fails on it.
    property bool _alive: true
    Component.onDestruction: _alive = false
    function _syncIdleDuration() {
        if (!_alive || running) return
        var secs = phaseSeconds(phase)
        if (cfg.pausedRemaining !== secs || cfg.endEpoch)
            save({ pausedRemaining: secs, endEpoch: 0 })
    }

    // Only the active (visible) instance drives completion, so phases never
    // double-advance. `remaining` itself is derived from endEpoch everywhere.
    Timer {
        interval: 1000; repeat: true; running: w.active
        onTriggered: {
            w.pulse++
            w.tick++   // rolls todayKey / completedWork over at midnight
            if (w.running && w.remaining <= 0) w.advance(true)
        }
    }

    Rectangle {
        anchors.fill: parent; radius: theme.radiusLg; color: w.phaseColor(); opacity: 0; z: 5
        SequentialAnimation on opacity {
            id: flash; running: false
            NumberAnimation { to: w.celebrationMotionEnabled ? 0.35 : 0; duration: theme.motionFast }
            NumberAnimation { to: 0.0; duration: theme.motionSlow }
        }
    }
    // Celebration message - pops in on a completed session (dopamine kick).
    //
    // The banner spans the whole CARD, so the card is what sizes it. `expanded ?
    // 34 : 18` asked the wrong question and got both answers wrong: a 696x819
    // baseline tile has more room than the overlay's live-preview pane and still
    // popped at 18, while the overlay kept its 34 after W5 shrank that pane to 38%
    // of the width in landscape (~941x456 there, ~656x980 stacked in portrait).
    // Both axes bind - a wide-but-short pane must not overreach - and 34 stays the
    // designed ceiling, which the tile classes this type declares (1x1, 1x1.5) all
    // reach. HorizontalFit + minimumPixelSize keep a long message inside the card.
    readonly property real celebratePx: Math.max(theme.fontMinimum, Math.min(width * 0.055,
                                                              height * 0.065, 34))
    Text {
        id: celebrateLabel; anchors.centerIn: parent; z: 20
        width: parent.width * 0.92
        text: w.celebrateMsg; opacity: 0
        font.pixelSize: Math.round(w.celebratePx); font.bold: true; font.family: theme.fontDisplay
        fontSizeMode: Text.HorizontalFit; minimumPixelSize: theme.fontMinimum
        color: w.phaseColor(); horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
        SequentialAnimation {
            id: celebrateAnim; running: false
            PropertyAction { target: celebrateLabel; property: "scale"; value: w.celebrationMotionEnabled ? 0.6 : 1 }
            ParallelAnimation {
                NumberAnimation { target: celebrateLabel; property: "opacity"; from: 0; to: 1; duration: theme.motionAdd }
                NumberAnimation { target: celebrateLabel; property: "scale"; to: w.celebrationMotionEnabled ? 1.12 : 1
                    duration: theme.motionPage; easing.type: w.celebrationMotionEnabled ? Easing.OutBack : Easing.Linear }
            }
            PauseAnimation { duration: 950 }
            NumberAnimation { target: celebrateLabel; property: "opacity"; to: 0; duration: theme.motionSlow }
        }
    }

    // ── Per-size layout (sizeClass injected by Dashboard) ────────────────────
    readonly property bool horiz: sizeClass === "wide"
    // `large` is unreachable for this type's declared sizes (1x2/1x3 are not
    // offered); treated as tall so a forced class degrades sanely rather than
    // falling through to the compact branch.
    readonly property bool tallish: sizeClass === "tall" || sizeClass === "large"
    // The momentum readout (sessions/goal, dots, points) and the nudge are the
    // overlay's content; 1x1.5 has the room to earn them for the TILE. 1x1 does
    // not - a ring big enough to read plus a real 52px control row fills it, and
    // squeezing a stats block in would just shrink the clock.
    readonly property bool showMomentum: tallish || horiz

    Item {
        anchors.fill: parent; visible: !w.expanded

        GridLayout {
            anchors.fill: parent
            // Wide reflows the SAME children into two columns - the ring keeps a
            // square cell and the stats/controls column takes the width that a
            // centred ring used to waste.
            columns: w.horiz ? 2 : 1
            rowSpacing: theme.spacingSm
            columnSpacing: theme.spacingLg

            // Tall only: split the slack ABOVE and BELOW the group so the whole
            // thing sits centred. A circle in a 696px-wide box tops out at ~600px
            // however tall the box gets, so 1x1.5 portrait has ~450px it cannot
            // spend on the ring. Letting the ring cell absorb it instead (the
            // fillHeight path) centres the RING and strands the stats at the
            // bottom edge, a third of a screen away from what they describe.
            // These spacers are invisible in the other classes, and an invisible
            // item is skipped by GridLayout - so they never consume a cell in the
            // 2-column (wide) arrangement.
            Item { Layout.fillWidth: true; Layout.fillHeight: true; visible: w.tallish }

            // Ring + the clock inside it. The cell is a real layout cell, so the
            // ring STOPS above the control row instead of being centred in the
            // whole box with the buttons anchored over its bottom arc.
            Item {
                id: ringCell
                Layout.fillWidth: !w.horiz
                // Tall hands the slack to the spacers, so the cell shrink-wraps
                // to a square instead of stretching into a void.
                Layout.fillHeight: !w.tallish
                Layout.preferredHeight: w.tallish ? Math.round(w.width * 0.9) : -1
                // Side-by-side: a square cell sized by the box height, capped so
                // the stats column keeps the majority of the width.
                Layout.preferredWidth: w.horiz ? Math.round(Math.min(w.height, w.width * 0.42)) : -1
                readonly property real d: Math.max(1, Math.min(width, height) * 0.9)
                // Text must fit the ring's INNER diameter, not the cell.
                readonly property real inner: Math.max(40, ringCell.d * 0.62)
                RingProgress {
                    anchors.centerIn: parent
                    width: ringCell.d; height: width
                    value: w.ringValue
                    progressColor: w.phaseColor(); progressColor2: w.phaseColor()
                }
                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 0
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        // Sized from the RING, not a magic 34px cap: the old cap
                        // left a 34px clock floating inside a 626px ring.
                        // preferredWidth (not a bare maximumWidth - Qt 6.7 ignores
                        // that) so HorizontalFit has a width to fit against.
                        Layout.preferredWidth: ringCell.inner
                        horizontalAlignment: Text.AlignHCenter
                        text: w.fmt(w.remaining)
                        font.pixelSize: Math.max(18, Math.min(ringCell.d * 0.28, 110))
                        fontSizeMode: Text.HorizontalFit; minimumPixelSize: theme.fontMinimum
                        elide: Text.ElideRight
                        font.family: theme.fontMono; font.bold: true
                        color: w.running ? w.phaseColor() : theme.textPrimary
                    }
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: ringCell.inner
                        horizontalAlignment: Text.AlignHCenter
                        text: w.phaseLabel(); elide: Text.ElideRight
                        fontSizeMode: Text.HorizontalFit; minimumPixelSize: theme.fontMinimum
                        font.pixelSize: Math.max(theme.fontMinimum,
                                                 Math.min(ringCell.d * 0.085,
                                                          Math.round(26 * theme.textScaleEff)))
                        font.bold: true
                        color: w.phaseColor()
                    }
                }
            }

            // Stats + controls. Below the ring when stacked, beside it when wide.
            //
            // Two Qt Layouts traps are load-bearing here (both caught on the real
            // panel, both pinned by tests):
            //  • No `Layout.alignment` on THIS column: alignment beats fill on
            //    that axis, so it would collapse to its implicit width and hug
            //    the left edge, dragging the centred control row with it. The
            //    wide projection centres vertically with the two spacers instead.
            //  • `Layout.maximumWidth` must be released explicitly: a nested
            //    Layout derives its implicit maximumWidth from its children, and
            //    the control row's own `Layout.alignment` pins that row's maximum
            //    to its implicit width. That maximum propagates UP and silently
            //    caps this column at ~164px even with fillWidth set - so the
            //    buttons landed under the ring's left edge, not its centre.
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: w.horiz
                Layout.maximumWidth: Number.POSITIVE_INFINITY
                spacing: theme.spacingSm

                // Centre the column against the ring when side-by-side.
                Item { Layout.fillHeight: true; visible: w.horiz }

                // Momentum - earned by 1x1.5, not shown at 1x1.
                ColumnLayout {
                    visible: w.showMomentum
                    Layout.fillWidth: true
                    spacing: theme.spacingXs

                    // A larger Focus tile now earns a genuine session runway,
                    // not just a larger timer. It answers the three questions a
                    // glance at a Pomodoro should answer: what is happening now,
                    // what follows, and where this session sits in the cycle.
                    Rectangle {
                        objectName: "focusRunway"
                        Layout.fillWidth: true
                        Layout.preferredHeight: 78
                        radius: theme.radiusMd
                        color: Qt.rgba(w.phaseColor().r, w.phaseColor().g,
                                       w.phaseColor().b, 0.09)
                        border.width: 1
                        border.color: Qt.rgba(w.phaseColor().r, w.phaseColor().g,
                                              w.phaseColor().b, 0.28)

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: theme.spacingMd
                            anchors.rightMargin: theme.spacingMd
                            spacing: theme.spacingSm

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Text { text: "NOW"; color: w.phaseColor(); font.pixelSize: theme.fontLabel
                                    font.bold: true; font.letterSpacing: 1.2 }
                                Text { text: w.phaseLabel(); color: theme.textPrimary
                                    font.pixelSize: theme.fontLabel; font.bold: true; elide: Text.ElideRight
                                    Layout.fillWidth: true }
                                Text { text: w.finishHint(); color: theme.textPrimary; opacity: 0.78
                                    font.pixelSize: theme.fontLabel; elide: Text.ElideRight; Layout.fillWidth: true }
                            }

                            Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true
                                Layout.topMargin: 14; Layout.bottomMargin: 14; color: theme.cardBorder }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Text { text: "NEXT"; color: w.phaseColor(); font.pixelSize: theme.fontLabel
                                    font.bold: true; font.letterSpacing: 1.2 }
                                Text { text: w.nextPhaseLabel(); color: theme.textPrimary
                                    font.pixelSize: theme.fontLabel; font.bold: true; elide: Text.ElideRight
                                    Layout.fillWidth: true }
                                Text { text: w.phase === "work" ? "Recovery" : "Deep work"
                                    color: theme.textPrimary; opacity: 0.78; font.pixelSize: theme.fontLabel
                                    elide: Text.ElideRight; Layout.fillWidth: true }
                            }

                            Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true
                                Layout.topMargin: 14; Layout.bottomMargin: 14; color: theme.cardBorder }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Text { text: "CYCLE"; color: w.phaseColor(); font.pixelSize: theme.fontLabel
                                    font.bold: true; font.letterSpacing: 1.2 }
                                Text { text: "Session " + w.cyclePosition() + " / " + w.p.every
                                    color: theme.textPrimary; font.pixelSize: theme.fontLabel; font.bold: true
                                    elide: Text.ElideRight; Layout.fillWidth: true }
                                Text { text: w.p.label + " rhythm"; color: theme.textPrimary; opacity: 0.78
                                    font.pixelSize: theme.fontLabel; elide: Text.ElideRight; Layout.fillWidth: true }
                            }
                        }
                    }

                    RowLayout {
                        Layout.alignment: Qt.AlignHCenter
                        spacing: theme.spacingSm
                        Text { text: w.completedWork + " / " + w.dailyGoal + " today"
                            font.pixelSize: theme.fontLabel
                            color: w.completedWork >= w.dailyGoal ? theme.success : theme.textPrimary
                            font.bold: w.completedWork >= w.dailyGoal }
                        Text { visible: w.rewardPoints; text: "·  ⭐ " + w.points + " pts"
                            font.pixelSize: theme.fontLabel; color: theme.textPrimary }
                    }
                    // Goal progress dots - the glanceable streak bar. The model is
                    // an int derived from CONFIG, so a tick never rebuilds it.
                    RowLayout {
                        Layout.alignment: Qt.AlignHCenter
                        spacing: 4
                        Repeater {
                            model: Math.min(w.dailyGoal, 8)
                            delegate: Rectangle {
                                required property int index
                                width: 8; height: 8; radius: 4
                                color: index < w.completedWork ? theme.success : theme.cardBorder
                            }
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: (w.phase === "work" && w.showNudges)
                                 || (w.phase !== "work" && w.breakSuggestions)
                        horizontalAlignment: Text.AlignHCenter
                        text: w.phase === "work"
                              ? w.nudges[w.completedWork % w.nudges.length]
                              : "Break idea: " + w.breakIdeas[w.completedWork % w.breakIdeas.length]
                        font.pixelSize: theme.fontLabel; font.italic: true
                        color: theme.textPrimary; opacity: 0.78; elide: Text.ElideRight
                    }
                }

                // Controls - operate the timer straight from the tile (no expand).
                // The PillButton default height (theme.touchSecondary) stands: the
                // old `implicitHeight: 36` override undercut the touch minimum.
                RowLayout {
                    objectName: "focusTileControls"
                    Layout.alignment: Qt.AlignHCenter
                    spacing: theme.spacingSm
                    PillButton {
                        label: w.running ? "Pause" : "Start"; glyph: w.running ? "⏸" : "▶"
                        primary: true; tint: w.phaseColor(); onClicked: w.toggle()
                    }
                    // "+5" is the control a running timer actually reaches for; only
                    // 1x1.5 has the width for a third button without shrinking one.
                    PillButton {
                        visible: w.showMomentum
                        label: "+5"; glyph: "＋"; tint: w.phaseColor(); onClicked: w.addFive()
                    }
                    PillButton {
                        label: w.skipArmed ? "Confirm" : "Skip"
                        glyph: "⏭"
                        tint: w.skipArmed ? theme.warning : theme.textPrimary
                        onClicked: w.requestSkip()
                    }
                }
                Item { Layout.fillHeight: true; visible: w.horiz }
            }

            Item { Layout.fillWidth: true; Layout.fillHeight: true; visible: w.tallish }
        }
    }

    // ── Expanded ──
    ColumnLayout {
        anchors.fill: parent; visible: w.expanded; spacing: theme.spacingMd

        SegmentedControl {
            Layout.fillWidth: true; Layout.preferredHeight: theme.touchTertiary
            tint: w.phaseColor()
            options: [ { label: "Classic", value: "classic" }, { label: "Deep", value: "deep" }, { label: "Sprint", value: "sprint" }, { label: "Custom", value: "custom" } ]
            currentValue: w.presetName
            onSelected: function (v) { w.applyPreset(v) }
        }
        Item {
            Layout.fillWidth: true; Layout.fillHeight: true
            RingProgress {
                id: bigRing; anchors.centerIn: parent
                width: Math.min(parent.width, parent.height); height: width
                value: w.ringValue
                progressColor: w.phaseColor(); progressColor2: w.phaseColor()
            }
            ColumnLayout {
                anchors.centerIn: parent; spacing: 2
                Text { Layout.alignment: Qt.AlignHCenter; text: w.phaseLabel().toUpperCase()
                    font.pixelSize: theme.fontLabel; font.letterSpacing: 2; color: w.phaseColor() }
                Text { Layout.alignment: Qt.AlignHCenter; text: w.fmt(w.remaining)
                    font.pixelSize: Math.min(bigRing.width * 0.30, 92); font.family: theme.fontMono
                    font.bold: true; color: theme.textPrimary }
                RowLayout {
                    Layout.alignment: Qt.AlignHCenter; spacing: theme.spacingSm
                    Text { text: w.completedWork + " / " + w.dailyGoal + " today"
                        font.pixelSize: theme.fontLabel; color: w.completedWork >= w.dailyGoal ? theme.success : theme.textPrimary
                        font.bold: w.completedWork >= w.dailyGoal }
                    Text { visible: w.rewardPoints; text: "·  ⭐ " + w.points + " pts"
                        font.pixelSize: theme.fontLabel; color: theme.textPrimary }
                }
                // Goal progress dots - a glanceable "streak" bar.
                RowLayout {
                    Layout.alignment: Qt.AlignHCenter; spacing: 4; Layout.topMargin: 2
                    Repeater {
                        model: Math.min(w.dailyGoal, 8)
                        delegate: Rectangle {
                            required property int index
                            width: 8; height: 8; radius: 4
                            color: index < w.completedWork ? theme.success : theme.cardBorder
                        }
                    }
                }
            }
        }
        // Encouraging nudge (focus) or a break-activity suggestion (break).
        Text {
            Layout.fillWidth: true
            visible: (w.phase === "work" && w.showNudges) || (w.phase !== "work" && w.breakSuggestions)
            horizontalAlignment: Text.AlignHCenter
            text: w.phase === "work"
                  ? w.nudges[w.completedWork % w.nudges.length]
                  : "Break idea: " + w.breakIdeas[w.completedWork % w.breakIdeas.length]
            font.pixelSize: theme.fontLabel; font.italic: true
            color: theme.textPrimary; opacity: 0.78; elide: Text.ElideRight
        }
        RowLayout {
            Layout.alignment: Qt.AlignHCenter; spacing: theme.spacingSm
            PillButton { label: "Reset"; glyph: "⟲"; tint: theme.textPrimary; onClicked: w.reset() }
            PillButton { label: w.running ? "Pause" : "Start"; glyph: w.running ? "⏸" : "▶"
                primary: true; tint: w.phaseColor(); implicitWidth: 150; onClicked: w.toggle() }
            PillButton { label: "+5"; glyph: "＋"; tint: w.phaseColor(); onClicked: w.addFive() }
            PillButton {
                label: w.skipArmed ? "Confirm" : "Skip"
                glyph: "⏭"
                tint: w.skipArmed ? theme.warning : theme.textPrimary
                onClicked: w.requestSkip()
            }
        }
    }
}

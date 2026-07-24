import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// ─────────────────────────────────────────────────────────────────────────
// Now / Next - the two questions an agenda actually gets asked: what am I
// supposed to be doing, and what is coming.
//
// WHY IT EMBEDS CalendarWidget. Calendar already answers this: its `events` model
// is expanded, sorted, recurrence-aware, EXDATE-aware, TZID-aware and horizon-
// bounded. Re-deriving now/next from a second, simpler ICS parser would mean two
// implementations of "when is this event, really" - and the one in Calendar took
// DST-safe day stepping, webcal rewriting and a supersede guard to get right. So
// this widget instantiates a headless CalendarWidget (zero-sized, invisible) purely
// as an agenda MODEL and reads `events` off it. The nested instance is passed our
// own `instanceId`, so it reads the same `url` setting and there is exactly one
// source of truth per tile.
//
// EGRESS. The nested Calendar fetches through the injected NetHub with the same
// kill switch, allowlist, counters, private-reference resolution, and provider
// lease. Calendar and Now/Next instances using the same stored source coalesce
// concurrent requests and reuse the just-published in-memory result.
//
// Sizing (W1 wave 2b): there are exactly TWO blocks, ever, so this widget cannot
// earn a size with more rows - it earns it with LEGIBILITY. The type was a flat
// 17px on every tile and 44px in the overlay, so a 696x819 baseline tile rendered
// the same cramped pair as a 348x819 sliver.
//   • wide  - NOW and NEXT side by side. A 846x306 banner stacked into two blocks
//             leaves each ~120px; beside each other they get the full height.
//   • every other shape - stacked, with the type scaled to the box.
//   • full (overlay) - larger hierarchy and live source status; connection
//             editing stays in the adjacent shared WidgetConfigPanel.
// (No 0.5x0.5 is declared, so `micro` is never true here - see WidgetCatalog.)
// ─────────────────────────────────────────────────────────────────────────
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""
    property int tick: 0
    // The app-global egress gate, injected by Dashboard; forwarded to the nested
    // Calendar, which is what actually talks to the network.
    property var netHub: null
    // Test seam, forwarded the same way.
    property var xhrFactory: null
    // Test seam for the final confirmed external launch.
    property var externalOpener: function(url) { return Qt.openUrlExternally(url) }
    property string pendingJoinUrl: ""

    title: "Now / Next"; iconName: "nownext"; accentColor: theme.catServices

    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    readonly property string url: cfg.url || ""
    readonly property int bufferMin: Math.max(0, Math.min(120,
        Number(cfg.bufferMin !== undefined ? cfg.bufferMin : 10)))
    property double nowMsOverride: -1
    function currentMs() { return w.nowMsOverride >= 0 ? w.nowMsOverride : Date.now() }

    // The agenda model. Zero-sized + invisible: it is data, not chrome.
    CalendarWidget {
        id: agenda
        width: 0; height: 0; visible: false
        store: w.store
        instanceId: w.instanceId
        active: w.active
        netHub: w.netHub
        xhrFactory: w.xhrFactory
        tick: w.tick
        nowMsOverride: w.nowMsOverride
    }

    // Proxies, so this widget's own state reads (and its tests) never have to
    // know the model is a nested component.
    readonly property var events: agenda.events
    readonly property bool loading: agenda.loading
    readonly property string errorText: agenda.errorText
    readonly property bool stale: agenda.stale
    readonly property string freshnessText: agenda.freshnessText()
    readonly property var parseWarnings: agenda.parseWarnings
    function refresh() { agenda.refresh(true) }

    // An all-day event carries DTEND exclusive, and CalendarWidget leaves dur = 0
    // when there is no DTEND at all - so `end` can equal `start` (midnight) and a
    // naive start<=now<end would say an all-day event is never happening. Give it
    // its whole day.
    function endOf(ev) {
        if (!ev || !ev.start) return 0
        var s = ev.start.getTime()
        var e = ev.end ? ev.end.getTime() : s
        if (ev.allDay) {
            var nextMidnight = new Date(ev.start)
            nextMidnight.setHours(0, 0, 0, 0)
            nextMidnight.setDate(nextMidnight.getDate() + 1)
            return Math.max(e, nextMidnight.getTime())
        }
        return e
    }

    // `tick` is what makes these re-evaluate each second; nothing is written.
    readonly property var nowEvent: {
        var t = (w.tick, w.currentMs())
        var evs = w.events
        for (var i = 0; i < evs.length; i++)
            if (evs[i].start.getTime() <= t && t < w.endOf(evs[i])) return evs[i]
        return null
    }
    readonly property var nextEvent: {
        var t = (w.tick, w.currentMs())
        var evs = w.events
        for (var i = 0; i < evs.length; i++)
            if (evs[i].start.getTime() > t) return evs[i]
        return null
    }

    status: w.errorText.length ? "Error" : w.stale ? "Stale"
            : w.parseWarnings.length ? "Partial"
            : (w.expanded ? "" : (w.nowEvent ? "now" : (w.nextEvent ? "next" : "")))
    statusColor: w.errorText.length || w.stale || w.parseWarnings.length
                 ? theme.warning : w.effAccent

    // ── Per-size layout (sizeClass injected by Dashboard) ────────────────────
    // Two blocks side by side once the box is genuinely wider than it is tall.
    readonly property bool horiz: sizeClass === "wide"
    // Both blocks show together, so each gets half the height when stacked.
    readonly property int _blocks: (w.nowEvent !== null ? 1 : 0) + (w.nextEvent !== null ? 1 : 0)
    readonly property real _colW: w.horiz ? width * 0.5 : width
    readonly property real _blockH: w.horiz ? height : height / Math.max(1, w._blocks)
    // The event title is the thing you read from across the room.
    readonly property real titlePx: w.expanded ? 44
        : Math.max(theme.fontTitle, Math.min(w._colW * 0.075, w._blockH * 0.22, 40))
    readonly property real nextTitlePx: w.expanded ? 32
        : Math.max(theme.fontTitle, Math.round(w.titlePx * (w.nowEvent ? 0.78 : 1.0)))
    readonly property real labelPx: w.expanded ? theme.fontLabel
        : Math.max(theme.fontLabel, Math.min(w.titlePx * 0.36, 19))
    readonly property real metaPx: w.expanded ? 22
        : Math.max(theme.fontLabel, Math.min(w.titlePx * 0.48, 24))

    // Whole minutes, rounded UP: "in 1 min" must not appear as "in 0 min" for the
    // 59 seconds before the thing starts.
    function minutesUntil(d) { return Math.ceil((d.getTime() - w.currentMs()) / 60000) }
    function humanDelta(mins) {
        if (mins <= 0) return "now"
        if (mins < 60) return "in " + mins + " min"
        var h = Math.floor(mins / 60), m = mins % 60
        if (h < 24) return m ? "in " + h + " h " + m + " min" : "in " + h + " h"
        var days = Math.round(h / 24)
        return "in " + days + (days === 1 ? " day" : " days")
    }
    function whenText(ev) {
        if (!ev) return ""
        var t = (w.tick, 0)
        if (ev.allDay) {
            var today = new Date(w.currentMs()).toDateString() === ev.start.toDateString()
            return today ? "all day" : Qt.formatDate(ev.start, "ddd MMM d") + " · all day"
        }
        var mins = w.minutesUntil(ev.start)
        return Qt.formatTime(ev.start, "HH:mm") + " · "
               + (mins > 0 && mins <= w.bufferMin ? "starts soon" : w.humanDelta(mins))
    }
    function untilText(ev) {
        if (!ev) return ""
        var t = (w.tick, 0)
        if (ev.allDay) return "all day"
        var mins = Math.ceil((w.endOf(ev) - w.currentMs()) / 60000)
        return "until " + Qt.formatTime(new Date(w.endOf(ev)), "HH:mm")
               + (mins > 0 && mins < 60 ? " · " + mins + " min left" : "")
    }
    function meetingUrl(ev) {
        if (!ev) return ""
        var direct = String(ev.url || "")
        if (/^https:\/\//i.test(direct)) return direct.replace(/[)\],.!;]+$/, "")
        var match = /https:\/\/[^\s,;]+/i.exec(String(ev.location || ""))
        return match ? match[0].replace(/[)\],.!;]+$/, "") : ""
    }
    readonly property string joinUrl: w.meetingUrl(w.nowEvent) || w.meetingUrl(w.nextEvent)
    function joinHost(url) {
        var m = /^https:\/\/([^\/?#]+)/i.exec(url || "")
        return m ? m[1].replace(/^www\./i, "") : "meeting"
    }
    function joinLabel(url) {
        return w.pendingJoinUrl === url
            ? "Open " + w.joinHost(url) + "?"
            : "Join " + w.joinHost(url)
    }
    function requestJoin(url) {
        if (!url.length) return
        if (w.pendingJoinUrl === url) {
            w.pendingJoinUrl = ""
            joinConfirmTimer.stop()
            w.externalOpener(url)
            return
        }
        w.pendingJoinUrl = url
        joinConfirmTimer.restart()
    }
    Timer {
        id: joinConfirmTimer
        interval: 5000
        onTriggered: w.pendingJoinUrl = ""
    }

    // ── Empty / error state ────────────────────────────────────────────────
    Text {
        anchors.centerIn: parent
        width: parent.width - 2 * theme.spacingSm
        visible: !w.url.length || (!w.nowEvent && !w.nextEvent)
        text: !w.url.length
              ? (w.expanded ? "Add a private ICS reference in the configuration panel."
                            : "Add a calendar\nin settings")
              : (w.loading ? "Loading calendar..." : (w.errorText.length ? w.errorText : "Nothing scheduled"))
        color: w.errorText.length ? theme.warning : theme.textTertiary
        font.pixelSize: w.expanded ? theme.fontTitle
            : Math.max(theme.fontLabel, Math.min(w.width * 0.045, 22))
        horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
    }

    // ── The two blocks ─────────────────────────────────────────────────────
    // `columns` flips for a wide box: NOW and NEXT sit side by side rather than
    // splitting a 306px-tall banner between them. Only a reshape.
    GridLayout {
        anchors.fill: parent
        anchors.margins: w.expanded ? theme.spacingMd : 0
        anchors.bottomMargin: w.expanded ? theme.fontLabel + theme.spacingLg : 0
        visible: w.url.length > 0 && (w.nowEvent !== null || w.nextEvent !== null)
        columns: w.horiz ? 3 : 1        // NOW | hairline | NEXT
        rowSpacing: w.expanded ? theme.spacingXl : theme.spacingSm
        columnSpacing: theme.spacingLg

        // NOW - the accent block. It is the answer to "am I meant to be somewhere".
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.alignment: Qt.AlignVCenter
            visible: w.nowEvent !== null
            spacing: 2
            Item { Layout.fillHeight: true }
            Text {
                text: "NOW"; color: w.effAccent; font.bold: true
                font.pixelSize: Math.round(w.labelPx); font.letterSpacing: 1.5
            }
            Text {
                Layout.fillWidth: true
                text: w.nowEvent ? (w.nowEvent.title || "(busy)") : ""
                color: theme.textPrimary; font.family: theme.fontDisplay
                font.pixelSize: Math.round(w.titlePx); font.bold: true
                elide: Text.ElideRight; maximumLineCount: 1
            }
            Text {
                Layout.fillWidth: true
                text: w.nowEvent ? w.untilText(w.nowEvent)
                                   + (w.nowEvent.location ? "  ·  " + w.nowEvent.location : "") : ""
                color: theme.textSecondary; font.pixelSize: Math.round(w.metaPx)
                elide: Text.ElideRight
            }
            PillButton {
                visible: w.nowEvent !== null && w.meetingUrl(w.nowEvent).length > 0
                         && w._blockH >= 220
                label: w.joinLabel(w.meetingUrl(w.nowEvent))
                glyph: "↗"; primary: w.pendingJoinUrl === w.meetingUrl(w.nowEvent)
                tint: w.effAccent
                minWidth: Math.min(240, Math.max(150, w._colW * 0.72))
                onClicked: w.requestJoin(w.meetingUrl(w.nowEvent))
            }
            Item { Layout.fillHeight: true }
        }

        // A hairline between the blocks, only when both are showing. It runs
        // across a stacked pair and DOWN a side-by-side one.
        Rectangle {
            visible: w.nowEvent !== null && w.nextEvent !== null
            Layout.fillWidth: !w.horiz
            Layout.fillHeight: w.horiz
            Layout.preferredWidth: w.horiz ? 1 : -1
            Layout.preferredHeight: w.horiz ? -1 : 1
            color: theme.cardBorder
        }

        // NEXT - deliberately quieter than NOW.
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.alignment: Qt.AlignVCenter
            visible: w.nextEvent !== null
            spacing: 2
            Item { Layout.fillHeight: true }
            Text {
                text: "NEXT"; color: theme.textTertiary; font.bold: true
                font.pixelSize: Math.round(w.labelPx); font.letterSpacing: 1.5
            }
            Text {
                Layout.fillWidth: true
                text: w.nextEvent ? (w.nextEvent.title || "(busy)") : ""
                color: w.nowEvent ? theme.textSecondary : theme.textPrimary
                font.family: theme.fontDisplay
                font.pixelSize: Math.round(w.nextTitlePx); font.bold: !w.nowEvent
                elide: Text.ElideRight; maximumLineCount: 1
            }
            Text {
                Layout.fillWidth: true
                text: w.nextEvent ? w.whenText(w.nextEvent)
                                    + (w.nextEvent.location ? "  ·  " + w.nextEvent.location : "") : ""
                color: theme.textSecondary; font.pixelSize: Math.round(w.metaPx)
                elide: Text.ElideRight
            }
            PillButton {
                visible: w.nextEvent !== null && w.meetingUrl(w.nextEvent).length > 0
                         && w._blockH >= 220
                label: w.joinLabel(w.meetingUrl(w.nextEvent))
                glyph: "↗"; primary: w.pendingJoinUrl === w.meetingUrl(w.nextEvent)
                tint: w.effAccent
                minWidth: Math.min(240, Math.max(150, w._colW * 0.72))
                onClicked: w.requestJoin(w.meetingUrl(w.nextEvent))
            }
            Item { Layout.fillHeight: true }
        }
    }

    Text {
        visible: w.expanded && w.url.length > 0
        anchors.left: parent.left; anchors.bottom: parent.bottom
        width: parent.width
        text: w.freshnessText + (w.parseWarnings.length ? " · " + w.parseWarnings.join("; ") : "")
        color: w.errorText.length || w.stale || w.parseWarnings.length
               ? theme.warning : theme.textTertiary
        font.pixelSize: theme.fontMinimum; elide: Text.ElideRight
    }
}

import QtQuick
import QtQuick.Layouts

// Daily quote - rotates once per day from a chosen category (or your own custom
// list); no network. A "Shuffle" picks a fresh one on demand.
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""
    property int tick: 0

    title: "Daily Quote"; iconName: "quote"; accentColor: theme.catInfo
    showHeader: expanded

    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    readonly property string category: cfg.category !== undefined ? cfg.category : "focus"
    readonly property string customText: cfg.customText !== undefined ? cfg.customText : ""
    readonly property string authorDisplay: ["auto", "always", "hide"].indexOf(cfg.authorDisplay) >= 0
        ? cfg.authorDisplay : "auto"

    readonly property var library: ({
        "focus": [
            { t: "Choose the next useful action, then give it your full attention.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "A clear finish line makes the first step easier.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "Protect a small block of time and make it count.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "Progress becomes visible when attention stops changing lanes.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "Finish the useful version before polishing the imagined one.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "One protected priority can rescue a crowded day.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "Make the next decision small enough to act on.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "Attention is a budget. Spend it where progress can answer.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" }
        ],
        "stoic": [
            { t: "Meet the moment you have, not the one you expected.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "Your response is still yours when the situation is not.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "Notice what is outside your control, then release the argument with it.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "Steady choices outlast dramatic intentions.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "Use the obstacle as information about the next move.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "A calm pause can be part of a decisive response.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "Let facts arrive before your conclusion does.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "Hold the standard firmly and the ego lightly.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" }
        ],
        "humor": [
            { t: "The shortcut was excellent until it introduced us to three new problems.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "Today's plan is fully tested against yesterday's assumptions.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "A tidy desk is often just a very confident drawer.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "The bug waited patiently for the demonstration.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "Coffee cannot solve everything, but it can attend the meeting.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "The final version was discovered directly after the final version.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "Nothing says confidence like opening the settings during a demo.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "The meeting ended early, so naturally everyone stayed to discuss it.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" }
        ],
        "kindness": [
            { t: "Make the next interaction a little easier for the person after you.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "A patient answer can change the shape of someone's day.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "Leave room for the story you have not heard yet.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "Care can be precise, practical and quiet.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "Offer yourself the same patience you would give a friend.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "A useful kindness notices what would make the next step lighter.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "Listen long enough for the quieter part of the answer.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" },
            { t: "Respect can be visible in the care taken with small details.", a: "EdgeHub editorial", s: "EdgeHub built-in library", r: "Bundled project copy" }
        ]
    })

    // Parse the user's custom list once with deterministic separator precedence.
    // Each malformed attributed line is reported by its one-based line number.
    function parseCustomResult() {
        var out = []
        var errors = []
        var lines = ("" + w.customText).split("\n")
        var separators = [
            " " + String.fromCharCode(0x2014) + " ",
            " -- ",
            " | ",
            " - "
        ]
        for (var i = 0; i < lines.length; i++) {
            var rawLine = lines[i]
            var ln = rawLine.trim()
            if (!ln.length) continue
            var sepAt = -1
            var separator = ""
            for (var j = 0; j < separators.length; j++) {
                sepAt = rawLine.indexOf(separators[j])
                if (sepAt >= 0) {
                    separator = separators[j]
                    break
                }
            }
            if (sepAt < 0) {
                out.push({ t: ln, a: "", s: "Custom text", r: "User supplied" })
                continue
            }
            var quoteText = rawLine.substring(0, sepAt).trim()
            var author = rawLine.substring(sepAt + separator.length).trim()
            if (!quoteText.length) {
                errors.push("Line " + (i + 1) + ": quote text is empty")
                continue
            }
            if (!author.length) {
                errors.push("Line " + (i + 1) + ": author is empty")
                continue
            }
            out.push({ t: quoteText, a: author, s: "Custom text", r: "User supplied" })
        }
        return { items: out, errors: errors }
    }
    readonly property var customParseResult: w.parseCustomResult()
    function parseCustom() { return w.customParseResult.items }
    readonly property var customErrors: w.customParseResult.errors
    // Custom mode never changes source behind the user's back.
    readonly property var pool: {
        if (w.category === "custom") return w.customParseResult.items
        return library[w.category] || library["focus"]
    }
    readonly property bool customLibraryEmpty: w.category === "custom" && w.pool.length === 0
    readonly property string customIssue: {
        if (w.category !== "custom") return ""
        if (!w.customText.trim().length) return "Add at least one custom quote in settings"
        if (w.customLibraryEmpty && w.customErrors.length)
            return w.customErrors[0]
        if (w.customErrors.length === 1) return "1 custom line was skipped"
        if (w.customErrors.length > 1) return w.customErrors.length + " custom lines were skipped"
        return ""
    }
    status: w.customIssue

    // Calendar day key (local) → changes exactly once per local midnight when the
    // dashboard bumps `tick`. Drives both the daily rotation and the release of a
    // manual shuffle, so a pinned quote can't survive forever (S6).
    readonly property string todayKey: {
        w.tick
        var d = new Date()
        return d.getFullYear() + "-" + (d.getMonth() + 1) + "-" + d.getDate()
    }
    // Day-of-year index → stable for the whole day, rotates at midnight (via tick).
    // Uses UTC calendar-date midnights so the count can't drift an hour across a
    // DST boundary the way a raw ms delta between local timestamps would (S6).
    property int dailyIdx: {
        w.tick
        var n = new Date()
        var doy = Math.round((Date.UTC(n.getFullYear(), n.getMonth(), n.getDate())
                              - Date.UTC(n.getFullYear(), 0, 0)) / 86400000)
        return doy % Math.max(1, w.pool.length)
    }
    // A manual shuffle is shared ephemeral state. Tile, overlay, and Manager are
    // separate QML instances, so instance-local state makes each show a different
    // quote after one host shuffles.
    property int manualIdx: -1
    property string pinnedText: ""
    property bool _syncingManual: false
    property bool _manualWritePending: false
    function _persistManual() {
        if (!w.active || !w.store || !w.instanceId) {
            w._manualWritePending = false
            return
        }
        w._manualWritePending = false
        w.store.patchSettings(w.instanceId, {
            quoteManualIdx: w.manualIdx,
            quotePinnedText: w.pinnedText,
            quoteManualDay: w.manualIdx >= 0 ? w.todayKey : ""
        })
    }
    function _restoreManual() {
        if (!w.store || !w.instanceId) return
        if (w._manualWritePending) return
        var s = w.store.settingsFor(w.instanceId)
        w._syncingManual = true
        if (s.quoteManualDay === w.todayKey && Number(s.quoteManualIdx) >= 0) {
            w.manualIdx = Number(s.quoteManualIdx)
            w.pinnedText = String(s.quotePinnedText || "")
        } else {
            w.manualIdx = -1
            w.pinnedText = ""
        }
        w._syncingManual = false
    }
    onManualIdxChanged: {
        if (w._syncingManual) return
        w.pinnedText = (w.manualIdx >= 0 && w.manualIdx < w.pool.length)
            ? w.pool[w.manualIdx].t : ""
        // A manual index can change while cfg is reacting to a store revision
        // (for example when category changes). Defer the write out of that
        // binding evaluation to avoid a cfg revision loop.
        w._manualWritePending = true
        Qt.callLater(w._persistManual)
    }
    onStoreChanged: _restoreManual()
    onInstanceIdChanged: _restoreManual()
    onCategoryChanged: {
        if (w.active) w.manualIdx = -1
        else w._restoreManual()
    }
    onTodayKeyChanged: {
        if (w.active) w.manualIdx = -1
        else w._restoreManual()
    }
    Connections {
        target: w.store
        function onRevisionChanged() { w._restoreManual() }
    }
    Component.onCompleted: _restoreManual()
    property int idx: {
        if (w.manualIdx >= 0) {
            if (w.pinnedText.length) {
                for (var i = 0; i < w.pool.length; i++)
                    if (w.pool[i].t === w.pinnedText) return i
            }
            if (w.manualIdx < w.pool.length) return w.manualIdx
        }
        return w.dailyIdx
    }
    property var q: w.pool[idx] || ({ t: "", a: "", s: "", r: "" })
    readonly property string displayQuoteText: w.customLibraryEmpty ? w.customIssue : w.q.t
    readonly property string authorText: w.q.a.length ? w.q.a : "Unknown author"
    readonly property string provenanceText: q.s ? "Source: " + q.s : ""
    readonly property string rightsText: q.r ? "Rights: " + q.r : ""
    function shuffle() {
        if (w.pool.length <= 1) return
        var n = w.idx
        while (n === w.idx) n = Math.floor(Math.random() * w.pool.length)
        w.manualIdx = n
    }

    // ── Per-size layout (sizeClass is injected by Dashboard) ─────────────────
    // 0.5x0.5 and 1x1 are both "compact" (shape, not footprint); the micro
    // half-cell is told apart by the box (~344-416px short side vs ~690px+).
    readonly property bool micro: sizeClass === "compact" && Math.min(width, height) < 480
    readonly property bool horiz: sizeClass === "wide"
    // What each size earns: micro is the quote alone (no glyph/author/controls
    // competing for a twelfth of the screen); every larger size adds the
    // decorative glyph, the author, and a touch-sized shuffle.
    readonly property bool showGlyph: !micro && !w.customLibraryEmpty
    readonly property bool showAuthor: !micro && w.authorDisplay !== "hide"
        && (w.q.a.length > 0 || w.authorDisplay === "always")
    readonly property bool showShuffleTile: !expanded && !micro && pool.length > 1
    readonly property real quotePx: {
        if (sizeClass === "full") return 30
        if (micro) return Math.max(theme.fontLabel, Math.min(width * 0.072, 22))
        if (sizeClass === "compact") return Math.max(theme.fontLabel, Math.min(width * 0.045, 25))
        if (horiz) return Math.max(theme.fontLabel, Math.min(height * 0.07, width * 0.035, 30))
        return Math.max(theme.fontTitle, Math.min(width * 0.07, 30))   // tall
    }
    readonly property int quoteLines: {
        if (sizeClass === "full") return 6
        if (micro) return 4
        if (horiz) return height > 500 ? 5 : 3
        return sizeClass === "tall" ? 6 : 4
    }

    GridLayout {
        id: quoteLayout
        anchors.centerIn: parent
        // A very wide box narrows the reading column so a
        // short quote sits as a centred block instead of hugging the left edge.
        width: parent.width * (w.horiz && w.width > 1000 ? 0.62 : 0.9)
        columns: w.horiz ? 2 : 1
        columnSpacing: theme.spacingMd
        rowSpacing: w.sizeClass === "full" ? 14 : (w.micro ? 2 : theme.spacingXs)

        Text {
            visible: w.showGlyph
            Layout.alignment: w.horiz ? (Qt.AlignTop | Qt.AlignLeft) : Qt.AlignHCenter
            text: "“"; font.bold: true
            font.pixelSize: w.sizeClass === "full" ? 72
                            : Math.max(22, Math.min(Math.min(w.width, w.height) * 0.12, 56))
            color: w.effAccent
        }
        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: w.micro ? 2 : theme.spacingXs
            Text {
                Layout.fillWidth: true
                horizontalAlignment: w.horiz ? Text.AlignLeft : Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: w.displayQuoteText
                font.italic: !w.customLibraryEmpty
                font.weight: w.customLibraryEmpty ? Font.DemiBold : Font.Normal
                color: w.customLibraryEmpty ? w.effAccent : theme.textPrimary
                font.pixelSize: w.quotePx
                maximumLineCount: w.quoteLines; elide: Text.ElideRight
                fontSizeMode: Text.Fit; minimumPixelSize: theme.fontMinimum
            }
            Text {
                Layout.fillWidth: true
                horizontalAlignment: w.horiz ? Text.AlignLeft : Text.AlignHCenter
                visible: w.showAuthor; text: "- " + w.authorText
                font.pixelSize: w.sizeClass === "full" ? 20
                                : Math.max(theme.fontLabel, Math.min(w.width * 0.03, 20))
                font.weight: Font.Medium
                color: theme.textPrimary
                elide: Text.ElideRight; maximumLineCount: 1
            }
            Text {
                objectName: "quoteProvenance"
                Layout.fillWidth: true
                horizontalAlignment: w.horiz ? Text.AlignLeft : Text.AlignHCenter
                visible: w.expanded && w.provenanceText.length > 0
                text: w.provenanceText + "\n" + w.rightsText
                font.pixelSize: theme.fontMinimum
                color: theme.textSecondary
                wrapMode: Text.WordWrap
            }
            Text {
                objectName: "quoteCustomValidation"
                Layout.fillWidth: true
                horizontalAlignment: w.horiz ? Text.AlignLeft : Text.AlignHCenter
                visible: w.expanded && w.category === "custom" && w.customErrors.length > 0
                text: w.customErrors.join("\n")
                font.pixelSize: theme.fontLabel
                color: theme.warning
                wrapMode: Text.WordWrap
            }
            Text {
                objectName: "quoteCustomRightsNotice"
                Layout.fillWidth: true
                horizontalAlignment: w.horiz ? Text.AlignLeft : Text.AlignHCenter
                visible: w.expanded && w.category === "custom"
                text: "Only display custom text you have permission to use."
                font.pixelSize: theme.fontMinimum
                color: theme.textSecondary
                wrapMode: Text.WordWrap
            }
            PillButton {
                objectName: "quoteExpandedShuffle"
                Layout.alignment: Qt.AlignHCenter; Layout.topMargin: theme.spacingSm
                visible: w.expanded && w.pool.length > 1
                label: "Another quote"; glyphIcon: "ui-refresh"
                accessibleName: "Show another quote"
                tint: w.effAccent; onClicked: w.shuffle()
            }
        }
    }

    // Tile shuffle - the one useful basic action on the tile (every size that can
    // host a touch-token target without crowding the text, i.e. all but micro).
    // The top-right is reserved for config, so it sits bottom-right, clear of the
    // centred quote text. Reuses the same shuffle() the expanded pill calls.
    PillButton {
        id: shuffleCompact
        objectName: "quoteTileShuffle"
        visible: w.showShuffleTile
        anchors.right: parent.right; anchors.bottom: parent.bottom
        anchors.rightMargin: theme.spacingXs; anchors.bottomMargin: theme.spacingXs
        width: Math.max(theme.touchTertiary, implicitWidth)
        height: Math.max(theme.touchTertiary, implicitHeight)
        glyphIcon: "ui-refresh"
        accessibleName: "Show another quote"
        tint: w.effAccent
        onClicked: w.shuffle()
    }
}

import QtQuick
import QtQuick.Layouts

// Filesystem capacity and block activity from the Rust core.
//
// Sizing (W1): layout keys off `sizeClass` (injected by Dashboard), never off
// `expanded`. The ring carries the capacity story while larger sizes add mount
// identity, exact capacity composition, thresholds, and read/write activity:
//   • 0.5x0.5 (micro) - a bare ring + percent, headerless: nothing competes
//     with the one number in a twelfth of the screen.
//   • 1x1 (compact)   - header + ring with percent and used/total inside.
//   • wide            - ring beside a Used / Free / Total detail column.
//   • tall / full     - ring above the same detail column.
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""

    title: "Disk"; iconName: "disk"; accentColor: theme.catInfo
    showHeader: !micro

    // Live per-instance config (see WidgetConfigSchema "disk").
    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    // Clamp to the schema slider range (50..99). The Manager control socket or a
    // hand-edited config can inject anything, and an out-of-range warn line breaks
    // the colour bands (e.g. warnPercent 0 paints every disk amber).
    readonly property real warnPercent: {
        var p = cfg.warnPercent !== undefined ? cfg.warnPercent : 90
        return Math.max(50, Math.min(99, p))
    }
    readonly property string requestedMountPath: String(cfg.mountPath || "/")
    readonly property bool showActivity: cfg.showActivity !== false
    readonly property var mountCatalog: Array.isArray(metrics.disk_mounts)
                                        ? metrics.disk_mounts : []
    readonly property bool selectedMountMissing: mountCatalog.length > 0
                                                 && selectedMount === null
    readonly property var selectedMount: {
        for (var i = 0; i < mountCatalog.length; i++) {
            var candidate = mountCatalog[i] || ({})
            if (String(candidate.path || "") === requestedMountPath) return candidate
        }
        if (mountCatalog.length > 0) return null
        if (requestedMountPath !== "/") return null
        return {
            path: "/",
            source: "",
            fs_type: "",
            device: "",
            metrics_available: metrics.disk_metrics_available !== undefined
                               ? metrics.disk_metrics_available
                               : Number(metrics.disk_total_bytes || 0) > 0,
            unavailable_reason: metrics.disk_unavailable_reason,
            total_bytes: metrics.disk_total_bytes,
            used_bytes: metrics.disk_used_bytes,
            available_bytes: metrics.disk_available_bytes,
            reserved_bytes: metrics.disk_reserved_bytes,
            usage_percent: metrics.disk_usage_percent,
            io_rate_available: false,
            read_bytes_per_sec: 0,
            write_bytes_per_sec: 0
        }
    }

    // statvfs failure and the pre-first-sample frame report no real disk
    // (total absent or 0). Don't fabricate a confident "0%"; flag the tile
    // unavailable so the gauge dims instead of showing a full empty track.
    readonly property bool explicitAvailable: selectedMount !== null
                                              && selectedMount.metrics_available !== undefined
    property bool avail: selectedMount !== null
                         && (explicitAvailable ? selectedMount.metrics_available === true
                                              : Number(selectedMount.total_bytes || 0) > 0)
    readonly property string unavailableReason: selectedMountMissing
                                                ? "Selected mount " + requestedMountPath + " is offline"
                                                : String(selectedMount
                                                         ? selectedMount.unavailable_reason || ""
                                                         : "")
                                                  || "Filesystem metrics are unavailable"
    readonly property string freshness: {
        if (!w.avail) return "unavailable"
        var stamp = Number(metrics.disk_sample_unix_ms || 0)
        if (stamp <= 0) return "live"
        var age = Math.max(0, Math.floor((Date.now() - stamp) / 1000))
        return age < 2 ? "updated now" : "updated " + age + "s ago"
    }
    status: explicitAvailable ? freshness : ""
    statusColor: avail ? theme.textSecondary : theme.warning

    // The df-correct fill (accounts for root-reserved blocks). Clamp to 0..100 so a
    // transient used>total sample can't overdrive the ring.
    property real v: avail ? Math.max(0, Math.min(100,
                                                 selectedMount.usage_percent || 0)) : 0

    // Critical (red) must always sit above the warn line so the amber band stays
    // reachable, and never below the hardware-sensible 97%. Ordering the checks
    // warn→critical stops a high warnPercent turning the ring red below the user's
    // own warn line.
    readonly property real critPercent: Math.min(100, Math.max(97, w.warnPercent + 1))
    function col(p) {
        // The ring label is rounded to a whole percent. Use that same displayed
        // value for status bands so two readings both shown as "97%" cannot
        // disagree in colour.
        var shown = Math.round(p)
        if (shown >= w.critPercent) return theme.error
        if (shown >= w.warnPercent) return theme.warning
        return w.effAccent
    }
    function human(b) {
        // Sizes are computed in powers of two, so label them with binary units.
        if (b >= 1099511627776) return (b / 1099511627776).toFixed(2) + " TiB"
        return (b / 1073741824).toFixed(0) + " GiB"
    }
    function humanCompact(b) {
        if (b >= 1099511627776)
            return (b / 1099511627776).toFixed(1) + " TiB"
        return (b / 1073741824).toFixed(0) + " GiB"
    }
    function humanRate(b) {
        if (b >= 1073741824) return (b / 1073741824).toFixed(1) + " GiB/s"
        if (b >= 1048576) return (b / 1048576).toFixed(1) + " MiB/s"
        if (b >= 1024) return (b / 1024).toFixed(0) + " KiB/s"
        return Math.round(b) + " B/s"
    }
    readonly property string mountPath: selectedMount
                                        ? String(selectedMount.path || requestedMountPath)
                                        : requestedMountPath
    readonly property string filesystemIdentity: {
        if (!selectedMount) return mountPath
        var parts = [mountPath]
        if (String(selectedMount.fs_type || "").length)
            parts.push(String(selectedMount.fs_type))
        if (String(selectedMount.source || "").length)
            parts.push(String(selectedMount.source))
        return parts.join(" · ")
    }
    readonly property bool ioAvailable: avail && selectedMount
                                        && selectedMount.io_rate_available === true
    readonly property real readRate: ioAvailable
                                     ? Number(selectedMount.read_bytes_per_sec || 0) : 0
    readonly property real writeRate: ioAvailable
                                      ? Number(selectedMount.write_bytes_per_sec || 0) : 0
    readonly property string capacityState: !avail ? "Unavailable"
                                                  : Math.round(v) >= critPercent ? "Critical"
                                                  : Math.round(v) >= warnPercent ? "Warning"
                                                  : "Healthy"
    readonly property string accessibleSummary: !avail
                                                ? "Disk " + mountPath + ", "
                                                  + unavailableReason
                                                : "Disk " + filesystemIdentity + ", "
                                                  + v.toFixed(0) + " percent used, "
                                                  + capacityState + ", "
                                                  + human(availableBytes) + " available"
    Accessible.name: accessibleSummary
    // Byte labels use the real statvfs counters. The percentage intentionally
    // follows df and uses Used / (Used + Available), while Total also includes
    // root-reserved blocks.
    readonly property real totalBytes: selectedMount ? Number(selectedMount.total_bytes || 0) : 0
    readonly property real usedBytes: selectedMount ? Number(selectedMount.used_bytes || 0) : 0
    readonly property real availableBytes: selectedMount
                                            && selectedMount.available_bytes !== undefined
                                            ? Number(selectedMount.available_bytes || 0)
                                            : Math.max(0, totalBytes - usedBytes)
    readonly property real reservedBytes: selectedMount
                                          ? Number(selectedMount.reserved_bytes || 0) : 0
    readonly property real freeBytes: availableBytes

    // ── Per-size layout (sizeClass is injected by Dashboard) ─────────────────
    // 0.5x0.5 and 1x1 are both "compact" (shape, not footprint); the micro
    // half-cell is told apart by the box (~344-416px short side vs ~690px+).
    readonly property bool micro: sizeClass === "compact" && Math.min(width, height) < 480
    readonly property bool horiz: sizeClass === "wide"
    readonly property bool shortWide: horiz && height < 460
    readonly property bool roomy: (sizeClass === "tall" || sizeClass === "wide")
                                  && Math.min(width, height) >= 480
    readonly property bool showCompositionLegend: roomy && !shortWide
    // The detail column earns its place wherever there is room beyond the ring.
    readonly property bool showDetails: sizeClass === "wide" || sizeClass === "tall"
                                        || sizeClass === "large" || sizeClass === "full"
    // used/total inside the ring: only the baseline tile and the overlay - the
    // micro ring is too small and the detail column already carries it elsewhere.
    readonly property bool showInlineSub: avail && !micro && !showDetails
    // Derive constrained detail modes from the active type and spacing tokens.
    // A large text scale or 125% output projection reduces both axes even though
    // the semantic size remains "wide" or "tall".
    readonly property real bodyHeightBudget: Math.max(
        0, height - 2 * contentMargins
           - (showHeader
              ? headerHeight + (big ? theme.spacingSm : theme.spacingXs)
              : 0))
    readonly property real detailsWidthBudget: Math.max(
        0, horiz ? diskLayout.width * 0.5 : diskLayout.width * 0.86)
    readonly property bool compactVerticalDetails: showDetails
        && (horiz
            ? bodyHeightBudget < theme.fontLabel * 12.5
            : detailsWidthBudget < theme.fontLabel * 18
              && bodyHeightBudget - ringDia < theme.fontLabel * 16.5)
    readonly property bool compactThreshold: showDetails
        && detailsWidthBudget < theme.fontLabel * 19
    readonly property bool compactIoFallback: compactVerticalDetails
        || (horiz
            && (detailsWidthBudget - theme.spacingMd) / 2
               < theme.fontLabel * 13)
    readonly property bool showCompositionHeading: !shortWide
        && !compactVerticalDetails
        && (horiz
            || bodyHeightBudget - ringDia >= theme.fontLabel * 17)
    readonly property string thresholdText: {
        var warn = warnPercent.toFixed(0)
        var crit = critPercent.toFixed(0)
        if (compactThreshold) {
            if (horiz)
                return capacityState + " · " + warn + " / " + crit + "%"
            return capacityState + "\nWarn " + warn + "% · Crit " + crit + "%"
        }
        return avail
            ? capacityState + " · warn " + warn + "% · crit " + crit + "%"
            : "Unavailable · limits " + warn + " / " + crit + "%"
    }
    readonly property real ringDia: {
        var boxW = width - 2 * contentMargins, boxH = height - 2 * contentMargins - (showHeader ? headerHeight : 0)
        if (micro) return Math.max(0, Math.min(boxW, boxH) * 0.92)
        if (horiz) return Math.max(0, Math.min(boxH * 0.72, boxW * 0.34))
        if (sizeClass === "compact") return Math.max(0, Math.min(boxW, boxH) * 0.80)
        return Math.max(0, Math.min(boxW * (w.roomy ? 0.58 : 0.62),
                                    boxH * (w.roomy ? 0.32 : 0.40)))
    }

    GridLayout {
        id: diskLayout
        objectName: "diskLayout"
        anchors.centerIn: parent
        width: parent.width
        columns: w.horiz ? 2 : 1
        columnSpacing: theme.spacingLg
        rowSpacing: w.micro ? 0 : theme.spacingMd

        Item {
            id: ringBox
            Layout.alignment: Qt.AlignHCenter | Qt.AlignVCenter
            Layout.preferredWidth: Math.round(w.ringDia)
            Layout.preferredHeight: Math.round(w.ringDia)
            RingProgress {
                id: ring
                anchors.fill: parent
                value: w.avail ? w.v / 100 : 0
                thickness: Math.max(9, width * 0.10)
                progressColor: w.col(w.v); progressColor2: w.col(w.v)
                trackColor: Qt.rgba(theme.cardBorder.r, theme.cardBorder.g, theme.cardBorder.b, 0.6)
            }
            Column {
                anchors.centerIn: parent
                width: Math.max(24, ringBox.width - 2 * ring.thickness - 8)
                spacing: 0
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: w.avail ? w.v.toFixed(0) + "%" : "N/A"
                    font.pixelSize: Math.max(18, Math.min(ringBox.width * 0.30, w.sizeClass === "full" ? 108 : 72))
                    fontSizeMode: Text.HorizontalFit; minimumPixelSize: theme.fontMinimum; elide: Text.ElideRight
                    font.bold: true; font.family: theme.fontMono
                    color: w.avail ? w.col(w.v) : theme.textTertiary
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    visible: w.showInlineSub
                    text: w.human(w.usedBytes) + " / " + w.human(w.totalBytes)
                    font.pixelSize: Math.max(theme.fontMinimum, Math.min(ringBox.width * 0.055, theme.fontLabel))
                    fontSizeMode: Text.HorizontalFit; minimumPixelSize: theme.fontMinimum; elide: Text.ElideRight
                    color: theme.textPrimary
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    visible: !w.micro && !w.showDetails
                    text: w.mountPath + " · " + w.capacityState
                    font.pixelSize: theme.fontLabel
                    fontSizeMode: Text.HorizontalFit
                    minimumPixelSize: theme.fontMinimum
                    elide: Text.ElideRight
                    color: w.avail ? theme.textPrimary : theme.warning
                }
            }
        }

        // Used / Available / Total are the raw statvfs byte counters. Reserved is
        // shown only when the filesystem exposes a nonzero root reservation.
        // has the room to spell them out.
        ColumnLayout {
            visible: w.showDetails
            Layout.alignment: Qt.AlignVCenter | Qt.AlignHCenter
            Layout.fillWidth: true
            Layout.maximumWidth: w.horiz ? Math.round(diskLayout.width * 0.5)
                                         : Math.round(diskLayout.width * 0.86)
            spacing: w.compactVerticalDetails
                     ? Math.max(1, Math.round(theme.spacingXs / 2))
                     : theme.spacingXs

            Text {
                objectName: "diskFilesystemIdentity"
                Layout.fillWidth: true
                text: w.filesystemIdentity
                elide: Text.ElideMiddle
                horizontalAlignment: w.horiz ? Text.AlignLeft : Text.AlignHCenter
                font.pixelSize: theme.fontLabel
                font.bold: true
                color: w.avail ? theme.textPrimary : theme.warning
            }
            Text {
                objectName: "diskThreshold"
                Layout.fillWidth: true
                text: w.thresholdText
                elide: w.compactThreshold && !w.horiz
                       ? Text.ElideNone : Text.ElideRight
                wrapMode: w.compactThreshold && !w.horiz
                          ? Text.Wrap : Text.NoWrap
                maximumLineCount: w.compactThreshold && !w.horiz ? 3 : 1
                horizontalAlignment: w.horiz ? Text.AlignLeft : Text.AlignHCenter
                font.pixelSize: theme.fontLabel
                font.bold: w.capacityState !== "Healthy"
                color: w.avail ? w.col(w.v) : theme.warning
            }

            Text {
                visible: !w.avail
                Layout.fillWidth: true
                text: w.unavailableReason
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
                font.pixelSize: theme.fontLabel
                color: theme.warning
            }

            RowLayout {
                objectName: "diskCompactCapacity"
                visible: w.avail && w.compactVerticalDetails
                Layout.fillWidth: true
                spacing: theme.spacingXs

                Repeater {
                    model: [
                        { k: "USED", val: w.humanCompact(w.usedBytes), hot: true },
                        { k: "AVAIL.", val: w.humanCompact(w.availableBytes), hot: false },
                        { k: "TOTAL", val: w.humanCompact(w.totalBytes), hot: false }
                    ]
                    delegate: ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        Text {
                            Layout.fillWidth: true
                            text: modelData.k
                            horizontalAlignment: Text.AlignHCenter
                            font.pixelSize: theme.fontMinimum
                            font.bold: true
                            color: theme.textPrimary
                        }
                        Text {
                            Layout.fillWidth: true
                            text: modelData.val
                            horizontalAlignment: Text.AlignHCenter
                            font.pixelSize: theme.fontMinimum
                            font.family: theme.fontMono
                            font.bold: modelData.hot
                            color: modelData.hot ? w.col(w.v) : theme.textPrimary
                        }
                    }
                }
            }

            Repeater {
                model: [
                    { k: "Used",  val: w.avail ? w.human(w.usedBytes) : "-", hot: true },
                    { k: "Available", val: w.avail ? w.human(w.availableBytes) : "-", hot: false },
                    { k: "Reserved", val: w.avail && w.reservedBytes > 0
                                                  ? w.human(w.reservedBytes) : "-", hot: false },
                    { k: "Total", val: w.avail ? w.human(w.totalBytes) : "-", hot: false }
                ]
                delegate: RowLayout {
                    visible: !w.compactVerticalDetails
                             && (modelData.k !== "Reserved" || w.reservedBytes > 0)
                             && !(w.shortWide && modelData.k === "Reserved")
                    Layout.fillWidth: true
                    spacing: theme.spacingMd
                    Text {
                        text: modelData.k
                        font.pixelSize: theme.fontLabel
                        color: theme.textPrimary
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: modelData.val
                        font.pixelSize: theme.fontTitle
                        font.family: theme.fontMono; font.bold: modelData.hot
                        color: modelData.hot && w.avail ? w.col(w.v) : theme.textPrimary
                    }
                }
            }

            ColumnLayout {
                objectName: "diskActivity"
                visible: w.avail && w.showActivity
                Layout.fillWidth: true
                Layout.topMargin: w.compactVerticalDetails
                                  ? theme.spacingXs : theme.spacingSm
                spacing: theme.spacingXs
                Text {
                    visible: !w.shortWide && !w.compactVerticalDetails
                    text: "LIVE ACTIVITY"
                    color: theme.textPrimary
                    font.pixelSize: theme.fontLabel
                    font.bold: true
                    font.letterSpacing: 0.8
                }
                GridLayout {
                    visible: !w.compactVerticalDetails
                    Layout.fillWidth: true
                    columns: w.horiz ? 2 : 1
                    columnSpacing: theme.spacingMd
                    rowSpacing: theme.spacingXs
                    Text {
                        objectName: "diskReadActivity"
                        text: "↓ Read  " + (w.ioAvailable ? w.humanRate(w.readRate)
                                                         : w.compactIoFallback
                                                           ? "N/A"
                                                           : "No I/O sample")
                        color: w.ioAvailable ? theme.success : theme.textSecondary
                        font.pixelSize: theme.fontLabel
                        font.family: theme.fontMono
                        font.bold: w.ioAvailable
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    Text {
                        objectName: "diskWriteActivity"
                        text: "↑ Write  " + (w.ioAvailable ? w.humanRate(w.writeRate)
                                                           : w.compactIoFallback
                                                             ? "N/A"
                                                             : "No I/O sample")
                        color: w.ioAvailable ? w.effAccent : theme.textSecondary
                        font.pixelSize: theme.fontLabel
                        font.family: theme.fontMono
                        font.bold: w.ioAvailable
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        horizontalAlignment: w.horiz
                                             ? Text.AlignRight : Text.AlignLeft
                    }
                }
                RowLayout {
                    visible: w.compactVerticalDetails
                    Layout.fillWidth: true
                    spacing: theme.spacingMd

                    Repeater {
                        model: [
                            {
                                label: "↓ READ",
                                value: w.ioAvailable
                                       ? w.humanRate(w.readRate) : "N/A",
                                hot: w.ioAvailable,
                                color: w.ioAvailable
                                       ? theme.success : theme.textSecondary,
                                name: "diskCompactReadActivity"
                            },
                            {
                                label: "↑ WRITE",
                                value: w.ioAvailable
                                       ? w.humanRate(w.writeRate) : "N/A",
                                hot: w.ioAvailable,
                                color: w.ioAvailable
                                       ? w.effAccent : theme.textSecondary,
                                name: "diskCompactWriteActivity"
                            }
                        ]
                        delegate: ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text {
                                Layout.fillWidth: true
                                text: modelData.label
                                horizontalAlignment: Text.AlignHCenter
                                color: theme.textPrimary
                                font.pixelSize: theme.fontMinimum
                                font.bold: true
                            }
                            Text {
                                objectName: modelData.name
                                Layout.fillWidth: true
                                text: modelData.value
                                horizontalAlignment: Text.AlignHCenter
                                color: modelData.color
                                font.pixelSize: theme.fontMinimum
                                font.family: theme.fontMono
                                font.bold: modelData.hot
                            }
                        }
                    }
                }
            }

            ColumnLayout {
                objectName: "diskCapacityComposition"
                visible: w.avail
                Layout.fillWidth: true
                Layout.topMargin: w.compactVerticalDetails
                                  ? theme.spacingXs : theme.spacingSm
                spacing: theme.spacingXs
                Text {
                    visible: w.showCompositionHeading
                    objectName: "diskCompositionHeading"
                    text: "CAPACITY COMPOSITION"
                    color: theme.textPrimary
                    font.pixelSize: theme.fontLabel
                    font.bold: true
                    font.letterSpacing: 0.8
                }
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: w.roomy ? 18 : 14
                    radius: height / 2
                    color: theme.cardBorder
                    clip: true
                    Row {
                        anchors.fill: parent
                        Rectangle {
                            width: parent.width * Math.max(0, Math.min(1,
                                   w.usedBytes / Math.max(1, w.totalBytes)))
                            height: parent.height
                            color: w.col(w.v)
                        }
                        Rectangle {
                            width: parent.width * Math.max(0, Math.min(1,
                                   w.availableBytes / Math.max(1, w.totalBytes)))
                            height: parent.height
                            color: theme.success
                        }
                        Rectangle {
                            width: Math.max(0, parent.width - x)
                            height: parent.height
                            color: theme.textTertiary
                        }
                    }
                }
                RowLayout {
                    objectName: "diskCapacityLegend"
                    // The narrow tall projection already presents Used,
                    // Available, Reserved, and Total as readable value rows.
                    // Keep the labelled composition bar, but omit this duplicate
                    // legend unless the tile has enough cross-axis room.
                    visible: w.showCompositionLegend
                    Layout.fillWidth: true
                    Text { text: "USED"; color: w.col(w.v); font.pixelSize: theme.fontLabel; font.bold: true }
                    Item { Layout.fillWidth: true }
                    Text { text: "AVAILABLE"; color: theme.success; font.pixelSize: theme.fontLabel; font.bold: true }
                    Item { Layout.fillWidth: true }
                    Text { text: "RESERVED"; color: theme.textSecondary; font.pixelSize: theme.fontLabel; font.bold: true }
                }
            }
        }
    }
}

import QtQuick
import QtQuick.Layouts

// MetricGauge - the shared visual for the system metric tiles (CPU/GPU/RAM).
// A large ring gauge with the value in the centre + a live sparkline, so the
// tile fills its box richly instead of floating a lone number.
//
// Sizing (W1 wave 2a): the host widget keys the knobs below off its injected
// `sizeClass`; the defaults reproduce the original stacked layout, so existing
// consumers (HttpJsonWidget) render unchanged.
//   • showSpark:false  - micro (0.5x0.5): the ring IS the tile; no sparkline
//     slot is reserved at all.
//   • horizontal:true  - wide: ring beside the sparkline, which finally gets
//     real width instead of a 30px strip under the ring.
//   • sparkFrac        - tall: the sparkline's share of the box; tall tiles
//     raise it so the history earns genuine height.
Item {
    id: g
    property real value: 0          // 0..1 for the ring
    property string big: ""         // centre value, e.g. "42%"
    property string sub: ""         // supporting line, e.g. "avg 34% · peak 87%"
    property color color: theme.accent
    property var history: []        // 0..1 samples for the sparkline
    property bool expanded: false
    property bool ok: true          // false → dim (e.g. GPU N/A)
    // Optional glanceable context supplied by a metric widget. This lives with
    // the history instead of being squeezed into the ring's centre caption.
    // Entries are { label, value }; an empty list preserves the classic gauge.
    property var detailItems: []
    property string historyCaption: ""
    // Consumers with information-dense cards may raise these two tokens without
    // forking the shared gauge. The row height follows the text, so increased
    // legibility cannot turn into clipping at larger accessibility scales.
    property real detailLabelPixelSize: theme.fontMinimum
    property real detailValuePixelSize: theme.fontLabel
    property color detailLabelColor: theme.textTertiary
    property color historyCaptionColor: theme.textTertiary
    property color subTextColor: theme.textSecondary
    property real historyCaptionPixelSize: theme.fontMinimum
    // A consumer can trade one horizontal strip for a denser but wider grid.
    // Zero keeps the legacy one-row behavior. CPU uses two columns because four
    // narrow cards made ordinary values such as "rustc 18%" truncate.
    property int horizontalDetailColumns: 0
    // Explicit column count for consumers whose value width matters more than
    // the default shape-derived grid. This applies in both stacked and
    // side-by-side layouts. Zero preserves the legacy choice below.
    property int detailColumns: 0
    readonly property int effectiveDetailColumns: {
        var count = detailItems ? detailItems.length : 0
        if (detailColumns > 0)
            return Math.max(1, Math.min(detailColumns, count))
        if (!horizontal) return 2
        if (horizontalDetailColumns > 0)
            return Math.max(1, Math.min(horizontalDetailColumns, count))
        return Math.max(1, count)
    }
    readonly property int effectiveDetailRows:
        Math.max(1, Math.ceil((detailItems ? detailItems.length : 0)
                             / effectiveDetailColumns))
    readonly property real detailRowHeight:
        Math.max(52, detailLabelPixelSize + detailValuePixelSize + 19)
    readonly property real historySlotMinimumHeight: {
        var height = theme.fontMinimum + 8
        var visibleSections = 1
        if (detailItems && detailItems.length > 0) {
            height += detailRowHeight * effectiveDetailRows
                    + theme.spacingXs * Math.max(0, effectiveDetailRows - 1)
            visibleSections += 1
        }
        if (historyCaption.length > 0) {
            height += historyCaptionPixelSize + 8
            visibleSections += 1
        }
        return height + theme.spacingXs * Math.max(0, visibleSections - 1)
    }

    // Per-size layout knobs (see header note). Defaults = the original layout.
    property bool showSpark: true
    property bool horizontal: false
    property real sparkFrac: 0.17
    // Tall tiles: pin the ring to a square cell at the top and hand the
    // sparkline ALL the remaining height - history earns the height, and the
    // ring no longer floats in a stretched void. Only meaningful stacked.
    property bool sparkFills: false
    property real stackedRingMaxFraction: 0.62
    // Cap for the centre value font when collapsed (micro tiles raise it so the
    // one number actually fills its headerless box).
    property real bigMax: 60

    // Threshold escalation (accent → warning → error) cross-fades the ring, the
    // big number and the sparkline together instead of hard-cutting all three.
    // Collapses to an instant cut under reduce-motion (motionValue token → 0).
    Behavior on color { ColorAnimation { duration: theme.motionValue } }

    // ring.width is 0 until the layout settles; fall back to the gauge's own
    // size so centre text is never rendered at 0px (invisible) on the 1st frame.
    readonly property real _ringW: ring.width > 0 ? ring.width : Math.min(g.width, g.height)

    GridLayout {
        anchors.fill: parent
        anchors.margins: g.expanded ? theme.spacingMd : theme.spacingXs
        columns: g.horizontal ? 2 : 1
        rowSpacing: g.expanded ? theme.spacingMd : theme.spacingSm
        columnSpacing: theme.spacingMd

        // Ring + centred value fills the bulk of the tile (all of it at micro).
        Item {
            id: ringCell
            readonly property bool square: g.sparkFills && !g.horizontal && g.showSpark
            Layout.fillWidth: !g.horizontal
            Layout.fillHeight: !square
            // Side-by-side: the ring takes a square cell sized by the box height
            // (capped at ~2/5 of the width so the sparkline keeps the majority).
            Layout.preferredWidth: g.horizontal ? Math.round(Math.min(g.height, g.width * 0.42)) : -1
            // Tall: a square cell up top; the sparkline below takes the rest.
            Layout.preferredHeight: square
                ? Math.round(Math.min(g.width, g.height * g.stackedRingMaxFraction)) : -1
            RingProgress {
                id: ring
                anchors.centerIn: parent
                width: Math.min(parent.width, parent.height) * 0.96
                height: width
                value: g.ok ? Math.max(0, Math.min(1, g.value)) : 0
                // Metric samples land every ~2s; glide the sweep between them so
                // a CPU/GPU/RAM tick reads as movement, not a redraw. (Instant
                // under reduce-motion via the motionValue token.)
                animateValue: true
                thickness: Math.max(9, width * 0.10)
                progressColor: g.color
                progressColor2: g.color
                trackColor: Qt.rgba(theme.cardBorder.r, theme.cardBorder.g, theme.cardBorder.b, 0.6)
            }
            ColumnLayout {
                anchors.centerIn: parent
                spacing: 0
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: g.big
                    // Cap the value to the ring's INNER diameter and shrink to fit.
                    // The system tiles only ever pass short readings ("42%", "N/A"),
                    // which never reach the cap; an HTTP/JSON gauge shows arbitrary
                    // values ("128ms"), which used to spill out over the ring.
                    // `Layout.maximumWidth` ALONE is a cap the layout ignores when the
                    // Text's implicitWidth already exceeds it - the Text keeps its
                    // natural width, and with it `HorizontalFit` and `elide` both go
                    // inert, because each needs a real box to fit INTO. Pairing it with
                    // `preferredWidth` forces the layout to allocate exactly that box.
                    // Same fix as CountdownWidget's overflowing number.
                    Layout.preferredWidth: Math.max(24, g._ringW - 2 * ring.thickness - 8)
                    Layout.maximumWidth: Math.max(24, g._ringW - 2 * ring.thickness - 8)
                    // The box above spans the ring's inner width so the value can
                    // shrink-to-fit; the TEXT must centre WITHIN that box, or it
                    // left-aligns inside a wide box and sits off-centre in the ring.
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: Math.min(g._ringW * 0.34, g.expanded ? 108 : g.bigMax)
                    fontSizeMode: Text.HorizontalFit
                    minimumPixelSize: theme.fontMinimum
                    elide: Text.ElideRight
                    font.bold: true; font.family: theme.fontMono
                    color: g.ok ? g.color : theme.textTertiary
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    visible: g.sub.length > 0
                    text: g.sub
                    // Paired for the same reason as the value above: maximumWidth
                    // alone is ignored once implicitWidth exceeds it, taking
                    // HorizontalFit and elide down with it.
                    Layout.preferredWidth: Math.max(24, g._ringW - 2 * ring.thickness - 8)
                    Layout.maximumWidth: Math.max(24, g._ringW - 2 * ring.thickness - 8)
                    horizontalAlignment: Text.AlignHCenter   // centre within the wide box
                    // Scale gently with the ring so a big tall-tile ring doesn't
                    // caption itself in 14px dust.
                    font.pixelSize: g.expanded ? theme.fontTitle
                                               : Math.max(theme.fontMinimum,
                                                          Math.min(g._ringW * 0.075, theme.fontLabel))
                    fontSizeMode: Text.HorizontalFit
                    minimumPixelSize: theme.fontMinimum
                    elide: Text.ElideRight
                    color: g.subTextColor
                }
            }
        }

        // History sparkline - under the ring (stacked) or beside it (wide). The
        // stacked slot always reserves its height (even while the sparkline
        // itself is hidden) so the fillHeight ring above does not visibly shrink
        // when the sparkline pops in at the 2nd sample.
        Item {
            visible: g.showSpark
            Layout.fillWidth: true
            Layout.fillHeight: g.horizontal || (g.sparkFills && !g.horizontal)
            Layout.preferredHeight: (g.horizontal || g.sparkFills) ? -1
                                  : Math.max(g.historySlotMinimumHeight,
                                             g.expanded ? 110
                                                        : Math.max(30, g.height * g.sparkFrac))
            ColumnLayout {
                anchors.fill: parent
                spacing: theme.spacingXs

                GridLayout {
                    id: metricDetailStrip
                    objectName: "metricDetailStrip"
                    visible: g.detailItems && g.detailItems.length > 0
                    Layout.fillWidth: true
                    columns: g.effectiveDetailColumns
                    rows: g.effectiveDetailRows
                    Layout.minimumHeight: visible
                        ? g.detailRowHeight * g.effectiveDetailRows
                          + rowSpacing * Math.max(0, g.effectiveDetailRows - 1)
                        : 0
                    Layout.preferredHeight: Layout.minimumHeight
                    Layout.maximumHeight: Layout.minimumHeight
                    rowSpacing: theme.spacingXs
                    columnSpacing: theme.spacingXs
                    Repeater {
                        model: g.detailItems || []
                        delegate: Rectangle {
                            required property var modelData
                            required property int index
                            objectName: "metricDetailCard_" + index
                            Layout.fillWidth: true
                            Layout.preferredHeight: g.detailRowHeight
                            radius: theme.radiusSm
                            color: Qt.rgba(theme.cardBackgroundAlt.r,
                                           theme.cardBackgroundAlt.g,
                                           theme.cardBackgroundAlt.b, 0.72)
                            border.width: 1
                            border.color: theme.cardBorder
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 6
                                spacing: 1
                                Text {
                                    objectName: "metricDetailLabel_" + index
                                    Layout.fillWidth: true
                                    text: modelData.label || ""
                                    color: g.detailLabelColor
                                    font.pixelSize: g.detailLabelPixelSize
                                    font.bold: true
                                    font.letterSpacing: 0.7
                                    elide: Text.ElideRight
                                }
                                Text {
                                    objectName: "metricDetailValue_" + index
                                    Layout.fillWidth: true
                                    text: modelData.value || "-"
                                    color: theme.textPrimary
                                    font.pixelSize: g.detailValuePixelSize
                                    font.weight: Font.DemiBold
                                    font.family: theme.fontMono
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }
                }

                Text {
                    visible: g.historyCaption.length > 0
                    Layout.fillWidth: true
                    text: g.historyCaption
                    color: g.historyCaptionColor
                    font.pixelSize: g.historyCaptionPixelSize
                    font.bold: true
                    font.letterSpacing: 0.8
                    elide: Text.ElideRight
                }

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Sparkline {
                        anchors.fill: parent
                        values: g.history
                        color: g.color
                        visible: g.ok && g.history && g.history.length > 1
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: g.ok && (!g.history || g.history.length < 2)
                        text: "Building history"
                        color: theme.textTertiary
                        font.pixelSize: theme.fontMinimum
                    }
                }
            }
        }
    }
}

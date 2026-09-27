import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

// ─────────────────────────────────────────────────────────────────────────
// HumbleBooksWidget - monitors active book, comic, sci-fi, and cookbook
// bundles on Humble Bundle with live countdowns, cover art, tier values,
// and category filters (Tech, Comics, SF, Cookbooks, Other).
//
// Egress is gated exclusively through NetHub; bundle metadata is parsed
// from the public landing page without tracking, cookies, or user credentials.
// Multiple widget instances share cached bundle data via "humble-books-v1".
// ─────────────────────────────────────────────────────────────────────────
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""
    property int tick: 0
    property double nowMsOverride: -1

    // Egress gate: injected by Dashboard, fallback for standalone/tests.
    property var netHub: null
    NetHub { id: _fallbackHub }
    function _hub() { return netHub ? netHub : _fallbackHub }

    // Test seams for offline deterministic testing and external URL dispatch
    property var xhrFactory: null
    property var externalOpener: function(url) { return Qt.openUrlExternally(url) }

    title: "Humble Books"
    iconName: "humblebooks"
    accentColor: theme.catEntertainment
    showHeader: !micro

    Accessible.name: "Humble Bundle Book Monitor"
    Accessible.description: w.filteredBundles.length === 0
        ? "No active book bundles"
        : (w.filteredBundles.length + " " + (w.activeCategory === "all" ? "bundles" : w.activeCategory + " bundles") + " available")

    // ── Live per-instance config ─────────────────────────────────────────────
    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    readonly property string configuredCategory: (cfg && cfg.category) ? String(cfg.category).toLowerCase() : "all"
    readonly property int pollHours: Math.max(1, Math.min(24, Number((cfg && cfg.pollHours !== undefined) ? cfg.pollHours : 2)))

    // Active category filter on the widget (defaults to configuredCategory, user can toggle live)
    property string activeCategory: configuredCategory
    onConfiguredCategoryChanged: {
        w.activeCategory = w.configuredCategory
    }

    // ── State ────────────────────────────────────────────────────────────────
    property var bundles: []
    property bool loading: false
    property string errorText: ""
    property string stateHelp: ""
    property double lastSuccessAt: 0
    property int _seq: 0
    property var _xhr: null
    property var selectedBundle: null

    readonly property string sharedKind: "humble-books-v1"
    readonly property string sharedKey: "books"
    readonly property string url: "https://www.humblebundle.com/books"

    function currentMs() { return w.nowMsOverride >= 0 ? w.nowMsOverride : Date.now() }

    // ── Classification ───────────────────────────────────────────────────────
    function classify(prod) {
        if (!prod) return "Other"
        var name = (prod.tile_name || "") + " " + (prod.tile_short_name || "")
        var nameLower = name.toLowerCase()
        var stamp = (prod.tile_stamp || "").toLowerCase()
        var blurb = (prod.short_marketing_blurb || "") + " " + (prod.marketing_blurb || "")
        var blurbLower = blurb.toLowerCase()
        var allText = nameLower + " " + blurbLower

        // 1. Comics & Graphic Novels
        if (nameLower.indexOf("comic") >= 0 || stamp === "comics"
                || nameLower.indexOf("manga") >= 0
                || allText.indexOf("graphic novel") >= 0) {
            return "Comics"
        }

        // 2. Tech / Programming / Engineering / Cloud
        var techKeywords = [
            "tech book", "programming", "programmer", "software", "linux", "cloud",
            "cybersecurity", "python", "c++", "coding", "web dev", "ai in production",
            "creative bundle", "data science", "it & security", "devops", "code faster",
            "no starch", "packt", "o'reilly", "manning", "computer"
        ]
        for (var i = 0; i < techKeywords.length; i++) {
            if (nameLower.indexOf(techKeywords[i]) >= 0) return "Tech"
        }

        // 3. Cookbooks / Culinary / Baking / Food
        var cookKeywords = [
            "cookbook", "cooking", "recipes", "baking", "keto", "kitchen", "food",
            "culinary", "protein", "diet"
        ]
        for (var j = 0; j < cookKeywords.length; j++) {
            if (nameLower.indexOf(cookKeywords[j]) >= 0) return "Cookbooks"
        }

        // 4. Sci-Fi & Fantasy (SF)
        var sfKeywords = [
            "sci-fi", "science fiction", "fantasy", "space opera", "dystopian",
            "forever war", "worlds of"
        ]
        for (var k = 0; k < sfKeywords.length; k++) {
            if (nameLower.indexOf(sfKeywords[k]) >= 0 || blurbLower.indexOf(sfKeywords[k]) >= 0)
                return "SF"
        }
        var sfAuthors = [
            "timothy zahn", "greg bear", "c.j. cherryh", "cj cherryh", "joe haldeman",
            "brian w. aldiss", "brian aldiss", "arthur c. clarke", "isaac asimov",
            "philip k. dick", "ursula", "robert heinlein", "brandon sanderson", "neil gaiman"
        ]
        for (var a = 0; a < sfAuthors.length; a++) {
            if (nameLower.indexOf(sfAuthors[a]) >= 0 || blurbLower.indexOf(sfAuthors[a]) >= 0)
                return "SF"
        }

        // 5. Other (Tabletop RPGs, Game Dev, Art, and general)
        return "Other"
    }

    function extractItemCount(highlights) {
        if (!Array.isArray(highlights)) return ""
        for (var i = 0; i < highlights.length; i++) {
            var h = String(highlights[i]).trim()
            if (/\b\d+\s+(comics?|books?|items?|titles?|novels?)\b/i.test(h)) {
                return h
            }
        }
        return ""
    }

    function extractValue(highlights) {
        if (!Array.isArray(highlights)) return ""
        for (var i = 0; i < highlights.length; i++) {
            var h = String(highlights[i]).trim()
            if (/(\$|€|£|\bValue\b)/i.test(h) && /\d+/.test(h)) {
                return h
            }
        }
        return ""
    }

    function extractTierPrice(highlights) {
        if (!Array.isArray(highlights)) return ""
        for (var i = 0; i < highlights.length; i++) {
            var h = String(highlights[i]).trim()
            if (/pay what you want/i.test(h)) return "Pay What You Want"
            if (/^from\s+[\$€£]/i.test(h)) return h
        }
        return "Pay What You Want"
    }

    function formatTimeRemaining(endStr, nowMs) {
        if (!endStr) return ""
        var endD = new Date(endStr)
        if (isNaN(endD.getTime())) return ""
        var now = (nowMs !== undefined && nowMs >= 0) ? nowMs : w.currentMs()
        var diffMs = endD.getTime() - now
        if (diffMs <= 0) return "Ended"
        var diffHours = Math.floor(diffMs / 3600000)
        var diffDays = Math.floor(diffHours / 24)
        if (diffDays >= 2) return diffDays + "d left"
        if (diffDays === 1) return "1d " + (diffHours % 24) + "h left"
        if (diffHours >= 1) return diffHours + "h left"
        var diffMinutes = Math.floor(diffMs / 60000)
        return Math.max(1, diffMinutes) + "m left"
    }

    function parseHumbleHtml(html) {
        if (!html || typeof html !== "string") return []
        var rawJson = ""
        var startTag = '<script id="landingPage-json-data" type="application/json">'
        var idx = html.indexOf(startTag)
        if (idx >= 0) {
            var endIdx = html.indexOf("</script>", idx + startTag.length)
            if (endIdx > idx) {
                rawJson = html.substring(idx + startTag.length, endIdx)
            }
        } else {
            var m = html.match(/<script\s+[^>]*id=["']landingPage-json-data["'][^>]*>([\s\S]*?)<\/script>/i)
            if (m && m[1]) rawJson = m[1]
        }
        if (!rawJson) return []

        try {
            var rootData = JSON.parse(rawJson)
            var prods = (rootData.data && rootData.data.books && rootData.data.books.mosaic
                         && rootData.data.books.mosaic[0] && rootData.data.books.mosaic[0].products)
                        ? rootData.data.books.mosaic[0].products : []
            var result = []
            for (var i = 0; i < prods.length; i++) {
                var p = prods[i]
                if (!p) continue
                var cat = classify(p)
                var rawTitle = p.tile_short_name || p.tile_name || "Book Bundle"
                // Clean redundant bundle prefixes if present
                var cleanTitle = rawTitle.replace(/^Humble\s+[^:]+\s+Bundle:\s*/i, "")
                var pUrl = p.product_url ? String(p.product_url).trim() : ""
                var fullUrl = pUrl.indexOf("http") === 0
                              ? pUrl
                              : ("https://www.humblebundle.com" + (pUrl.indexOf("/") === 0 ? "" : "/") + pUrl)

                var endRaw = p["end_date|datetime"] || ""
                var timeRem = formatTimeRemaining(endRaw, w.currentMs())
                var imgUrl = p.high_res_tile_image || p.tile_image || ""
                var hl = p.highlights || []

                result.push({
                    id: p.machine_name || ("bundle_" + i),
                    title: cleanTitle,
                    fullName: p.tile_name || rawTitle,
                    category: cat,
                    url: fullUrl,
                    imageUrl: imgUrl,
                    endDate: endRaw,
                    timeRemainingText: timeRem,
                    highlights: hl,
                    itemCountText: extractItemCount(hl),
                    valueText: extractValue(hl),
                    tierPriceText: extractTierPrice(hl),
                    blurb: p.short_marketing_blurb || p.marketing_blurb || ""
                })
            }
            return result
        } catch (e) {
            return []
        }
    }

    // ── Filtered bundles ─────────────────────────────────────────────────────
    readonly property var filteredBundles: {
        var list = w.bundles || []
        var cat = (w.activeCategory || "all").toLowerCase()
        if (cat === "all") return list
        var out = []
        for (var i = 0; i < list.length; i++) {
            if (String(list[i].category).toLowerCase() === cat) {
                out.push(list[i])
            }
        }
        return out
    }

    function countForCategory(catName) {
        var list = w.bundles || []
        var target = String(catName).toLowerCase()
        if (target === "all") return list.length
        var c = 0
        for (var i = 0; i < list.length; i++) {
            if (String(list[i].category).toLowerCase() === target) c++
        }
        return c
    }

    function openBundle(bundle) {
        if (!bundle || !bundle.url) return
        if (w.externalOpener) w.externalOpener(bundle.url)
    }

    // ── Shared Provider Sync ─────────────────────────────────────────────────
    function _syncShared() {
        var hub = w._hub()
        if (!hub || !hub.sharedProvider) return
        var entry = hub.sharedProvider(w.sharedKind, w.sharedKey)
        if (!entry) return
        if (entry.bundles !== undefined) w.bundles = entry.bundles
        if (entry.errorText !== undefined) w.errorText = entry.errorText
        if (entry.stateHelp !== undefined) w.stateHelp = entry.stateHelp
        if (entry.lastSuccessAt !== undefined) w.lastSuccessAt = entry.lastSuccessAt
        w.loading = !!entry.loading
    }

    Connections {
        target: w._hub()
        function onSharedRevisionChanged() { w._syncShared() }
    }

    Component.onDestruction: {
        if (_xhr) _xhr.abort()
        if (w._hub().releaseSharedProvider)
            w._hub().releaseSharedProvider(w.sharedKind, w.sharedKey, w, "")
    }

    function refresh(force) {
        var forceNow = force === undefined ? true : !!force
        if (_xhr) _xhr.abort()
        w._xhr = null

        var hub = w._hub()
        var maxAgeMs = Math.max(300000, w.pollHours * 3600000)
        if (hub.claimSharedProvider
                && !hub.claimSharedProvider(w.sharedKind, w.sharedKey, w,
                                            forceNow ? 0 : maxAgeMs)) {
            w._syncShared()
            return
        }

        w.loading = true
        w.stateHelp = ""
        var seq = ++w._seq
        var xhr = hub.request({
            url: w.url,
            timeout: 15000,
            maxResponseBytes: 2097152,
            xhrFactory: w.xhrFactory,
            onDone: function (status, body) {
                if (seq !== w._seq) return
                w._xhr = null
                w.loading = false
                try {
                    if (status >= 200 && status < 300) {
                        var parsed = w.parseHumbleHtml(body)
                        w.bundles = parsed
                        w.errorText = ""
                        w.stateHelp = parsed.length
                            ? "Active book bundles updated."
                            : "Connected to Humble Bundle, but no active book bundles were found."
                        w.lastSuccessAt = w.currentMs()
                        if (hub.publishSharedProvider) {
                            hub.publishSharedProvider(w.sharedKind, w.sharedKey, w, {
                                bundles: w.bundles,
                                errorText: "",
                                stateHelp: w.stateHelp,
                                lastSuccessAt: w.lastSuccessAt
                            })
                        }
                    } else if (status === 0) {
                        w.errorText = "Offline or request blocked."
                        w.stateHelp = "Check network connection or offline settings."
                        if (hub.releaseSharedProvider)
                            hub.releaseSharedProvider(w.sharedKind, w.sharedKey, w, w.errorText)
                    } else {
                        w.errorText = "HTTP error " + status
                        w.stateHelp = "Humble Bundle returned status " + status
                        if (hub.releaseSharedProvider)
                            hub.releaseSharedProvider(w.sharedKind, w.sharedKey, w, w.errorText)
                    }
                } catch (err) {
                    w.errorText = "Parse error"
                    w.stateHelp = err ? String(err.message || err) : "Unknown error"
                    if (hub.releaseSharedProvider)
                        hub.releaseSharedProvider(w.sharedKind, w.sharedKey, w, w.errorText)
                }
            }
        })
        w._xhr = xhr
    }

    Component.onCompleted: {
        _syncShared()
        if (w.bundles.length === 0) w.refresh(false)
    }

    // Refresh on tick intervals matching pollHours
    onTickChanged: {
        if (!w.active) return
        var now = w.currentMs()
        var maxAgeMs = Math.max(300000, w.pollHours * 3600000)
        if (w.bundles.length === 0 || (now - w.lastSuccessAt >= maxAgeMs)) {
            w.refresh(false)
        }
    }

    // Status in header
    status: {
        if (w.loading) return "Updating…"
        if (w.errorText.length > 0 && w.bundles.length === 0) return "Offline"
        var count = w.filteredBundles.length
        return count + (count === 1 ? " bundle" : " bundles")
    }
    statusColor: w.errorText.length > 0 && w.bundles.length === 0 ? theme.warning : theme.textSecondary

    // ── Category Definitions ─────────────────────────────────────────────────
    readonly property var categoryList: [
        { key: "all", label: "All" },
        { key: "tech", label: "Tech" },
        { key: "comics", label: "Comics" },
        { key: "sf", label: "SF" },
        { key: "cookbooks", label: "Cookbooks" },
        { key: "other", label: "Other" }
    ]

    // ── UI Content ───────────────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: w.contentMargins
        spacing: theme.spacingSm

        // 1. Category Filter Pill Row (Scrollable / Flickable for all screen widths)
        Item {
            Layout.fillWidth: true
            implicitHeight: Math.max(44, theme.touchTertiary)
            visible: !w.micro

            Flickable {
                id: pillFlick
                anchors.fill: parent
                contentWidth: pillRow.width
                contentHeight: height
                flickableDirection: Flickable.HorizontalFlick
                boundsBehavior: Flickable.StopAtBounds
                clip: true

                RowLayout {
                    id: pillRow
                    height: parent.height
                    spacing: theme.spacingXs

                    Repeater {
                        model: w.categoryList
                        delegate: Rectangle {
                            id: catPill
                            required property var modelData
                            readonly property bool isSelected: w.activeCategory.toLowerCase() === modelData.key.toLowerCase()
                            readonly property int itemCount: w.countForCategory(modelData.key)

                            implicitHeight: Math.max(44, theme.touchTertiary)
                            implicitWidth: Math.max(56, pillText.implicitWidth + countBadge.implicitWidth + theme.spacingLg)
                            radius: height / 2

                            color: isSelected ? w.effAccent : Qt.rgba(255, 255, 255, 0.06)
                            border.width: activeFocus ? 2 : 1
                            border.color: activeFocus ? theme.textPrimary : (isSelected ? w.effAccent : theme.cardBorder)

                            activeFocusOnTab: true
                            Accessible.role: Accessible.RadioButton
                            Accessible.name: modelData.label + " (" + itemCount + ")"
                            Accessible.checked: isSelected
                            Accessible.onPressAction: w.activeCategory = modelData.key

                            Keys.onPressed: function(event) {
                                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                                    w.activeCategory = modelData.key
                                    event.accepted = true
                                }
                            }

                            RowLayout {
                                anchors.centerIn: parent
                                spacing: 4

                                Text {
                                    id: pillText
                                    text: catPill.modelData.label
                                    color: catPill.isSelected ? "#0D1117" : theme.textPrimary
                                    font.pixelSize: theme.fontCaption
                                    font.weight: catPill.isSelected ? Font.DemiBold : Font.Normal
                                }

                                Text {
                                    id: countBadge
                                    text: catPill.itemCount > 0 ? ("(" + catPill.itemCount + ")") : ""
                                    color: catPill.isSelected ? "#0D1117" : theme.textSecondary
                                    font.pixelSize: theme.fontCaption - 1
                                    visible: catPill.itemCount > 0
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    catPill.forceActiveFocus()
                                    w.activeCategory = catPill.modelData.key
                                }
                            }
                        }
                    }
                }
            }
        }

        // 2. Main Bundle Content Area
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            // Loading state
            ColumnLayout {
                anchors.centerIn: parent
                spacing: theme.spacingMd
                visible: w.loading && w.bundles.length === 0

                BusyIndicator {
                    Layout.alignment: Qt.AlignHCenter
                    running: true
                }
                Text {
                    text: "Checking Humble Bundle…"
                    color: theme.textSecondary
                    font.pixelSize: theme.fontLabel
                    Layout.alignment: Qt.AlignHCenter
                }
            }

            // Error / Offline State with Retry Button
            ColumnLayout {
                anchors.centerIn: parent
                spacing: theme.spacingMd
                visible: !w.loading && w.errorText.length > 0 && w.bundles.length === 0
                width: Math.min(parent.width - 32, 400)

                Text {
                    text: w.errorText
                    color: theme.warning
                    font.pixelSize: theme.fontTitle
                    font.weight: Font.DemiBold
                    horizontalAlignment: Text.AlignHCenter
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                }
                Text {
                    text: w.stateHelp || "Unable to load active book bundles."
                    color: theme.textSecondary
                    font.pixelSize: theme.fontLabel
                    horizontalAlignment: Text.AlignHCenter
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                }
                Rectangle {
                    Layout.alignment: Qt.AlignHCenter
                    implicitHeight: Math.max(44, theme.touchTertiary)
                    implicitWidth: 120
                    radius: theme.radiusMd
                    color: w.effAccent
                    activeFocusOnTab: true
                    Accessible.role: Accessible.Button
                    Accessible.name: "Retry loading Humble Bundles"
                    Accessible.onPressAction: w.refresh(true)

                    Text {
                        anchors.centerIn: parent
                        text: "Retry"
                        color: "#0D1117"
                        font.pixelSize: theme.fontLabel
                        font.weight: Font.DemiBold
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: w.refresh(true)
                    }
                }
            }

            // Empty state (Category has 0 bundles)
            ColumnLayout {
                anchors.centerIn: parent
                spacing: theme.spacingMd
                visible: !w.loading && w.bundles.length > 0 && w.filteredBundles.length === 0
                width: Math.min(parent.width - 32, 360)

                Text {
                    text: "No " + w.activeCategory.toUpperCase() + " bundles right now."
                    color: theme.textPrimary
                    font.pixelSize: theme.fontLabel
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    Layout.fillWidth: true
                }
                Rectangle {
                    Layout.alignment: Qt.AlignHCenter
                    implicitHeight: Math.max(44, theme.touchTertiary)
                    implicitWidth: 140
                    radius: theme.radiusMd
                    color: Qt.rgba(255, 255, 255, 0.1)
                    border.width: 1
                    border.color: theme.cardBorder
                    activeFocusOnTab: true
                    Accessible.role: Accessible.Button
                    Accessible.name: "Show all bundles"
                    Accessible.onPressAction: w.activeCategory = "all"

                    Text {
                        anchors.centerIn: parent
                        text: "Show All Bundles"
                        color: theme.textPrimary
                        font.pixelSize: theme.fontCaption
                        font.weight: Font.DemiBold
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: w.activeCategory = "all"
                    }
                }
            }

            // Bundles List (ListView with smooth touch scrolling and cards)
            ListView {
                id: bundleListView
                anchors.fill: parent
                model: w.filteredBundles
                spacing: theme.spacingSm
                visible: w.filteredBundles.length > 0
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                    id: card
                    required property var modelData
                    width: bundleListView.width
                    implicitHeight: Math.max(76, cardRow.implicitHeight + 16)
                    radius: theme.radiusMd
                    color: cardArea.containsMouse ? Qt.rgba(255, 255, 255, 0.08) : Qt.rgba(255, 255, 255, 0.04)
                    border.width: activeFocus ? 2 : 1
                    border.color: activeFocus ? theme.textPrimary : theme.cardBorder

                    activeFocusOnTab: true
                    Accessible.role: Accessible.Button
                    Accessible.name: modelData.title + ", " + modelData.category + ", " + modelData.timeRemainingText
                    Accessible.description: modelData.itemCountText + " " + modelData.valueText
                    Accessible.onPressAction: w.openBundle(modelData)

                    Keys.onPressed: function(event) {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                            w.openBundle(modelData)
                            event.accepted = true
                        }
                    }

                    RowLayout {
                        id: cardRow
                        anchors.fill: parent
                        anchors.margins: 8
                        spacing: theme.spacingSm

                        // Cover Image Thumbnail
                        Rectangle {
                            Layout.preferredWidth: w.micro ? 60 : (w.big ? 110 : 80)
                            Layout.fillHeight: true
                            radius: theme.radiusSm
                            color: Qt.rgba(0, 0, 0, 0.3)
                            clip: true

                            Image {
                                anchors.fill: parent
                                source: card.modelData.imageUrl
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                visible: status === Image.Ready
                            }

                            // Fallback icon if image is loading or failed
                            AppIcon {
                                anchors.centerIn: parent
                                name: "humblebooks"
                                size: 24
                                tint: theme.textSecondary
                                opacity: 0.5
                            }
                        }

                        // Bundle Details
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: 3

                            // Category badge & Time remaining row
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 6

                                Rectangle {
                                    implicitHeight: 20
                                    implicitWidth: catLabel.implicitWidth + 10
                                    radius: 10
                                    color: Qt.rgba(255, 255, 255, 0.1)

                                    Text {
                                        id: catLabel
                                        anchors.centerIn: parent
                                        text: card.modelData.category
                                        color: w.effAccent
                                        font.pixelSize: theme.fontCaption - 2
                                        font.weight: Font.DemiBold
                                    }
                                }

                                Text {
                                    text: card.modelData.timeRemainingText
                                    color: (card.modelData.timeRemainingText.indexOf("h left") >= 0
                                            || card.modelData.timeRemainingText === "1d left")
                                           ? theme.warning : theme.textSecondary
                                    font.pixelSize: theme.fontCaption - 1
                                    font.weight: Font.Medium
                                }

                                Item { Layout.fillWidth: true }

                                // Open Arrow / Glyph
                                Text {
                                    text: "↗"
                                    color: theme.textSecondary
                                    font.pixelSize: theme.fontLabel
                                    visible: !w.micro
                                }
                            }

                            // Title
                            Text {
                                text: card.modelData.title
                                color: theme.textPrimary
                                font.pixelSize: w.big ? theme.fontLabel : theme.fontCaption
                                font.weight: Font.DemiBold
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                maximumLineCount: w.big ? 2 : 1
                                wrapMode: Text.WordWrap
                            }

                            // Meta Row: Items count + Value
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                visible: !w.micro

                                Text {
                                    text: card.modelData.itemCountText
                                    color: theme.textPrimary
                                    font.pixelSize: theme.fontCaption - 1
                                    visible: card.modelData.itemCountText.length > 0
                                }

                                Text {
                                    text: "•"
                                    color: theme.textSecondary
                                    font.pixelSize: theme.fontCaption - 2
                                    visible: card.modelData.itemCountText.length > 0 && card.modelData.valueText.length > 0
                                }

                                Text {
                                    text: card.modelData.valueText
                                    color: theme.textSecondary
                                    font.pixelSize: theme.fontCaption - 1
                                    visible: card.modelData.valueText.length > 0
                                }

                                Item { Layout.fillWidth: true }

                                Text {
                                    text: card.modelData.tierPriceText
                                    color: w.effAccent
                                    font.pixelSize: theme.fontCaption - 1
                                    font.weight: Font.Medium
                                    visible: card.modelData.tierPriceText.length > 0 && w.big
                                }
                            }
                        }
                    }

                    MouseArea {
                        id: cardArea
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        hoverEnabled: true
                        onClicked: {
                            card.forceActiveFocus()
                            w.openBundle(card.modelData)
                        }
                    }
                }
            }
        }
    }
}

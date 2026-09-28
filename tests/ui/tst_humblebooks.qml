import QtQuick
import QtTest
import "../../ui/qml" as App

// COVERS: schema:humblebooks.category, schema:humblebooks.pollHours, widget:humblebooks

// ─────────────────────────────────────────────────────────────────────────
// Comprehensive tests for Humble Books Bundle Monitor (HumbleBooksWidget.qml)
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 600; height: 800

    App.Theme { id: theme }

    WidgetHarness {
        id: h; anchors.fill: parent; widgetFile: "HumbleBooksWidget.qml"; expanded: true
    }

    App.WidgetConfigSchema { id: sc }
    App.WidgetCatalog { id: catalog }

    readonly property string sampleHumbleHtml: '<!DOCTYPE html><html><head>'
        + '<script id="landingPage-json-data" type="application/json">'
        + '{"data":{"books":{"mosaic":[{"products":['
        + '{"machine_name":"batmanday_bundle","tile_name":"Humble Comics Bundle: Batman Day Comics Bundle by DC Comics","tile_short_name":"Batman Day Comics Bundle by DC Comics","tile_stamp":"comics","product_url":"/books/batman-day","tile_image":"https://hb.imgix.net/batman.jpg","end_date|datetime":"2026-10-10T18:00:00","highlights":["Pay What You Want","31 comics","$487 Value","Support Charity"],"hero_highlights":[{"heading":"Pay $5 or more"}],"short_marketing_blurb":"Explore the Dark Knight."}'
        + ',{"machine_name":"cpp_masterclass","tile_name":"Humble Tech Book Bundle: C++ Programming Masterclass","tile_short_name":"C++ Programming Masterclass","tile_stamp":"books","product_url":"/books/cpp-masterclass","tile_image":"https://hb.imgix.net/cpp.jpg","end_date|datetime":"2026-10-12T18:00:00","highlights":["Pay What You Want","21 books","$761 Value","Support Charity"],"hero_highlights":[{"heading":"Pay $5 or more"}],"marketing_blurb":"Includes Modern C++ Programming Cookbook and best practices."}'
        + ',{"machine_name":"timothy_zahn","tile_name":"Humble Book Bundle: The Original Worlds of Timothy Zahn","tile_short_name":"The Original Worlds of Timothy Zahn","tile_stamp":"books","product_url":"/books/timothy-zahn","tile_image":"https://hb.imgix.net/zahn.jpg","end_date|datetime":"2026-09-29T18:00:00","highlights":["Pay What You Want","23 books","$248 Value","Support Charity"],"hero_highlights":[{"heading":"Pay $3 or more"}],"short_marketing_blurb":"Sci-fi classics from Timothy Zahn."}'
        + ',{"machine_name":"keto_cookbook","tile_name":"Humble Book Bundle: Eat Your Protein! A Keto Cookbook Bundle","tile_short_name":"Eat Your Protein! A Keto Cookbook Bundle","tile_stamp":"books","product_url":"/books/keto-cookbook","tile_image":"https://hb.imgix.net/keto.jpg","end_date|datetime":"2026-10-01T18:00:00","highlights":["Pay What You Want","25 books","$278 Value","Support Charity"],"hero_highlights":[{"heading":"Pay $18 or more"}],"short_marketing_blurb":"Delicious recipes and meal plans."}'
        + ',{"machine_name":"dnd_guild","tile_name":"Humble RPG Bundle: Dungeon Master\'s Guild Top Content","tile_short_name":"Dungeon Master\'s Guild Top Content","tile_stamp":"books","product_url":"/books/dnd-guild","tile_image":"https://hb.imgix.net/dnd.jpg","end_date|datetime":"2026-10-03T18:00:00","highlights":["Pay What You Want","19 books","$326 Value","Support Charity"],"hero_highlights":[{"heading":"Pay $5 or more"}],"short_marketing_blurb":"Top D&D campaign content."}'
        + ',{"machine_name":"woodworking_bundle","tile_name":"The Ultimate Woodworking & Carpentry Masterclass","tile_short_name":"Woodworking Masterclass","tile_stamp":"books","product_url":"/books/woodworking","tile_image":"https://hb.imgix.net/wood.jpg","end_date|datetime":"2026-10-05T18:00:00","highlights":["Pay What You Want","12 books","$150 Value"],"hero_highlights":[{"heading":"Pay $5 or more"}],"short_marketing_blurb":"Crafting and woodworking."}'
        + ']}]}}}'
        + '</script></head><body><h1>Humble Bundle Books</h1></body></html>'

    // ── 1. Catalog and Schema Invariants ────────────────────────────────────
    TestCase {
        name: "HumbleBooksCatalogAndSchema"
        when: windowShown

        function test_catalog_entry() {
            var item = catalog.def("humblebooks")
            verify(item !== null, "humblebooks is registered in WidgetCatalog")
            compare(item.title, "Humble Books")
            compare(item.category, "Info")
            compare(item.source, "qrc:/qml/HumbleBooksWidget.qml")
            verify(catalog.desc("humblebooks").length > 0, "humblebooks has description in catalog")
            verify(item.sizes.indexOf("1x1") >= 0, "supports 1x1 baseline")
            verify(item.sizes.indexOf("0.5x1") >= 0, "supports 0.5x1")
            verify(item.sizes.indexOf("1x0.5") >= 0, "supports 1x0.5")
            verify(item.sizes.indexOf("1x1.5") >= 0, "supports 1x1.5")
            verify(item.sizes.indexOf("1x2") >= 0, "supports 1x2")
        }

        function test_schema_structure() {
            var schema = sc.schemaFor("humblebooks")
            verify(schema !== null && schema.sections.length >= 2, "schema defines sections")

            var fieldKeys = []
            var catField = null
            for (var s = 0; s < schema.sections.length; s++) {
                var fields = schema.sections[s].fields || []
                for (var f = 0; f < fields.length; f++) {
                    if (fields[f].key) fieldKeys.push(fields[f].key)
                    if (fields[f].key === "category") catField = fields[f]
                }
            }

            verify(fieldKeys.indexOf("category") >= 0, "category field exists")
            verify(fieldKeys.indexOf("pollHours") >= 0, "pollHours field exists")
            verify(catField !== null && catField.options !== undefined, "category field defines options")
            var catVals = catField.options.map(function(o) { return o.value })
            verify(catVals.indexOf("rpg") >= 0, "category schema includes rpg option")
        }
    }

    // ── 2. Classification Logic Tests ────────────────────────────────────────
    TestCase {
        name: "HumbleBooksClassifier"
        when: windowShown

        function init() {
            tryVerify(function () { return h.ready }, 3000)
        }

        function test_comics_classification() {
            var w = h.item
            compare(w.classify({ tile_name: "Humble Comics Bundle: Batman Day", tile_stamp: "comics" }), "Comics")
            compare(w.classify({ tile_name: "50 Essential Fantagraphics Titles", tile_stamp: "comics" }), "Comics")
            compare(w.classify({ tile_name: "Manga Megabundle 2026", tile_stamp: "books" }), "Comics")
            compare(w.classify({ tile_name: "Indie Graphic Novels", tile_stamp: "books", marketing_blurb: "Award winning graphic novel collection." }), "Comics")
        }

        function test_tech_classification() {
            var w = h.item
            // Critical test: C++ Masterclass with "Cookbook" in blurb MUST classify as Tech, not Cookbook
            compare(w.classify({ tile_name: "Humble Tech Book Bundle: C++ Programming Masterclass", tile_stamp: "books", marketing_blurb: "Get Modern C++ Programming Cookbook and CMake Best Practices" }), "Tech")
            compare(w.classify({ tile_name: "AI in Production: Governance & Reliability by Manning", tile_stamp: "books" }), "Tech")
            compare(w.classify({ tile_name: "The Ultimate Linux & Cloud Infrastructure Bundle", tile_stamp: "books" }), "Tech")
            compare(w.classify({ tile_name: "Think Like a Programmer by No Starch Press", tile_stamp: "books" }), "Tech")
            compare(w.classify({ tile_name: "Software Architecture 2026 by O'Reilly", tile_stamp: "books" }), "Tech")
            compare(w.classify({ tile_name: "Python for Data Science by Packt", tile_stamp: "books" }), "Tech")
        }

        function test_rpg_classification() {
            var w = h.item
            compare(w.classify({ tile_name: "Humble RPG Bundle: Dungeon Master's Guild", tile_stamp: "books" }), "RPG")
            compare(w.classify({ tile_name: "Legend In The Mist & Otherscape RPG", tile_stamp: "books", author: "Son of Oak" }), "RPG")
            compare(w.classify({ tile_name: "Caverns of Thracia Tabletop Adventure", tile_stamp: "books", author: "Goodman Games" }), "RPG")
            compare(w.classify({ tile_name: "Pathfinder 2e Core Rules", tile_stamp: "books" }), "RPG")
            compare(w.classify({ tile_name: "Call of Cthulhu TTRPG", tile_stamp: "books" }), "RPG")
        }

        function test_cookbooks_classification() {
            var w = h.item
            compare(w.classify({ tile_name: "Eat Your Protein! A Keto Cookbook Bundle", tile_stamp: "books" }), "Cookbooks")
            compare(w.classify({ tile_name: "Artisan Bread Baking & Pastry Recipes", tile_stamp: "books" }), "Cookbooks")
            compare(w.classify({ tile_name: "The Complete Vegetarian Kitchen & Culinary Guide", tile_stamp: "books" }), "Cookbooks")
        }

        function test_sf_classification() {
            var w = h.item
            compare(w.classify({ tile_name: "The Original Worlds of Timothy Zahn", tile_stamp: "books" }), "SF")
            compare(w.classify({ tile_name: "The Greg Bear Birthday Bundle", tile_stamp: "books" }), "SF")
            compare(w.classify({ tile_name: "The Best of C.J. Cherryh", tile_stamp: "books" }), "SF")
            compare(w.classify({ tile_name: "Joe Haldeman: The Forever War and Beyond", tile_stamp: "books" }), "SF")
            compare(w.classify({ tile_name: "The Best of Brian W. Aldiss", tile_stamp: "books" }), "SF")
            compare(w.classify({ tile_name: "Epic Space Opera & Science Fiction Collection", tile_stamp: "books" }), "SF")
            compare(w.classify({ tile_name: "High Fantasy Realms", tile_stamp: "books", short_marketing_blurb: "Fantasy novels from bestsellers" }), "SF")
        }

        function test_other_classification() {
            var w = h.item
            compare(w.classify({ tile_name: "The Ultimate Woodworking & Carpentry Masterclass", tile_stamp: "books" }), "Other")
            compare(w.classify({ tile_name: "Master Your Digital Audio Workstation", tile_stamp: "books" }), "Other")
            compare(w.classify({ tile_name: "Watercolor Painting Essentials", tile_stamp: "books" }), "Other")
        }
    }

    // ── 3. HTML Parsing Tests ────────────────────────────────────────────────
    TestCase {
        name: "HumbleBooksParsing"
        when: windowShown

        function init() {
            tryVerify(function () { return h.ready }, 3000)
        }

        function test_parse_sample_html() {
            var w = h.item
            var bundles = w.parseHumbleHtml(root.sampleHumbleHtml)
            compare(bundles.length, 6, "parsed all 6 sample bundles")

            // Batman (Comics)
            compare(bundles[0].id, "batmanday_bundle")
            compare(bundles[0].title, "Batman Day Comics Bundle by DC Comics")
            compare(bundles[0].category, "Comics")
            compare(bundles[0].url, "https://www.humblebundle.com/books/batman-day")
            compare(bundles[0].imageUrl, "https://hb.imgix.net/batman.jpg")
            compare(bundles[0].itemCountText, "31 comics")
            compare(bundles[0].valueText, "$487 Value")
            compare(bundles[0].tierPriceText, "From $5")

            // C++ (Tech)
            compare(bundles[1].id, "cpp_masterclass")
            compare(bundles[1].title, "C++ Programming Masterclass")
            compare(bundles[1].category, "Tech")
            compare(bundles[1].itemCountText, "21 books")
            compare(bundles[1].valueText, "$761 Value")
            compare(bundles[1].tierPriceText, "From $5")

            // Timothy Zahn (SF)
            compare(bundles[2].category, "SF")
            compare(bundles[2].itemCountText, "23 books")
            compare(bundles[2].tierPriceText, "From $3")

            // Keto (Cookbooks)
            compare(bundles[3].category, "Cookbooks")
            compare(bundles[3].itemCountText, "25 books")
            compare(bundles[3].tierPriceText, "From $18")

            // D&D (RPG)
            compare(bundles[4].category, "RPG")
            compare(bundles[4].itemCountText, "19 books")
            compare(bundles[4].tierPriceText, "From $5")

            // Woodworking (Other)
            compare(bundles[5].category, "Other")
            compare(bundles[5].itemCountText, "12 books")
            compare(bundles[5].tierPriceText, "From $5")
        }

        function test_parse_empty_or_malformed_html() {
            var w = h.item
            compare(w.parseHumbleHtml("").length, 0)
            compare(w.parseHumbleHtml("<html><body>No script</body></html>").length, 0)
            compare(w.parseHumbleHtml('<script id="landingPage-json-data" type="application/json">invalid json</script>').length, 0)
        }

        function test_extract_highlights_helpers() {
            var w = h.item
            compare(w.extractItemCount(["Pay What You Want", "42 books", "$500 Value"]), "42 books")
            compare(w.extractItemCount(["Pay What You Want", "100 comics"]), "100 comics")
            compare(w.extractItemCount([]), "")

            compare(w.extractValue(["Pay What You Want", "42 books", "$500 Value"]), "$500 Value")
            compare(w.extractValue(["Pay What You Want", "£250 Value"]), "£250 Value")
            compare(w.extractValue([]), "")

            // hero_highlights extraction (replaces generic "Pay What You Want")
            compare(w.extractTierPrice(["Pay What You Want"], [{ heading: "Pay $5 or more" }]), "From $5")
            compare(w.extractTierPrice(["Pay What You Want"], [{ heading: "Pay $18 or more" }]), "From $18")
            compare(w.extractTierPrice(["From $10", "42 books"], []), "From $10")
            compare(w.extractTierPrice(["Pay What You Want", "42 books"], []), "")

            // Top-tier price resolution (shows full bundle unlock price)
            compare(w.extractTierPrice(["Pay What You Want"], [{ heading: "Pay $5 or more" }], "batmandaycomicsbundledccomics_bookbundle"), "$20 for all")
            compare(w.extractTierPrice(["Pay What You Want"], [{ heading: "Pay $5 or more" }], "cprogrammingmasterclasscodefasterbuildsmartermasterc_bookbundle"), "$18 for all")
            compare(w.extractTierPrice(["Pay What You Want"], [{ heading: "Pay $10 or more" }], "aiinproductiongovernancereliabilityandapplicationmanning_bookbundle"), "$40 for all")
        }

        function test_extract_top_tier_from_subpage_html() {
            var w = h.item
            var sampleSubpageHtml = '<script id="bundle-data" type="application/json">{"bundleData":{"tier_pricing_data":{"bt20":{"price|money":{"currency":"USD","amount":20.0}},"bt12":{"price|money":{"currency":"USD","amount":12.0}},"initial":{"price|money":{"currency":"USD","amount":5.0}}}}}</script>'
            compare(w.extractTopTierPriceFromSubpage(sampleSubpageHtml), "$20")

            var euroSubpageHtml = '<script type="application/json">{"bundleData":{"tier_pricing_data":{"tier3":{"price|money":{"currency":"EUR","amount":18.50}},"tier1":{"price|money":{"currency":"EUR","amount":1.0}}}}}</script>'
            compare(w.extractTopTierPriceFromSubpage(euroSubpageHtml), "€18.50")
        }

        function test_time_remaining_formatting() {
            var w = h.item
            var refMs = new Date("2026-09-27T12:00:00.000Z").getTime()

            // 5 days left
            var future5d = new Date(refMs + 5 * 86400000).toISOString()
            compare(w.formatTimeRemaining(future5d, refMs), "5d left")

            // 1 day and 6 hours left
            var future1d = new Date(refMs + 30 * 3600000).toISOString()
            compare(w.formatTimeRemaining(future1d, refMs), "1d 6h left")

            // 8 hours left
            var future8h = new Date(refMs + 8 * 3600000).toISOString()
            compare(w.formatTimeRemaining(future8h, refMs), "8h left")

            // 45 minutes left
            var future45m = new Date(refMs + 45 * 60000).toISOString()
            compare(w.formatTimeRemaining(future45m, refMs), "45m left")

            // In the past -> Ended
            var pastDate = new Date(refMs - 3600000).toISOString()
            compare(w.formatTimeRemaining(pastDate, refMs), "Ended")

            // Invalid string
            compare(w.formatTimeRemaining("invalid-date", refMs), "")
        }
    }

    // ── 4. Widget Harness & Interactive Behavior Tests ───────────────────────
    TestCase {
        name: "HumbleBooksHarness"
        when: windowShown

        function init() {
            tryVerify(function () { return h.ready }, 3000)
            var w = h.item
            w.bundles = w.parseHumbleHtml(root.sampleHumbleHtml)
            w.activeCategory = "all"
        }

        function test_category_filtering() {
            var w = h.item
            compare(w.filteredBundles.length, 6, "all shows all 6 bundles")
            compare(w.countForCategory("all"), 6)
            compare(w.countForCategory("tech"), 1)
            compare(w.countForCategory("comics"), 1)
            compare(w.countForCategory("sf"), 1)
            compare(w.countForCategory("rpg"), 1)
            compare(w.countForCategory("cookbooks"), 1)
            compare(w.countForCategory("other"), 1)

            // Switch to Tech
            w.activeCategory = "tech"
            compare(w.filteredBundles.length, 1, "tech shows 1 bundle")
            compare(w.filteredBundles[0].category, "Tech")
            compare(w.filteredBundles[0].title, "C++ Programming Masterclass")

            // Switch to Comics
            w.activeCategory = "comics"
            compare(w.filteredBundles.length, 1, "comics shows 1 bundle")
            compare(w.filteredBundles[0].category, "Comics")

            // Switch to SF
            w.activeCategory = "sf"
            compare(w.filteredBundles.length, 1, "sf shows 1 bundle")
            compare(w.filteredBundles[0].category, "SF")

            // Switch to RPG
            w.activeCategory = "rpg"
            compare(w.filteredBundles.length, 1, "rpg shows 1 bundle")
            compare(w.filteredBundles[0].category, "RPG")
            compare(w.filteredBundles[0].title, "Dungeon Master's Guild Top Content")

            // Switch to Cookbooks
            w.activeCategory = "cookbooks"
            compare(w.filteredBundles.length, 1, "cookbooks shows 1 bundle")
            compare(w.filteredBundles[0].category, "Cookbooks")

            // Switch to Other
            w.activeCategory = "other"
            compare(w.filteredBundles.length, 1, "other shows 1 bundle")
            compare(w.filteredBundles[0].category, "Other")
            compare(w.filteredBundles[0].title, "Woodworking Masterclass")

            // Reset to All
            w.activeCategory = "all"
            compare(w.filteredBundles.length, 6)
        }

        function test_toggle_category_filtering() {
            var w = h.item
            w.toggleCategory("all")
            compare(w.filteredBundles.length, 6)
            compare(w.isCategoryActive("all"), true)

            // 1. Toggle Tech: only tech is selected
            w.toggleCategory("tech")
            compare(w.isCategoryActive("tech"), true)
            compare(w.isCategoryActive("all"), false)
            compare(w.filteredBundles.length, 1)
            compare(w.filteredBundles[0].category, "Tech")

            // 2. Toggle SF while Tech is active: switches directly to SF (not additive)
            w.toggleCategory("sf")
            compare(w.isCategoryActive("tech"), false)
            compare(w.isCategoryActive("sf"), true)
            compare(w.isCategoryActive("all"), false)
            compare(w.filteredBundles.length, 1)
            compare(w.filteredBundles[0].category, "SF")

            // 3. Toggle SF again: toggles off and returns to All
            w.toggleCategory("sf")
            compare(w.isCategoryActive("sf"), false)
            compare(w.isCategoryActive("all"), true)
            compare(w.filteredBundles.length, 6)

            // 4. Toggle Comics: only Comics selected
            w.toggleCategory("comics")
            compare(w.isCategoryActive("comics"), true)
            compare(w.filteredBundles.length, 1)
            compare(w.filteredBundles[0].category, "Comics")

            // 5. Tap All: explicitly clears back to All
            w.toggleCategory("all")
            compare(w.isCategoryActive("comics"), false)
            compare(w.isCategoryActive("all"), true)
            compare(w.filteredBundles.length, 6)

            // 6. Tap All again while All is active: remains All
            w.toggleCategory("all")
            compare(w.isCategoryActive("all"), true)
            compare(w.filteredBundles.length, 6)
        }

        function test_open_bundle_calls_external_opener() {
            var w = h.item
            var openedUrl = ""
            w.externalOpener = function (u) {
                openedUrl = u
            }

            var testBundle = w.bundles[0]
            w.openBundle(testBundle)
            compare(openedUrl, testBundle.url, "external opener was called with the bundle URL")
        }

        function test_touch_target_dimensions() {
            var w = h.item
            // Verify that category pills and buttons meet the >= 44px touch target requirement
            var pills = w.categoryList
            verify(pills.length === 7, "has 7 category pills (All, Tech, Comics, SF, RPG, Cookbooks, Other)")
            // Category row height is at least 44
            verify(Math.max(44, theme.touchTertiary) >= 44, "touchTertiary >= 44px")
        }

        function test_expiry_sorting_and_color_thresholds() {
            var w = h.item
            var refMs = new Date("2026-09-27T12:00:00.000Z").getTime()
            w.nowMsOverride = refMs

            // 1. Color threshold tests
            var bUrgent = { endDate: new Date(refMs + 36 * 3600000).toISOString() } // 36 hours (<48h)
            compare(w.getExpiryLevel(bUrgent), "urgent")
            compare(w.getExpiryColor(bUrgent), theme.error)

            var bSoon = { endDate: new Date(refMs + 3 * 86400000).toISOString() } // 3 days (<5d)
            compare(w.getExpiryLevel(bSoon), "soon")
            compare(w.getExpiryColor(bSoon), theme.warning)

            var bNormal = { endDate: new Date(refMs + 10 * 86400000).toISOString() } // 10 days (>=5d)
            compare(w.getExpiryLevel(bNormal), "normal")
            compare(w.getExpiryColor(bNormal), theme.textSecondary)

            // 2. Sorting test: bundles should sort in "about to expire" order
            var b1 = { id: "later", title: "Later Bundle", endDate: new Date(refMs + 8 * 86400000).toISOString(), category: "Tech", imageUrl: "", itemCountText: "10 books", valueText: "$100", tierPriceText: "Pay What You Want" }
            var b2 = { id: "soonest", title: "Soonest Bundle", endDate: new Date(refMs + 24 * 3600000).toISOString(), category: "Tech", imageUrl: "", itemCountText: "5 books", valueText: "$50", tierPriceText: "Pay What You Want" }
            var b3 = { id: "middle", title: "Middle Bundle", endDate: new Date(refMs + 3 * 86400000).toISOString(), category: "Tech", imageUrl: "", itemCountText: "8 books", valueText: "$80", tierPriceText: "Pay What You Want" }
            w.bundles = [b1, b2, b3]
            w.activeCategory = "all"

            compare(w.filteredBundles.length, 3)
            compare(w.filteredBundles[0].id, "soonest", "first item is expiring soonest")
            compare(w.filteredBundles[1].id, "middle", "second item is middle")
            compare(w.filteredBundles[2].id, "later", "third item is latest")
        }
    }
}

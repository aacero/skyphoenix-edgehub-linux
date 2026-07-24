import QtQuick
import QtTest
import "../../ui/qml" as App

// DashboardStore persistence I/O (ui/qml/DashboardStore.qml). The store resolves
// the C++ `configBridge` by UNQUALIFIED name via the scope chain, so we expose it
// as a root property and toggle it null / fake to drive both the bridge-present
// and bridge-absent paths. Focus: ephemeral-key stripping in _persistableData,
// the _isEphemeralKey table, _hasBridge, and safe flush without a bridge.
Item {
    id: root
    width: 100; height: 100

    // Fake persistence bridge with a saveUiState spy. `configBridge` (null when we
    // want the no-bridge path) is what the store sees.
    QtObject {
        id: fakeBridge
        property int saveCount: 0
        property string lastJson: ""
        property bool saveSucceeds: true
        function saveUiState(json) { saveCount++; lastJson = json; return saveSucceeds }
        function uiState() { return "" }
        function reset() { saveCount = 0; lastJson = ""; saveSucceeds = true }
    }
    property var configBridge: null

    App.DashboardStore { id: store }

    function seedBuckets() {
        // Two settings buckets, each mixing ephemeral runtime keys with real keys.
        store.setSetting("cpu-1", "hist", [0.1, 0.2, 0.3])
        store.setSetting("cpu-1", "peakRx", 999)
        store.setSetting("cpu-1", "peakTx", 888)
        store.setSetting("cpu-1", "warnTemp", 70)        // real
        store.setSetting("cpu-1", "title", "Processor")  // real
        store.setSetting("net-1", "hist", [1, 2, 3])
        store.setSetting("net-1", "peakRx", 5)
        store.setSetting("net-1", "iface", "eth0")       // real
    }

    TestCase {
        name: "StoreIO"
        when: windowShown

        function init() {
            root.configBridge = null           // no-bridge seed path (no persistence)
            store.load("blank")                 // fresh, plain-JS document with settings:{}
            root.configBridge = null
            fakeBridge.reset()
        }

        // ── _isEphemeralKey table ────────────────────────────────────────────
        function test_isEphemeralKey_table() {
            verify(store._isEphemeralKey("hist"), "hist is ephemeral")
            verify(store._isEphemeralKey("histRaw"), "raw KPI history is ephemeral")
            verify(store._isEphemeralKey("histDevice"), "GPU history identity is ephemeral")
            verify(store._isEphemeralKey("quoteManualIdx"), "quote shuffle index is ephemeral")
            verify(store._isEphemeralKey("quotePinnedText"), "quote identity is ephemeral")
            verify(store._isEphemeralKey("quoteManualDay"), "quote shuffle day is ephemeral")
            verify(store._isEphemeralKey("peakRx"), "peakRx is ephemeral")
            verify(store._isEphemeralKey("peakTx"), "peakTx is ephemeral")
            verify(!store._isEphemeralKey("title"), "title is persisted")
            verify(!store._isEphemeralKey("warnTemp"), "warnTemp is persisted")
            verify(!store._isEphemeralKey("accent"), "accent is persisted")
            verify(!store._isEphemeralKey(""), "empty key is not ephemeral")
        }

        // ── _hasBridge ───────────────────────────────────────────────────────
        function test_hasBridge_false_without_bridge() {
            root.configBridge = null
            verify(!store._hasBridge(), "_hasBridge is false when no bridge is present")
        }

        function test_hasBridge_true_with_bridge() {
            root.configBridge = fakeBridge
            verify(store._hasBridge(), "_hasBridge is true when the bridge is present")
        }

        // ── flush is safe with no bridge ─────────────────────────────────────
        function test_flush_safe_without_bridge() {
            root.configBridge = null
            var threw = false
            try { store._flush(); store.flushNow() } catch (e) { threw = true }
            verify(!threw, "_flush / flushNow must be no-ops (not throw) without a bridge")
        }

        // ensureSettings must NOT schedule a save when every default is already
        // present - otherwise each tile-Loader rebuild (e.g. after applyExternal)
        // re-runs it and triggers a redundant flash write echoing the pushed doc.
        function test_ensureSettings_no_save_when_nothing_added() {
            store.load("blank")
            store.setSetting("w1", "a", 1)      // real key → schedules a save
            store.flushNow()                    // clear the pending save
            verify(!store._savePending, "no save pending after flushNow")
            store.ensureSettings("w1", { a: 999 })   // 'a' already present → nothing seeded
            verify(!store._savePending, "ensureSettings scheduled NO save when all defaults present")
            compare(store.settingsFor("w1").a, 1, "existing value not overwritten by the default")
            store.ensureSettings("w1", { b: 2 })     // 'b' is new → seeded
            verify(store._savePending, "ensureSettings DID schedule a save when a default was seeded")
            compare(store.settingsFor("w1").b, 2, "new default was seeded")
            store.flushNow()   // don't leak a pending save into the next (alphabetical) test
        }

        // ── _persistableData strips ephemeral keys from EVERY bucket ─────────
        function test_persistableData_strips_ephemeral_from_every_bucket() {
            seedBuckets()
            var pd = store._persistableData()
            verify(pd !== store.document, "persistable data is a separate clone")
            // Ephemeral keys gone from both buckets.
            compare(pd.settings["cpu-1"].hist, undefined, "cpu-1 hist stripped")
            compare(pd.settings["cpu-1"].peakRx, undefined, "cpu-1 peakRx stripped")
            compare(pd.settings["cpu-1"].peakTx, undefined, "cpu-1 peakTx stripped")
            compare(pd.settings["net-1"].hist, undefined, "net-1 hist stripped")
            compare(pd.settings["net-1"].peakRx, undefined, "net-1 peakRx stripped")
            // Real keys preserved.
            compare(pd.settings["cpu-1"].warnTemp, 70, "cpu-1 warnTemp kept")
            compare(pd.settings["cpu-1"].title, "Processor", "cpu-1 title kept")
            compare(pd.settings["net-1"].iface, "eth0", "net-1 iface kept")
        }

        function test_persistableData_is_non_destructive() {
            seedBuckets()
            store._persistableData()
            verify(store.document.settings["cpu-1"].hist !== undefined,
                   "the live document keeps its runtime hist (only the on-disk copy is stripped)")
            verify(store.document.settings["cpu-1"].peakRx !== undefined, "live peakRx retained")
        }

        // ── flush writes the exact persistable JSON (no ephemeral keys) ──────
        function test_flush_writes_persistable_json_without_ephemeral() {
            root.configBridge = fakeBridge
            fakeBridge.reset()
            seedBuckets()
            store.flushNow()
            compare(fakeBridge.saveCount, 1, "flushNow saves exactly once through the bridge")
            var doc = JSON.parse(fakeBridge.lastJson)
            for (var id in doc.settings) {
                compare(doc.settings[id].hist, undefined, id + " hist absent from saved JSON")
                compare(doc.settings[id].peakRx, undefined, id + " peakRx absent from saved JSON")
                compare(doc.settings[id].peakTx, undefined, id + " peakTx absent from saved JSON")
            }
            compare(doc.settings["cpu-1"].warnTemp, 70, "real key present in saved JSON")
            compare(doc.settings["net-1"].iface, "eth0", "real key present in saved JSON")
        }

        function test_flushNow_reports_bridge_failure_and_clears_the_timer() {
            root.configBridge = fakeBridge
            store.setSetting("cpu-1", "warnTemp", 91)
            verify(store._savePending, "real edit armed the debounce")
            fakeBridge.saveSucceeds = false
            verify(!store.flushNow(), "the synchronous flush reports a persistence rejection")
            verify(!store._savePending, "the debounce is stopped even when persistence rejects")
            compare(fakeBridge.saveCount, 1, "one immediate persistence attempt was made")
        }

        // ── Ephemeral writes never schedule a disk save ──────────────────────
        function test_ephemeral_setSetting_does_not_persist() {
            root.configBridge = fakeBridge
            fakeBridge.reset()
            store.setSetting("cpu-1", "hist", [0.5])       // volatile → no save
            wait(600)                                       // let any debounce fire
            compare(fakeBridge.saveCount, 0, "a volatile hist write never schedules a disk save")
        }

        function test_real_setSetting_persists() {
            root.configBridge = fakeBridge
            fakeBridge.reset()
            store.setSetting("cpu-1", "warnTemp", 80)      // real → debounced save
            wait(600)
            verify(fakeBridge.saveCount > 0, "a real setSetting schedules a disk save")
        }

        function test_patch_only_ephemeral_does_not_persist() {
            root.configBridge = fakeBridge
            fakeBridge.reset()
            store.patchSettings("cpu-1", { hist: [1], peakRx: 2, peakTx: 3 })
            wait(600)
            compare(fakeBridge.saveCount, 0, "a patch of only volatile keys never saves")
        }

        function test_patch_with_real_key_persists() {
            root.configBridge = fakeBridge
            fakeBridge.reset()
            store.patchSettings("cpu-1", { hist: [1], warnTemp: 65 })   // mixed → persists
            wait(600)
            verify(fakeBridge.saveCount > 0, "a patch that carries a real key schedules a save")
        }
    }
}

import Testing

@testable import PathemEngine

@Suite struct KeymapOverlayTests {
    @Test func overlayRoundTripsThroughMerging() {
        // Start from defaults, then: rebind one chord, add a new one, drop a default.
        var effective = Keymap.defaultBindings
        effective["f5"] = "files.moveToOtherPane"  // changed from copyToOtherPane
        effective["cmd+e"] = "files.extract"  // brand-new binding
        effective["space"] = nil  // user removed a default (quickLook)

        let overlay = Keymap.overlay(forEffective: effective)
        // Minimal: only the three deltas, nothing else.
        #expect(overlay["f5"] == "files.moveToOtherPane")
        #expect(overlay["cmd+e"] == "files.extract")
        #expect(overlay["space"] == "")  // unbound marker
        #expect(overlay["return"] == nil)  // unchanged default not in the overlay

        // Applying the overlay to the defaults reproduces the edited map exactly.
        let merged = Keymap.standard.merging(userBindings: overlay).bindings
        #expect(merged == effective)
    }

    @Test func noChangesYieldEmptyOverlay() {
        #expect(Keymap.overlay(forEffective: Keymap.defaultBindings).isEmpty)
    }
}

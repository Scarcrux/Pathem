#if DEBUG
import AppKit

extension TransientSurfaceSample {
    func fullText(_ token: Any) -> String {
        if let value = token as? String { return value }
        guard let object = token as? [String: Any] else { return "INVALID-TOKEN" }
        if let value = object["literal"] as? String { return value }
        if object["error"] as? Bool == true {
            return NSError(
                domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                userInfo: [
                    NSFilePathErrorKey: "/fixture/" + String(repeating: "n", count: 251) + ".txt"
                ]
            )
            .localizedDescription
        }
        if let parts = object["parts"] as? [Any] { return parts.map(fullText).joined() }
        guard let key = object["key"] as? String else { return "INVALID-TOKEN" }
        let arguments: [CVarArg] = (object["args"] as? [Any] ?? []).map {
            if let number = $0 as? NSNumber { return number.intValue }
            return fullText($0)
        }
        return String(format: L(key, "MISSING:" + key), arguments: arguments)
    }

    func fullAlert(_ recipe: [String: Any]) -> NSAlert {
        if let sample = recipe["unit1_sample"] as? [String: Any] { return plainAlert(sample) }
        let alert = NSAlert()
        alert.messageText = fullText(recipe["message"]!)
        alert.informativeText = fullText(recipe["body"]!)
        for key in recipe["buttons"] as? [String] ?? [] {
            alert.addButton(withTitle: L(key, "MISSING:" + key))
        }
        // NSAlert supplies the default OK button when the production builder adds none.
        alert.layout()
        return alert
    }

    func classBFull() {
        requestedAppearance = nil
        let file = environment["PATHEM_TRANSIENT_FULL_ALERTS"] ?? ""
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let recipes = object["alerts"] as? [[String: Any]]
        else {
            emit("full-B-contract", 0, false, "missing audited recipes")
            return
        }
        let expected = Set(policy.filter { $0.value["class"] as? String == "B" }.keys)
        emit(
            "full-B-contract", 0,
            Set(recipes.compactMap { $0["site"] as? String }) == expected
                && recipes.count == expected.count, "all \(expected.count) classified B sites")
        if let only = environment["PATHEM_TRANSIENT_SURFACES_ONLY"] {
            trace("TSAMPLE: B-SUBSET requested=\(only)")
        }
        for size in [NSSize(width: 720, height: 420), NSSize(width: 1100, height: 700)] {
            requestedSize = size
            host.setContentSize(size)
            for recipe in recipes
            where environment["PATHEM_TRANSIENT_SURFACES_ONLY"].map({
                $0 == recipe["id"] as? String
            }) ?? true {
                let id = recipe["id"] as! String
                let cell = "B-\(id)-\(language)-\(Int(size.width))"
                let alert = fullAlert(recipe)
                alert.layout()
                guard let content = alert.window.contentView else {
                    emit(cell, 0, false, "missing content")
                    continue
                }
                trace(
                    "TSAMPLE: SITE cell=\(cell) site=\(recipe["site"]!) builder=\(recipe["builder"]!)"
                )
                emit(
                    cell, 0,
                    !alert.messageText.contains("MISSING:")
                        && !alert.informativeText.contains("MISSING:")
                        && !alert.messageText.contains("INVALID-TOKEN")
                        && !alert.informativeText.contains("INVALID-TOKEN"),
                    "real catalog/fixture delivered")
                inspect(
                    content, alert: alert, cell: cell, phase: "full-structural",
                    sheet: recipe["sheet"] as? Bool == true, presented: false)
                if language == "de", recipe["sheet"] as? Bool == true {
                    let sample = recipe["unit1_sample"] as? [String: Any]
                    let cancelAt =
                        sample?["id"] as? String == "extension-confirm"
                        ? 0 : alert.buttons.count - 1
                    runSurface(
                        "plain", cell: cell + "-lifecycle", name: "fixture.txt",
                        plain: { self.fullAlert(recipe) }, cancelAt: cancelAt,
                        responseBase: ((sample?["button_keys"] as? [String] ?? recipe["buttons"]
                            as? [String] ?? []).isEmpty ? 0 : 1000))
                }
                trace(
                    "TSAMPLE: COVERED class=B site=\(recipe["site"]!) mode=\(recipe["sheet"] as? Bool == true ? "structural+sheet" : "structural-only-runModal")"
                )
            }
        }
    }
}
#endif

#if canImport(AppIntents)
    import AppIntents
    import Foundation
    import PathomEngine

    // App Intents / Shortcuts integration (DESIGN.md section 10, Phase 4).
    //
    // IMPORTANT: App Intents are only discovered by the Shortcuts app and Spotlight
    // once Pathom is built and installed as a registered .app bundle (the notarized
    // direct-download model in DESIGN). They do not register when launched via
    // `swift run`. This code is the real integration, ready to activate at the
    // packaging step; it is not exercisable from the CLI build.
    //
    // The flagship action is on-device semantic search: it is genuinely
    // differentiated (free, local, no Apple Intelligence) and self-contained, so it
    // runs entirely off the engine without needing the running app's UI state.

    @available(macOS 15.0, *)
    struct SemanticSearchIntent: AppIntent {
        static let title: LocalizedStringResource = "Search a Folder by Meaning"
        static let description = IntentDescription(
            "On-device semantic search over a folder's files, ranked by similarity to your query. Runs locally and free, with no Apple Intelligence required."
        )

        @Parameter(title: "Folder Path")
        var folderPath: String

        @Parameter(title: "Query")
        var query: String

        @Parameter(title: "Maximum Results", default: 20)
        var maxResults: Int

        static var parameterSummary: some ParameterSummary {
            Summary("Search \(\.$folderPath) for \(\.$query)")
        }

        func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
            let folder = URL(fileURLWithPath: folderPath)
            let entries = (try? BulkEnumerator().entries(of: folder, includingHidden: false)) ?? []
            let index = SemanticSearcher.index(entries, in: folder)
            let ranked = SemanticSearcher.rank(query: query, in: index)
            let paths = ranked.prefix(max(0, maxResults)).compactMap { i -> String? in
                i < entries.count ? folder.appendingPathComponent(entries[i].name).path : nil
            }
            return .result(value: Array(paths))
        }
    }

    @available(macOS 15.0, *)
    struct PathomShortcuts: AppShortcutsProvider {
        static var appShortcuts: [AppShortcut] {
            AppShortcut(
                intent: SemanticSearchIntent(),
                phrases: [
                    "Search a folder with \(.applicationName)",
                    "Semantic search in \(.applicationName)",
                ],
                shortTitle: "Semantic Search",
                systemImageName: "magnifyingglass")
        }
    }
#endif

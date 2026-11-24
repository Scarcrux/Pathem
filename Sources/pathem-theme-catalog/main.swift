import Foundation
import PathemEngine

enum CatalogCommandError: LocalizedError {
    case usage
    var errorDescription: String? {
        """
        Usage: pathem-theme-catalog <store> submit <submission.json>
               pathem-theme-catalog <store> review <id> <version> <approved|rejected> <reviewer> <note>
               pathem-theme-catalog <store> withdraw <id>
               pathem-theme-catalog <store> snapshot <catalog.json>
               pathem-theme-catalog <client-store> sync <catalog-url>
               pathem-theme-catalog <client-store> install <id>
        """
    }
}

func perform(_ arguments: [String]) async throws {
    guard arguments.count >= 3 else { throw CatalogCommandError.usage }
    let store = URL(fileURLWithPath: arguments[0])
    let command = arguments[1]
    let values = Array(arguments.dropFirst(2))
    switch command {
    case "submit" where values.count == 1:
        let input = try CommunityThemeGallery.submission(at: URL(fileURLWithPath: values[0]))
        _ = try CommunityThemeGallery.update(at: store) { try $0.submit(input) }
    case "review" where values.count == 5:
        guard let version = Int(values[1]),
            let decision = CommunityThemeGallery.Review.Outcome(rawValue: values[2])
        else { throw CatalogCommandError.usage }
        _ = try CommunityThemeGallery.update(at: store) { gallery in
            guard
                let reference = gallery.entries.first(where: {
                    $0.revision.id == values[0] && $0.revision.version == version
                })?.revision.reference
            else { throw CommunityThemeError.invalidTransition }
            try gallery.review(reference, outcome: decision, reviewer: values[3], note: values[4])
        }
    case "withdraw" where values.count == 1:
        _ = try CommunityThemeGallery.update(at: store) { try $0.withdraw(values[0]) }
    case "sync" where values.count == 1:
        let catalog = try await SharedThemeCatalog.fetch(values[0])
        _ = try CommunityThemeGallery.update(at: store) { $0.synchronize(catalog) }
    case "install" where values.count == 1:
        _ = try CommunityThemeGallery.update(at: store) { gallery in
            guard let reference = gallery.discover().first(where: { $0.id == values[0] })?.reference
            else { throw CommunityThemeError.invalidTransition }
            try gallery.install(reference)
        }
    case "snapshot" where values.count == 1:
        let gallery = try CommunityThemeGallery.load(from: store)
        let catalog = SharedThemeCatalog(reviewed: gallery)
        try catalog.encoded().write(to: URL(fileURLWithPath: values[0]), options: .atomic)
    default:
        throw CatalogCommandError.usage
    }
}

do {
    try await perform(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}

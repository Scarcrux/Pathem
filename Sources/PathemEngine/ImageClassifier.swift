import Foundation
import Vision

/// Classifies the content of an image with the on-device Vision taxonomy (`VNClassifyImageRequest`),
/// returning a few high-precision, tag-friendly labels ("Beach", "Dog", "Food"). Used to auto-tag
/// photos so they become findable by what's in them. Pure (Vision only, no AppKit), runs off-main.
public enum ImageClassifier {
    /// The top content labels for the image at `url`: high-precision classifications only (so the
    /// tags are trustworthy, not a wall of maybes), most confident first, capped at `maxLabels`.
    /// Empty if nothing is confident or the image can't be read.
    public static func classify(url: URL, maxLabels: Int = 3) -> [String] {
        let handler = VNImageRequestHandler(url: url, options: [:])
        let request = VNClassifyImageRequest()
        guard (try? handler.perform([request])) != nil, let observations = request.results else { return [] }
        return
            observations
            // Vision recommends filtering by precision/recall rather than a raw confidence cutoff;
            // precision 0.7 keeps only labels the model is fairly sure about.
            .filter { $0.hasMinimumRecall(0.01, forPrecision: 0.7) }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxLabels)
            .map { tagName(from: $0.identifier) }
    }

    /// Turn a taxonomy identifier ("hot_dog", "beach") into a tag label ("Hot Dog", "Beach").
    static func tagName(from identifier: String) -> String {
        identifier
            .split(whereSeparator: { $0 == "_" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

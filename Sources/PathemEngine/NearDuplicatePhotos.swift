import Foundation
import Vision

/// Finds visually near-duplicate photos (bursts, near-identical shots) and picks the best one to keep
/// in each cluster. Similarity comes from Vision feature prints (`VNGenerateImageFeaturePrintRequest`,
/// what Photos uses to tell shots apart); "best" comes from the on-device aesthetics score
/// (`VNDetectImageAestheticsScoresRequest`), which downranks blur. Pure (Vision only), runs off-main.
public enum NearDuplicatePhotos {
    /// A cluster of near-duplicate images and the index within it of the one to keep (the sharpest /
    /// best-scoring). Only real clusters (2+) are returned.
    public struct Group: Sendable, Equatable {
        public let urls: [URL]
        public let keepIndex: Int
        public init(urls: [URL], keepIndex: Int) {
            self.urls = urls
            self.keepIndex = keepIndex
        }
        /// The images to remove (everything but the keeper).
        public var extras: [URL] {
            urls.enumerated().filter { $0.offset != keepIndex }.map(\.element)
        }
    }

    /// Cluster the given images by visual similarity and pick a keeper for each cluster. `distance
    /// Threshold` is the max feature-print distance to count as "the same shot" (smaller = stricter).
    public static func groups(of images: [URL], distanceThreshold: Float = 0.35) -> [Group] {
        let prints: [(url: URL, print: VNFeaturePrintObservation)] = images.compactMap { url in
            featurePrint(url).map { (url, $0) }
        }
        var used = Set<Int>()
        var result: [Group] = []
        for i in prints.indices where !used.contains(i) {
            var cluster = [i]
            used.insert(i)
            for j in prints.indices where j > i && !used.contains(j) {
                var distance = Float(0)
                try? prints[i].print.computeDistance(&distance, to: prints[j].print)
                if distance < distanceThreshold {
                    cluster.append(j)
                    used.insert(j)
                }
            }
            guard cluster.count >= 2 else { continue }
            let urls = cluster.map { prints[$0].url }
            result.append(Group(urls: urls, keepIndex: bestIndex(in: urls)))
        }
        return result
    }

    static func featurePrint(_ url: URL) -> VNFeaturePrintObservation? {
        let handler = VNImageRequestHandler(url: url, options: [:])
        let request = VNGenerateImageFeaturePrintRequest()
        guard (try? handler.perform([request])) != nil else { return nil }
        return request.results?.first
    }

    /// The index of the best (highest aesthetics score) image; 0 if scores can't be computed, so the
    /// caller always has a defined keeper.
    static func bestIndex(in urls: [URL]) -> Int {
        var best = 0
        var bestScore = -Float.greatestFiniteMagnitude
        for (index, url) in urls.enumerated() {
            let score = aestheticsScore(url) ?? -Float.greatestFiniteMagnitude
            if score > bestScore {
                bestScore = score
                best = index
            }
        }
        return best
    }

    static func aestheticsScore(_ url: URL) -> Float? {
        let handler = VNImageRequestHandler(url: url, options: [:])
        let request = VNCalculateImageAestheticsScoresRequest()
        guard (try? handler.perform([request])) != nil else { return nil }
        return request.results?.first?.overallScore
    }
}

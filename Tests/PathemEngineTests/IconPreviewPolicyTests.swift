import Foundation
import Testing
import UniformTypeIdentifiers

@testable import PathemEngine

@Suite struct IconPreviewPolicyTests {
    /// File names by the group the policy must treat alike.
    static let content = [
        "photo.jpg", "shot.PNG", "live.heic", "anim.gif", "logo.svg",  // images
        "clip.mov", "talk.mp4", "old.m4v",  // video
        "report.pdf",  // PDF
    ]
    static let iconOnly = [
        "notes.txt", "README.md", "letter.rtf", "deck.key", "sheet.xlsx",  // documents
        "main.swift", "tool.py", "config.json", "page.html",  // code
        "bundle.zip", "backup.tar", "image.dmg",  // archives
        "song.mp3", "voice.m4a",  // audio has no content frame worth showing over a theme
        "mystery.zzunknownzz", "Makefile", "",  // unknown or no extension
    ]

    @Test(arguments: content)
    func themedContentFilesGetTheContentThumbnail(name: String) {
        #expect(IconPreviewPolicy.kind(forFileNamed: name, themed: true) == .contentThumbnail)
    }

    @Test(arguments: iconOnly)
    func themedOtherFilesKeepTheThemeIcon(name: String) {
        #expect(IconPreviewPolicy.kind(forFileNamed: name, themed: true) == .none)
    }

    @Test(arguments: content + iconOnly)
    func unthemedFilesBehaveAsBefore(name: String) {
        #expect(IconPreviewPolicy.kind(forFileNamed: name, themed: false) == .systemDefault)
    }

    @Test func decidesFromTheTypeItself() {
        #expect(IconPreviewPolicy.kind(for: .jpeg, themed: true) == .contentThumbnail)
        #expect(IconPreviewPolicy.kind(for: .quickTimeMovie, themed: true) == .contentThumbnail)
        #expect(IconPreviewPolicy.kind(for: .pdf, themed: true) == .contentThumbnail)
        #expect(IconPreviewPolicy.kind(for: .plainText, themed: true) == .none)
        #expect(IconPreviewPolicy.kind(for: .swiftSource, themed: true) == .none)
        #expect(IconPreviewPolicy.kind(for: .zip, themed: true) == .none)
        #expect(IconPreviewPolicy.kind(for: .mp3, themed: true) == .none)
        #expect(IconPreviewPolicy.kind(for: nil, themed: true) == .none)
        #expect(IconPreviewPolicy.kind(for: nil, themed: false) == .systemDefault)
        #expect(IconPreviewPolicy.kind(for: .plainText, themed: false) == .systemDefault)
    }
}

import Darwin
import Foundation
import Testing

@testable import PathemEngine

@Suite struct NotebookPreviewTests {
    @Test func rendersMarkdownCodeAndPlainOutputsWithoutRichExecution() throws {
        let data = Data(
            #"""
            {"cells":[
              {"cell_type":"markdown","source":["# Audit\n","criteria"]},
              {"cell_type":"code","execution_count":3,"source":["print(1)"],
               "outputs":[{"output_type":"stream","text":["1\n"]},
                          {"output_type":"display_data","data":{"text/html":"<script>bad()</script>","text/plain":"chart"}}]}
            ],"nbformat":4,"nbformat_minor":5}
            """#.utf8)
        let doc = try NotebookPreview.document(from: data)
        #expect(doc.cellCount == 2)
        #expect(doc.text.contains("Markdown cell"))
        #expect(doc.text.contains("Code cell [3]"))
        #expect(doc.text.contains("print(1)"))
        #expect(doc.text.contains("chart"))
        #expect(!doc.text.contains("<script>"))
        #expect(!doc.truncated)
    }

    @Test func rejectsNonNotebookAndOversizeInputs() {
        #expect(throws: NotebookPreview.PreviewError.invalidNotebook) {
            try NotebookPreview.document(from: Data("{}".utf8))
        }
        #expect(throws: NotebookPreview.PreviewError.tooLarge) {
            try NotebookPreview.document(
                from: Data(repeating: 0, count: NotebookPreview.maximumFileBytes + 1))
        }
    }

    @Test func boundsCellCount() throws {
        let cells = Array(
            repeating: ["cell_type": "markdown", "source": ["x"]],
            count: NotebookPreview.maximumCells + 2)
        let data = try JSONSerialization.data(withJSONObject: ["cells": cells])
        let doc = try NotebookPreview.document(from: data)
        #expect(doc.cellCount == NotebookPreview.maximumCells)
        #expect(doc.truncated)
        #expect(doc.text.contains("Preview truncated"))
    }

    @Test func outputNeverExceedsCharacterCap() throws {
        let huge = String(repeating: "x", count: NotebookPreview.maximumCharacters * 2)
        let data = try JSONSerialization.data(withJSONObject: [
            "cells": [["cell_type": "code", "source": [huge]]]
        ])
        let doc = try NotebookPreview.document(from: data)
        #expect(doc.text.count <= NotebookPreview.maximumCharacters)
        #expect(doc.truncated)
    }

    @Test func descriptorReadAcceptsRegularFileAndRejectsSpecialFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let notebook = folder.appendingPathComponent("sample.ipynb")
        try Data(#"{"cells":[{"cell_type":"markdown","source":["hello"]}]}"#.utf8)
            .write(to: notebook)
        #expect(try NotebookPreview.document(at: notebook).text.contains("hello"))

        let fifo = folder.appendingPathComponent("blocked.ipynb")
        #expect(mkfifo(fifo.path, S_IRUSR | S_IWUSR) == 0)
        #expect(throws: NotebookPreview.PreviewError.unsupportedFile) {
            try NotebookPreview.document(at: fifo)
        }
    }

    @Test func descriptorReadRejectsSparseOversizeFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "oversize-\(UUID().uuidString).ipynb")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(NotebookPreview.maximumFileBytes + 1))
        try handle.close()
        #expect(throws: NotebookPreview.PreviewError.tooLarge) {
            try NotebookPreview.document(at: url)
        }
    }
}

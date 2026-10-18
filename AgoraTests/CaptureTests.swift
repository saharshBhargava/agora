import XCTest
import UIKit
import PDFKit
@testable import Agora

@MainActor
final class CaptureTests: XCTestCase {
    private func fixtureDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testPhotoImportPersistsAndDoesNotModifyOriginal() async throws {
        let root = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.9)); try data.write(to: source)
        let directory = root.appendingPathComponent("library")
        let repository = MediaRepository(directory: directory)
        let items = try await repository.add(file: source, kind: .image)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.kind, .image)
        let saved = directory.appendingPathComponent(items[0].filename)
        XCTAssertEqual(try Data(contentsOf: saved), data)
        XCTAssertNotNil(MediaLibrary.thumbnail(saved))
        let restored = try await MediaRepository(directory: directory).load()
        XCTAssertEqual(restored, items)
        let remaining = try await repository.remove(items[0])
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
        XCTAssertEqual(try Data(contentsOf: source), data)
    }
    func testMultipageScanPDFRemainsMultipageAfterImport() async throws {
        let root = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("scan.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).writePDF(to: source) { context in
            context.beginPage(); context.beginPage()
        }
        let directory = root.appendingPathComponent("library")
        let items = try await MediaRepository(directory: directory).add(file: source, kind: .document)
        let document = PDFDocument(url: directory.appendingPathComponent(items[0].filename))
        XCTAssertEqual(document?.pageCount, 2)
    }
    func testUnsupportedImportDoesNotCreateLibraryEntry() async throws {
        let root = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("notes.txt"); try Data("not a picture".utf8).write(to: source)
        let repository = MediaRepository(directory: root.appendingPathComponent("library"))
        do { _ = try await repository.add(file: source, kind: .image); XCTFail("Expected unsupported file") }
        catch { XCTAssertTrue(error is CaptureFailure) }
        let items = try await repository.load()
        XCTAssertTrue(items.isEmpty)
    }
    func testCameraAndMicrophonePurposeStringsAreBundled() {
        XCTAssertFalse((Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String ?? "").isEmpty)
        XCTAssertFalse((Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String ?? "").isEmpty)
    }
}


extension CaptureTests {
    func testCameraPhotoResultReturnsTheNewLibraryItemForImmediateReview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        var result: Result<(URL, CaptureItem.Kind)?, Error>?
        let coordinator = CameraPicker.Coordinator { result = $0 }
        coordinator.imagePickerController(UIImagePickerController(), didFinishPickingMediaWithInfo: [.originalImage: image])
        let (file, kind) = try XCTUnwrap(try XCTUnwrap(result).get())
        defer { try? FileManager.default.removeItem(at: file) }
        let library = MediaLibrary(directory: directory)
        let first = await library.add(file: file, kind: kind)
        let second = await library.add(file: file, kind: kind)
        let capture = try XCTUnwrap(second)
        XCTAssertEqual(capture.kind, .image)
        XCTAssertNotEqual(first?.id, capture.id)
        XCTAssertEqual(library.items.first?.id, capture.id)
        XCTAssertNotNil(MediaLibrary.thumbnail(library.url(for: capture)))
    }
}

import SwiftUI
import PhotosUI
import VisionKit
import UniformTypeIdentifiers

struct CameraPicker: UIViewControllerRepresentable {
    let video: Bool
    let onComplete: (Result<(URL, CaptureItem.Kind)?, Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onComplete) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [video ? UTType.movie.identifier : UTType.image.identifier]
        picker.cameraCaptureMode = video ? .video : .photo
        picker.videoQuality = .typeHigh
        picker.videoMaximumDuration = 300
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let complete: (Result<(URL, CaptureItem.Kind)?, Error>) -> Void
        init(_ complete: @escaping (Result<(URL, CaptureItem.Kind)?, Error>) -> Void) { self.complete = complete }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { complete(.success(nil)) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            do {
                if let video = info[.mediaURL] as? URL {
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(video.pathExtension)
                    try FileManager.default.copyItem(at: video, to: file)
                    complete(.success((file, .video)))
                } else if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
                    try data.write(to: file, options: .atomic)
                    complete(.success((file, .image)))
                } else { throw CaptureFailure.unsupported }
            } catch { complete(.failure(error)) }
        }
    }
}

struct DocumentScanner: UIViewControllerRepresentable {
    let onComplete: (Result<URL?, Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onComplete) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController(); controller.delegate = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let complete: (Result<URL?, Error>) -> Void
        init(_ complete: @escaping (Result<URL?, Error>) -> Void) { self.complete = complete }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { complete(.success(nil)) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { complete(.failure(error)) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            do {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
                let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
                try renderer.writePDF(to: file) { context in
                    for page in 0..<scan.pageCount {
                        let image = scan.imageOfPage(at: page)
                        let width: CGFloat = 612, height = width * image.size.height / max(image.size.width, 1)
                        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
                        context.beginPage(withBounds: bounds, pageInfo: [:]); image.draw(in: bounds)
                    }
                }
                complete(.success(file))
            } catch { complete(.failure(error)) }
        }
    }
}

struct LibraryPicker: UIViewControllerRepresentable {
    let onComplete: ([PHPickerResult]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onComplete) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .any(of: [.images, .videos]); configuration.selectionLimit = 10
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration); picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let complete: ([PHPickerResult]) -> Void
        init(_ complete: @escaping ([PHPickerResult]) -> Void) { self.complete = complete }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) { complete(results) }
    }
    static func copyFile(from result: PHPickerResult) async throws -> (URL, CaptureItem.Kind) {
        let provider = result.itemProvider
        let video = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
        let type = video ? UTType.movie.identifier : UTType.image.identifier
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw CaptureFailure.missingFile }
                    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
                    // The provider's URL expires when this callback returns.
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: (destination, video ? .video : .image))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

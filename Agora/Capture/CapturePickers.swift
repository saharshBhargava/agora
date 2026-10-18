import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct CameraPicker: UIViewControllerRepresentable {
    let video: Bool
    let onComplete: (Result<(URL, CaptureItem.Kind)?, Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onComplete) }
    func makeUIViewController(context: Context) -> UIViewController {
        makeController(coordinator: context.coordinator)
    }
    static func availableCamera(video: Bool) -> UIImagePickerController.CameraDevice? {
        guard UIImagePickerController.isSourceTypeAvailable(.camera),
              UIImagePickerController.availableMediaTypes(for: .camera)?.contains(video ? UTType.movie.identifier : UTType.image.identifier) == true else { return nil }
        let mode: UIImagePickerController.CameraCaptureMode = video ? .video : .photo
        return [UIImagePickerController.CameraDevice.rear, .front].first { device in
            UIImagePickerController.isCameraDeviceAvailable(device) &&
            UIImagePickerController.availableCaptureModes(for: device)?.contains(NSNumber(value: mode.rawValue)) == true
        }
    }
    func makeController(coordinator: Coordinator) -> UIViewController {
        // Recheck at presentation: camera availability can change after permission prompts.
        // UIKit raises Objective-C exceptions for unavailable sources/media types.
        guard let device = Self.availableCamera(video: video) else {
            DispatchQueue.main.async { coordinator.complete(.failure(CaptureFailure.cameraUnavailable)) }
            return UIViewController()
        }
        let picker = UIImagePickerController()
        picker.delegate = coordinator
        picker.sourceType = .camera
        picker.cameraDevice = device
        // A single media type selects its capture interface. Do not force a second
        // cameraCaptureMode transition while UIKit is starting the camera session.
        picker.mediaTypes = [video ? UTType.movie.identifier : UTType.image.identifier]
        if video {
            picker.videoQuality = .typeHigh
            picker.videoMaximumDuration = 300
        }
        return picker
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
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

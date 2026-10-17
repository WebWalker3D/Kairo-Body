import SwiftUI
import UIKit

struct ManualCameraPicker: UIViewControllerRepresentable {
    let onPhoto: (UIImage) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraDevice = .front
        picker.showsCameraControls = false
        context.coordinator.picker = picker
        let overlay = UIView(frame: UIScreen.main.bounds)
        let capture = UIButton(type: .system)
        capture.setTitle("Take front photo", for: .normal)
        capture.addTarget(context.coordinator, action: #selector(Coordinator.capture), for: .touchUpInside)
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.addTarget(context.coordinator, action: #selector(Coordinator.cancel), for: .touchUpInside)
        let controls = UIStackView(arrangedSubviews: [cancel, capture])
        controls.axis = .horizontal
        controls.distribution = .fillEqually
        controls.backgroundColor = .systemBackground
        controls.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor),
            controls.heightAnchor.constraint(equalToConstant: 70)])
        picker.cameraOverlayView = overlay
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPhoto: onPhoto, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onPhoto: (UIImage) -> Void
        let onCancel: () -> Void
        weak var picker: UIImagePickerController?
        @objc func capture() { picker?.takePicture() }
        @objc func cancel() { onCancel() }

        init(onPhoto: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onPhoto = onPhoto
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if picker.cameraDevice == .front, let image = info[.originalImage] as? UIImage {
                onPhoto(image)
            } else {
                onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}

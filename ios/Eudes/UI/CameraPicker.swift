import SwiftUI
import UIKit

/// Prise de vue directe depuis le composeur.
///
/// UIKit ne propose qu'`UIImagePickerController` pour l'appareil photo : SwiftUI n'a pas de
/// vue caméra native. Cette vue ne valide rien — elle rend les octets au composeur, qui les
/// passe à `ImageAttachment.importData` exactement comme une image de la Photothèque.
///
/// Le rappel n'est appelé qu'une fois : `nil` signifie que la prise de vue a été annulée.
struct CameraPicker: UIViewControllerRepresentable {
    /// Faux sur le simulateur et sur les appareils sans caméra : le menu masque alors l'entrée.
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    let onFinish: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onFinish: (Data?) -> Void
        private var finished = false

        init(onFinish: @escaping (Data?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard !finished else { return }
            finished = true
            // Qualité haute : `ImageAttachment.importData` réduit puis recompresse en JPEG.
            let image = info[.originalImage] as? UIImage
            onFinish(image?.jpegData(compressionQuality: 0.95))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            guard !finished else { return }
            finished = true
            onFinish(nil)
        }
    }
}

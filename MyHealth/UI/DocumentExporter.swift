import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// SwiftUI bridge to `UIDocumentPickerViewController(forExporting:)`.
/// Use via `.sheet(item:)` with a binding to a `FilesExporter.ExportArtifact?`:
///
/// ```swift
/// .sheet(item: $exporter.pendingExportURL) { artifact in
///     DocumentExporter(url: artifact.url)
/// }
/// ```
///
/// The picker handles all the file-system permissions — when the user picks
/// a destination, iOS copies the source file there. We surface no errors:
/// if the user cancels, the source URL stays in `temporaryDirectory` and
/// iOS will reap it on next launch.
struct DocumentExporter: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: false)
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}

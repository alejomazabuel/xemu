import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SetupWizardView: View {
  @EnvironmentObject private var model: AppModel
  @State private var activeImportRequest: X1BoxImportRequest?
  @State private var errorMessage: String?

  private let orderedKinds: [SetupAssetKind] = [.mcpx, .flash, .hdd, .eeprom, .gamesFolder]

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text("Setup Wizard")
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .foregroundStyle(XboxTheme.text)

          Text("Import your original Xbox files and choose the games folder to unlock the iOS shell.")
            .foregroundStyle(XboxTheme.muted)

          ForEach(orderedKinds) { kind in
            VStack(alignment: .leading, spacing: 10) {
              Text(LocalizedStringKey(kind.displayName))
                .font(.headline)
                .foregroundStyle(XboxTheme.text)

              if let record = model.setupStore.summary.record(for: kind) {
                Text(record.displayName)
                  .font(.subheadline)
                  .foregroundStyle(XboxTheme.muted)
              } else {
                Text(kind.isRequired ? "Required" : "Optional")
                  .font(.subheadline)
                  .foregroundStyle(XboxTheme.muted)
              }

              Button(kind.allowsFolderSelection ? "Choose Folder" : "Import File") {
                activeImportRequest = X1BoxImportRequest(kind: kind)
              }
              .buttonStyle(.borderedProminent)
              .tint(XboxTheme.accent)
            }
            .xboxPanel()
          }

          if let errorMessage {
            Text(errorMessage)
              .foregroundStyle(.red)
              .font(.footnote)
          }

          Button("Finish Setup") {
            model.refreshRoute()
          }
          .buttonStyle(.borderedProminent)
          .tint(XboxTheme.accent)
          .disabled(!model.setupStore.summary.isCoreReady)
        }
        .padding(24)
      }
      .navigationBarHidden(true)
    }
    .sheet(item: $activeImportRequest) { request in
      X1BoxDocumentPicker(
        allowedContentTypes: request.allowedContentTypes,
        allowsMultipleSelection: false
      ) { result in
        handleImport(result, for: request.kind)
      }
    }
  }

  private func handleImport(_ result: Result<[URL], Error>, for kind: SetupAssetKind) {
    activeImportRequest = nil
    switch result {
    case .success(let urls):
      guard let url = urls.first else { return }
      do {
        try model.setupStore.importSelection(from: url, kind: kind)
        model.refreshRoute()
        errorMessage = nil
      } catch {
        errorMessage = error.localizedDescription
      }
    case .failure(let error):
      errorMessage = error.localizedDescription
    }
  }
}

struct X1BoxImportRequest: Identifiable {
  let kind: SetupAssetKind
  let allowedContentTypes: [UTType]

  var id: String { kind.rawValue }

  init(kind: SetupAssetKind, allowedContentTypes: [UTType]? = nil) {
    self.kind = kind
    if let allowedContentTypes {
      self.allowedContentTypes = allowedContentTypes
    } else if kind.allowsFolderSelection {
      self.allowedContentTypes = [.folder]
    } else {
      self.allowedContentTypes = [.data]
    }
  }

  static let embeddedCore = X1BoxImportRequest(kind: .embeddedCore, allowedContentTypes: [.item, .folder])
  static let eeprom = X1BoxImportRequest(kind: .eeprom, allowedContentTypes: [.data])
}

struct X1BoxDocumentPicker: UIViewControllerRepresentable {
  let allowedContentTypes: [UTType]
  let allowsMultipleSelection: Bool
  let onComplete: (Result<[URL], Error>) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onComplete: onComplete)
  }

  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    let controller = UIDocumentPickerViewController(
      forOpeningContentTypes: allowedContentTypes,
      asCopy: false
    )
    controller.delegate = context.coordinator
    controller.allowsMultipleSelection = allowsMultipleSelection
    return controller
  }

  func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

  final class Coordinator: NSObject, UIDocumentPickerDelegate {
    private let onComplete: (Result<[URL], Error>) -> Void

    init(onComplete: @escaping (Result<[URL], Error>) -> Void) {
      self.onComplete = onComplete
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
      onComplete(.success(urls))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
      onComplete(.success([]))
    }
  }
}

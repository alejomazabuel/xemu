import Combine
import Foundation
import X1BoxNativeCore

@MainActor
final class AppModel: ObservableObject {
  enum Route {
    case launcher
    case setup
    case library
    case emulator
  }

  @Published var route: Route = .launcher
  @Published var games: [GameEntry] = []
  @Published var isShowingSettings = false
  @Published var scanErrorMessage: String?
  @Published var emulatorErrorMessage: String?
  @Published var emulatorNoticeMessage: String?
  @Published private(set) var embeddedCoreStatusSummary: String = AppLocalizer.string("Embedded core detection has not run yet.")
  @Published private(set) var embeddedCoreResolvedPath: String?
  @Published private(set) var isEmbeddedCoreAvailable = false

  let setupStore: SetupAssetStore
  let settingsStore: SettingsStore
  let controllerMonitor: GameControllerMonitor
  let emulatorSession: EmulatorSession

  private let scanner = LibraryScanner()
  private var cancellables = Set<AnyCancellable>()

  init() {
    self.setupStore = SetupAssetStore()
    self.settingsStore = SettingsStore()
    self.controllerMonitor = GameControllerMonitor()
    self.emulatorSession = EmulatorSession()
    bindChildObjects()
    refreshEmbeddedCoreAvailability()
    refreshRoute()
  }

  init(
    setupStore: SetupAssetStore,
    settingsStore: SettingsStore,
    controllerMonitor: GameControllerMonitor,
    emulatorSession: EmulatorSession
  ) {
    self.setupStore = setupStore
    self.settingsStore = settingsStore
    self.controllerMonitor = controllerMonitor
    self.emulatorSession = emulatorSession
    bindChildObjects()
    refreshEmbeddedCoreAvailability()
    refreshRoute()
  }

  var canAttemptEmulationLaunch: Bool {
    setupStore.summary.isCoreReady && isEmbeddedCoreAvailable
  }

  var emulationReadinessMessage: String? {
    let languageCode = settingsStore.settings.appLanguage

    if !setupStore.summary.isCoreReady {
      return AppLocalizer.string(
        "Complete the required MCPX, flash, HDD, and games-folder setup before starting emulation.",
        languageCode: languageCode
      )
    }

    if isEmbeddedCoreAvailable {
      return nil
    }

    let summary = embeddedCoreStatusSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    if !summary.isEmpty {
      return summary
    }

    return AppLocalizer.string(
      "Import or bundle a signed X1BoxEmbeddedCore artifact before launching emulation on iPhone or iPad.",
      languageCode: languageCode
    )
  }

  func refreshRoute() {
    route = setupStore.summary.isCoreReady ? .library : .setup
  }

  func refreshEmbeddedCoreAvailability() {
    let bridge = X1BoxNativeBridge.shared()
    bridge.refreshEmbeddedCoreAvailability()
    isEmbeddedCoreAvailable = bridge.isEmbeddedCoreLinked()
    embeddedCoreStatusSummary = bridge.embeddedCoreStatusSummary()
    embeddedCoreResolvedPath = bridge.resolvedEmbeddedCorePath()
  }

  func reloadLibrary() async {
    refreshEmbeddedCoreAvailability()
    emulatorSession.reloadSnapshotSlots()
    do {
      let games = try setupStore.withGamesFolderURL { folderURL in
        try scanner.scanGames(in: folderURL)
      }
      self.games = games
      self.scanErrorMessage = nil
    } catch {
      self.games = []
      self.scanErrorMessage = error.localizedDescription
    }
  }

  func startDashboard() async {
    guard prepareForLaunch() else { return }
    emulatorErrorMessage = nil
    emulatorNoticeMessage = nil
    await emulatorSession.launchDashboard(setup: setupStore.summary, settings: settingsStore.settings)
    syncLaunchOutcome()
  }

  func start(game: GameEntry) async {
    guard prepareForLaunch() else { return }
    emulatorErrorMessage = nil
    emulatorNoticeMessage = nil
    await emulatorSession.launch(game: game, setup: setupStore.summary, settings: settingsStore.settings)
    syncLaunchOutcome()
  }

  func stopEmulation() {
    emulatorSession.stop()
    emulatorNoticeMessage = nil
    route = .library
  }

  func saveSnapshot(to slotNumber: Int) {
    do {
      emulatorErrorMessage = nil
      try emulatorSession.saveSnapshot(to: slotNumber)
      emulatorNoticeMessage = emulatorSession.snapshotActionMessage
    } catch {
      emulatorErrorMessage = error.localizedDescription
    }
  }

  func deleteSnapshot(_ slot: EmulatorSession.SnapshotSlot) {
    do {
      emulatorErrorMessage = nil
      try emulatorSession.deleteSnapshot(slotNumber: slot.slotNumber)
      emulatorNoticeMessage = emulatorSession.snapshotActionMessage
    } catch {
      emulatorErrorMessage = error.localizedDescription
    }
  }

  func resumeSnapshot(_ slot: EmulatorSession.SnapshotSlot) async {
    guard prepareForLaunch() else { return }
    emulatorErrorMessage = nil
    emulatorNoticeMessage = nil

    switch slot.launchKind {
    case "dashboard":
      await emulatorSession.launchDashboard(setup: setupStore.summary, settings: settingsStore.settings)
    case "game":
      guard let relativePath = slot.relativePath,
            let game = games.first(where: { $0.relativePath == relativePath }) else {
        emulatorErrorMessage = String(
          format: AppLocalizer.string(
            "The original game file for snapshot slot %d could not be found in the current library.",
            languageCode: settingsStore.settings.appLanguage
          ),
          slot.slotNumber
        )
        return
      }
      await emulatorSession.launch(game: game, setup: setupStore.summary, settings: settingsStore.settings)
    default:
      emulatorErrorMessage = String(
        format: AppLocalizer.string("Snapshot slot %d is empty.", languageCode: settingsStore.settings.appLanguage),
        slot.slotNumber
      )
      return
    }

    syncLaunchOutcome()
    if emulatorErrorMessage == nil {
      do {
        _ = try emulatorSession.restoreNativeSnapshotIfAvailable(for: slot)
      } catch {
        emulatorErrorMessage = error.localizedDescription
      }

      if emulatorErrorMessage == nil {
        emulatorNoticeMessage = String(
          format: AppLocalizer.string(
            "Resumed slot %d by restoring the saved boot target. Full memory-state resume will be connected when the native snapshot API is available.",
            languageCode: settingsStore.settings.appLanguage
          ),
          slot.slotNumber
        )
      }
    }

    if emulatorErrorMessage == nil && slot.nativeSnapshotName != nil {
      emulatorNoticeMessage = String(
        format: AppLocalizer.string(
          "Resumed slot %d and requested native snapshot restore when available.",
          languageCode: settingsStore.settings.appLanguage
        ),
        slot.slotNumber
      )
    } else if emulatorErrorMessage == nil {
      emulatorNoticeMessage = String(
        format: AppLocalizer.string(
          "Resumed slot %d by restoring the saved boot target. Full memory-state resume will be connected when the native snapshot API is available.",
          languageCode: settingsStore.settings.appLanguage
        ),
        slot.slotNumber
      )
    }
  }

  private func bindChildObjects() {
    setupStore.objectWillChange
      .sink { [weak self] _ in
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)

    settingsStore.objectWillChange
      .sink { [weak self] _ in
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)

    controllerMonitor.objectWillChange
      .sink { [weak self] _ in
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)

    emulatorSession.objectWillChange
      .sink { [weak self] _ in
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)
  }

  private func prepareForLaunch() -> Bool {
    refreshEmbeddedCoreAvailability()

    guard canAttemptEmulationLaunch else {
      emulatorNoticeMessage = nil
      emulatorErrorMessage = emulationReadinessMessage
      route = .library
      return false
    }

    return true
  }

  private func syncLaunchOutcome() {
    emulatorNoticeMessage = emulatorSession.launchWarning

    switch emulatorSession.state {
    case .running, .preparing:
      emulatorErrorMessage = nil
      route = .emulator
    case .failed(let message):
      emulatorErrorMessage = message
      route = .library
    case .idle:
      route = .library
    }
  }
}

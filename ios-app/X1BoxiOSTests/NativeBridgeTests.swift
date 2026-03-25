import XCTest
@testable import X1BoxiOS

@MainActor
final class NativeBridgeTests: XCTestCase {
  func testBundledEmbeddedCoreCanBeResolved() throws {
    let bridge = X1BoxNativeBridge.shared
    bridge.refreshEmbeddedCoreAvailability()

    guard let resolvedPath = bridge.resolvedEmbeddedCorePath() else {
      throw XCTSkip("No embedded core image was bundled for this test configuration.")
    }

    XCTAssertTrue(bridge.isEmbeddedCoreLinked(), "The embedded core symbols should resolve when the bundled image is present.")
    XCTAssertFalse(resolvedPath.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: resolvedPath))
    XCTAssertTrue(resolvedPath.contains("libxemu-ios-core") || resolvedPath.contains("X1BoxEmbeddedCore"))
  }

  func testEmbeddedCoreStatusReportsDynamicImageLoad() throws {
    let bridge = X1BoxNativeBridge.shared
    bridge.refreshEmbeddedCoreAvailability()

    guard bridge.resolvedEmbeddedCorePath() != nil else {
      throw XCTSkip("No embedded core image was bundled for this test configuration.")
    }

    let summary = bridge.embeddedCoreStatusSummary()
    XCTAssertFalse(summary.isEmpty)
    XCTAssertTrue(summary.localizedCaseInsensitiveContains("dynamic embedded core image loaded"))
  }
}

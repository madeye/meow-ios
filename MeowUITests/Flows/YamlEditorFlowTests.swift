import XCTest

/// Flow: edit a profile's YAML, validate, save, and revert.
final class YamlEditorFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testEditSaveValidYaml() throws {
        throw XCTSkip("blocked on T5.9")
        // navigate Subscriptions → row → editor
        // modify one line, tap Save → returns to Subscriptions, lastUpdated changes
    }

    func testSaveInvalidYamlShowsError() throws {
        throw XCTSkip("blocked on T5.9 + T2.4 validator FFI")
        // inject malformed YAML, tap Save → alert with specific error message
        // file on disk unchanged (verify via @Binding or launch-env readback)
    }

    func testRevertRestoresBackup() throws {
        throw XCTSkip("blocked on T5.9")
        // save edit A, edit to B, tap Revert → content is A again
    }
}

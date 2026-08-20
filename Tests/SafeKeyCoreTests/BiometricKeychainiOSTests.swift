#if os(iOS)
import XCTest
import LocalAuthentication
@testable import SafeKeyCore

/// iOS-only checks on the biometric key store.
///
/// These separate the two things that can break Face ID unlock — writing the
/// biometry-protected Keychain item, and satisfying the evaluation prompt — so
/// a failure says which one it was. Hosted in the app, so they run with the
/// app's `application-identifier`; without it every Keychain call would fail
/// with errSecMissingEntitlement and prove nothing.
final class BiometricKeychainiOSTests: XCTestCase {
    private let factor = BiometricFactor()
    private var vaultID: UUID!

    override func setUp() {
        super.setUp()
        vaultID = UUID()
    }

    override func tearDown() {
        try? factor.disable(vaultID: vaultID)
        factor.forgetStrategyMarker(vaultID: vaultID)
        super.tearDown()
    }

    /// The data-protection Keychain must accept a `.biometryCurrentSet` item.
    /// This is the write that silently failed on the Mac for months, and the
    /// one an unsigned iOS build cannot do at all.
    func testEnableWritesAccessControlledItem() async throws {
        try XCTSkipUnless(
            BiometricFactor.isBiometryAvailable(),
            "no biometry enrolled — enrol Face ID on this simulator to run this"
        )

        let secret = Data(repeating: 7, count: 32)
        // confirm: false — this test is about the Keychain write, not the prompt.
        let strategy = try await factor.enable(secret: secret, vaultID: vaultID, confirm: false)

        XCTAssertEqual(
            strategy,
            .accessControl,
            "iOS must use the biometry-gated item; falling back would store the vault key without biometric protection"
        )
        XCTAssertTrue(factor.isEnrolled(vaultID: vaultID))
    }

    /// What the simulator actually does with an evaluation. Recorded rather
    /// than asserted: a headless simulator has no way to answer the prompt, so
    /// this documents the error instead of failing the suite over it.
    func testEvaluationOutcomeIsReported() async throws {
        try XCTSkipUnless(BiometricFactor.isBiometryAvailable(), "no biometry enrolled")

        let context = LAContext()
        var authError: NSError?
        XCTAssertTrue(
            context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError),
            "canEvaluatePolicy said no: \(authError?.localizedDescription ?? "unknown")"
        )

        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "run the SafeKey biometric self-test"
            )
            XCTAssertTrue(ok)
        } catch {
            let code = (error as NSError).code
            throw XCTSkip("simulator did not complete the evaluation (LAError \(code)): \(error.localizedDescription)")
        }
    }
}
#endif

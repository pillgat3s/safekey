#if os(iOS)
import XCTest
import SafeKeyCore
@testable import SafeKeyiOS

/// The two iOS layouts remember where the user is in different shapes: the
/// iPhone home screen as a navigation stack, the sidebar layout as a selection
/// with wallets pushed over it. An iPhone Duo swaps the layouts live as it
/// opens and closes, so each must be able to pick up exactly where the other
/// left off.
@MainActor
final class ResumeStateiOSTests: XCTestCase {
    private let wallet = UUID()
    private let group = UUID()

    func testWalletOpenOnTheHomeStackIsSelectedInTheSidebar() {
        var state = ResumeState()
        state.noteHome([.list(.favorites), .entry(wallet)])
        XCTAssertEqual(state.splitSelection, .tile(.favorites))
        XCTAssertEqual(state.splitPath, [.entry(wallet)])
    }

    func testWalletOpenInTheSidebarIsOnTheHomeStack() {
        var state = ResumeState()
        state.noteSplit(selection: .chain(.solana), path: [.entry(wallet)])
        XCTAssertEqual(state.homePath, [.list(.chain(.solana)), .entry(wallet)])
    }

    func testGroupsAndTilesRoundTrip() {
        for filter in [EntryFilter.all, .favorites, .seedPhrases, .privateKeys, .chain(.bitcoin), .group(group)] {
            XCTAssertEqual(VaultSplitView.Selection(filter).filter, filter)
        }
    }

    func testHomeScreenItselfMeansTheDefaultSidebarRow() {
        var state = ResumeState()
        state.noteSplit(selection: .group(group), path: [.entry(wallet)])
        state.noteHome([])
        XCTAssertEqual(state.splitSelection, .tile(.all))
        XCTAssertTrue(state.splitPath.isEmpty)
    }

    func testTheDefaultSidebarRowWithNothingPushedMeansTheHomeScreen() {
        var state = ResumeState()
        state.noteHome([.list(.chain(.evm)), .entry(wallet)])
        state.noteSplit(selection: .tile(.all), path: [])
        XCTAssertTrue(state.homePath.isEmpty)
    }

    func testAListWithoutAWalletStillCarriesAcross() {
        var state = ResumeState()
        state.noteSplit(selection: .tile(.privateKeys), path: [])
        XCTAssertEqual(state.homePath, [.list(.privateKeys)])
        state.noteHome([.list(.group(group))])
        XCTAssertEqual(state.splitSelection, .group(group))
        XCTAssertTrue(state.splitPath.isEmpty)
    }
}
#endif

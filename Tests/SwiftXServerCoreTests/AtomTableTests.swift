import XCTest
@testable import SwiftXServerCore

final class AtomTableTests: XCTestCase {

    func testPredefinedAtomsResolvable() {
        let atoms = AtomTable()
        XCTAssertEqual(atoms.lookupOrZero("PRIMARY"), 1)
        XCTAssertEqual(atoms.lookupOrZero("WM_NAME"), 39)
        XCTAssertEqual(atoms.lookupOrZero("WM_CLASS"), 67)
        XCTAssertEqual(atoms.name(for: 39), "WM_NAME")
    }

    func testInternIsIdempotent() {
        let atoms = AtomTable()
        let a = atoms.intern("WM_DELETE_WINDOW")
        let b = atoms.intern("WM_DELETE_WINDOW")
        XCTAssertEqual(a, b)
        XCTAssertGreaterThanOrEqual(a, 69)
    }

    func testInternAssignsMonotonicIDsForNewNames() {
        let atoms = AtomTable()
        let a = atoms.intern("WM_PROTOCOLS")
        let b = atoms.intern("WM_DELETE_WINDOW")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(b, a + 1)
    }

    func testLookupOrZeroReturnsZeroForUnknownName() {
        let atoms = AtomTable()
        XCTAssertEqual(atoms.lookupOrZero("DEFINITELY_NOT_AN_ATOM"), 0)
    }
}

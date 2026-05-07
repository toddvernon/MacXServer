import Framer

// Atom interner. Atoms 1..68 are pre-defined per the X11 spec; we delegate to
// Framer.predefinedAtomName for those. New atoms get monotonic IDs starting at
// 69. Same name always returns the same ID for the lifetime of the table —
// this matters for `same name → same ID` invariants xclock and the WM rely on.

public final class AtomTable {
    private var nameToAtom: [String: UInt32] = [:]
    private var atomToName: [UInt32: String] = [:]
    private var nextAtom: UInt32 = 69

    public init() {
        // Seed predefined atoms so name lookup works without a separate fallback.
        for atom in 1...68 {
            if let name = predefinedAtomName(UInt32(atom)) {
                nameToAtom[name] = UInt32(atom)
                atomToName[UInt32(atom)] = name
            }
        }
    }

    /// Equivalent to InternAtom with onlyIfExists=false: assigns a fresh atom
    /// for new names.
    public func intern(_ name: String) -> UInt32 {
        if let existing = nameToAtom[name] { return existing }
        let id = nextAtom
        nextAtom += 1
        nameToAtom[name] = id
        atomToName[id] = name
        return id
    }

    /// Equivalent to InternAtom with onlyIfExists=true: 0 (None) when missing.
    public func lookupOrZero(_ name: String) -> UInt32 {
        nameToAtom[name] ?? 0
    }

    public func name(for atom: UInt32) -> String? {
        atomToName[atom]
    }

    public var count: Int { atomToName.count }
}

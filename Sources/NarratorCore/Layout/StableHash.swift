/// FNV-1a over UTF-8. Swift's Hasher is seeded per process; the spec needs the same
/// quip to get the same sticker/note angle and color group across launches.
public func stableHash(_ string: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x0000_0100_0000_01b3
    }
    return hash
}

/// Sticker tilt, visual-spec §2.4: −3° … +3°.
public func stickerAngle(quipID: String) -> Double {
    Double(Int(stableHash(quipID) % 7) - 3)
}

/// Note tilt, visual-spec §2.5: −4° … +4°.
public func noteAngle(quipID: String) -> Double {
    Double(Int(stableHash(quipID) % 9) - 4)
}

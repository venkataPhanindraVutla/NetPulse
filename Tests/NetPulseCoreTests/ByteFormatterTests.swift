import Testing
@testable import NetPulseCore

@Test func decimalBytes() {
    #expect(ByteFormatter.bytes(0) == "0 B")
    #expect(ByteFormatter.bytes(999) == "999 B")
    #expect(ByteFormatter.bytes(1_000) == "1.0 KB")
    #expect(ByteFormatter.bytes(412_000_000) == "412 MB")
    #expect(ByteFormatter.bytes(3_210_000_000) == "3.21 GB")
    #expect(ByteFormatter.bytes(64_200_000_000) == "64.2 GB")
}

@Test func rates() {
    #expect(ByteFormatter.rate(8_400_000, unit: .bytesPerSecond) == "8.4 MB/s")
    #expect(ByteFormatter.rate(8_400_000, unit: .bitsPerSecond) == "67.2 Mbps")
    #expect(ByteFormatter.rate(950, unit: .bytesPerSecond) == "950 B/s")
    #expect(ByteFormatter.compactRate(8_400_000, unit: .bytesPerSecond) == "8.4M")
}

@Test func roundingCarriesIntoNextUnit() {
    #expect(ByteFormatter.bytes(999_600) == "1.0 MB")
    #expect(ByteFormatter.rate(999.6, unit: .bytesPerSecond) == "1.0 KB/s")
}

@Test func invalidRatesClampToZero() {
    #expect(ByteFormatter.rate(-5, unit: .bytesPerSecond) == "0 B/s")
    #expect(ByteFormatter.rate(.nan, unit: .bitsPerSecond) == "0 bps")
}

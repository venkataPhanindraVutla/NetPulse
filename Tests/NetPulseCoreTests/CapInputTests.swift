import Foundation
import Testing
@testable import NetPulseCore

private let us = Locale(identifier: "en_US")
private let de = Locale(identifier: "de_DE")

@Test func parsesPlainAndDecimalGB() {
    #expect(CapInput.limitBytes(fromGB: "100", locale: us) == 100_000_000_000)
    #expect(CapInput.limitBytes(fromGB: "0.1", locale: us) == 100_000_000)
    #expect(CapInput.limitBytes(fromGB: " 5 ", locale: us) == 5_000_000_000)
    #expect(CapInput.limitBytes(fromGB: "0,1", locale: de) == 100_000_000)
}

@Test func rejectsGroupingAndInvalidInput() {
    #expect(CapInput.limitBytes(fromGB: "1,000", locale: us) == nil)
    #expect(CapInput.limitBytes(fromGB: "1.000", locale: de) == nil)
    #expect(CapInput.limitBytes(fromGB: "1,000.5", locale: us) == nil)
    #expect(CapInput.limitBytes(fromGB: "-1", locale: us) == nil)
    #expect(CapInput.limitBytes(fromGB: "0", locale: us) == nil)
    #expect(CapInput.limitBytes(fromGB: "abc", locale: us) == nil)
    #expect(CapInput.limitBytes(fromGB: "", locale: us) == nil)
    #expect(CapInput.limitBytes(fromGB: "1e30", locale: us) == nil)
}

@Test func formatsWithLocaleSeparator() {
    #expect(CapInput.text(forBytes: 100_000_000, locale: us) == "0.1")
    #expect(CapInput.text(forBytes: 100_000_000, locale: de) == "0,1")
    #expect(CapInput.text(forBytes: 100_000_000_000, locale: us) == "100")
    #expect(CapInput.text(forBytes: 1_500_000_000_000, locale: us) == "1500")
}

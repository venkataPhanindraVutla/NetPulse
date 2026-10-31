import Foundation
import Testing
@testable import NetPulseCore

private func fixtureLines(_ name: String) -> [String] {
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    guard let url = Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures"),
          let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.components(separatedBy: .newlines)
}

@Test func parsesNameWithSpacesParensAndDots() {
    #expect(NettopParser.parseRow("Code Helper (Pl.29154,10,20,") == ProcessSample(pid: 29154, truncatedName: "Code Helper (Pl", bytesIn: 10, bytesOut: 20))
    #expect(NettopParser.parseRow("Google Chrome H.1135,48,56,")?.pid == 1135)
    #expect(NettopParser.parseRow("com.apple.audio.477,0,0,")?.truncatedName == "com.apple.audio")
}

@Test func firstBlockDiscarded_secondEmitted() {
    var p = NettopParser()
    var emitted: [[ProcessSample]] = []
    let lines = fixtureLines("nettop-delta.csv")
    #expect(!lines.isEmpty)
    for line in lines { if let b = p.consume(line: line) { emitted.append(b) } }
    if let b = p.consume(line: ",bytes_in,bytes_out,") { emitted.append(b) }
    #expect(emitted.count == 2)
    #expect(emitted[0].allSatisfy { $0.bytesIn < 50_000_000 })
}

@Test func garbageCounted() {
    var p = NettopParser()
    _ = p.consume(line: "not,a,row")
    #expect(p.malformedLineCount == 1)
}

@Test func parsesNameContainingComma() {
    #expect(NettopParser.parseRow("Acme, Inc. Hel.812,300,40,") == ProcessSample(pid: 812, truncatedName: "Acme, Inc. Hel", bytesIn: 300, bytesOut: 40))
    #expect(NettopParser.parseRow("a,b,c.9,1,2,")?.truncatedName == "a,b,c")
    #expect(NettopParser.parseRow("curl.42,5000,100") == ProcessSample(pid: 42, truncatedName: "curl", bytesIn: 5000, bytesOut: 100))
    #expect(NettopParser.parseRow("curl.42,abc,100,") == nil)
}

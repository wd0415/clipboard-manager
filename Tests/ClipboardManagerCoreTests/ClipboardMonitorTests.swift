import Foundation
import Testing
@testable import ClipboardManagerCore

@Test func normalizerRemovesImmediateDuplicates() {
    let normalizer = ClipNormalizer()

    #expect(normalizer.accept(.text("same")))
    #expect(!normalizer.accept(.text("same")))
    #expect(normalizer.accept(.text("different")))
}

@Test func rawImageAndTextBecomePayloads() {
    #expect(ClipNormalizer.payload(from: .text("hello")) == .text("hello"))
    #expect(ClipNormalizer.payload(from: .image(Data([1, 2]))) == .image(Data([1, 2])))
}

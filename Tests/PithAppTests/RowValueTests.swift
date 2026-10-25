import PithCore
import Testing

@testable import Pith

/// R110 and R122: a reading with no value says whether the next reading has it. A first sample is
/// "not available yet"; any other reason, such as an accounting mismatch or a failed read, is "not
/// available", with one plain sentence as its tooltip and no internal reason.
@Test func aMissingReadingSaysWhetherTheNextOneHasIt() {
  let first = RowValue.missing(Reading<Double>.firstSample)
  #expect(first.text == "—" && first.label == "not available yet" && first.help == nil)
  for reason in ["accounting mismatch", "host_statistics64 failed: 5", "volume unmounted"] {
    let missing = RowValue.missing(Reading<UInt64>.unavailable(reason))
    #expect(missing.text == "—" && missing.label == "not available", "\(reason)")
    #expect(missing.help == "Pith couldn't measure this right now.", "\(reason)")
  }
}

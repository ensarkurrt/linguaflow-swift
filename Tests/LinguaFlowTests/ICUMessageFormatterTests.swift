import Testing

@testable import LinguaFlow

@Test func formatsPluralAndSelect() throws {
  let pattern =
    "{gender, select, female {{count, plural, one {She has one} other {She has #}}} other {They have #}}"
  let output = try ICUMessageFormatter.format(
    pattern, arguments: ["gender": .string("female"), "count": .number(2)], locale: "en")
  #expect(output == "She has 2")
}

@Test func evaluatesOnlyTheSelectedBranch() throws {
  let output = try ICUMessageFormatter.format(
    "{gender, select, female {Welcome, {name}} other {Welcome, {unused}}}",
    arguments: ["gender": .string("female"), "name": .string("Ada")], locale: "en")
  #expect(output == "Welcome, Ada")
}

@Test func appliesLocalePluralCategories() throws {
  let pattern = "{count, plural, one {one} few {few} many {many} other {other}}"
  #expect(
    try ICUMessageFormatter.format(
      pattern, arguments: ["count": .number(2)], locale: "ru") == "few")
  #expect(
    try ICUMessageFormatter.format(
      pattern, arguments: ["count": .number(11)], locale: "ru") == "many")
}

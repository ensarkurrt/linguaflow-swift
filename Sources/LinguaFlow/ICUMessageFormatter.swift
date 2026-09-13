import Foundation

enum ICUMessageFormatter {
  static func format(_ pattern: String, arguments: [String: LfArgument], locale: String) throws
    -> String
  {
    var parser = Parser(
      pattern, arguments: arguments, locale: Locale(identifier: locale), pound: nil)
    return try parser.message(untilClosingBrace: false)
  }
}

private struct Parser {
  let characters: [Character]
  let arguments: [String: LfArgument]
  let locale: Locale
  var index = 0
  var pound: Double?

  init(_ value: String, arguments: [String: LfArgument], locale: Locale, pound: Double?) {
    characters = Array(value)
    self.arguments = arguments
    self.locale = locale
    self.pound = pound
  }

  mutating func message(untilClosingBrace: Bool) throws -> String {
    var output = ""
    while index < characters.count {
      let char = characters[index]
      if char == "}" && untilClosingBrace {
        index += 1
        return output
      }
      if char == "{" {
        output += try placeholder()
        continue
      }
      if char == "#", let pound {
        output += pound.formatted(.number.locale(locale))
        index += 1
        continue
      }
      if char == "'" {
        output += quoted()
        continue
      }
      output.append(char)
      index += 1
    }
    if untilClosingBrace { throw LinguaFlowError.messageFormat("Missing closing brace") }
    return output
  }

  mutating func placeholder() throws -> String {
    index += 1
    let name = token(stoppingAt: [",", "}"])
    guard let argument = arguments[name] else {
      throw LinguaFlowError.messageFormat("Missing argument \(name)")
    }
    if consume("}") { return argument.string }
    guard consume(",") else { throw LinguaFlowError.messageFormat("Invalid argument \(name)") }
    let kind = token(stoppingAt: [",", "}"])
    if consume("}") { return try simple(argument, kind: kind, style: nil) }
    guard consume(",") else { throw LinguaFlowError.messageFormat("Invalid argument kind \(kind)") }
    if kind == "select" { return try select(argument.string) }
    if kind == "plural", let number = argument.number { return try plural(number) }
    let style = token(stoppingAt: ["}"])
    guard consume("}") else { throw LinguaFlowError.messageFormat("Missing closing brace") }
    return try simple(argument, kind: kind, style: style)
  }

  func simple(_ argument: LfArgument, kind: String, style: String?) throws -> String {
    switch kind {
    case "number":
      guard let number = argument.number else {
        throw LinguaFlowError.messageFormat("Number argument required")
      }
      return number.formatted(.number.locale(locale))
    case "date", "time":
      guard let date = argument.date else {
        throw LinguaFlowError.messageFormat("Date argument required")
      }
      let formatter = DateFormatter()
      formatter.locale = locale
      formatter.dateStyle = kind == "date" ? dateStyle(style) : .none
      formatter.timeStyle = kind == "time" ? dateStyle(style) : .none
      return formatter.string(from: date)
    default: throw LinguaFlowError.messageFormat("Unsupported argument kind \(kind)")
    }
  }

  func dateStyle(_ style: String?) -> DateFormatter.Style {
    switch style?.trimmingCharacters(in: .whitespacesAndNewlines) {
    case "short": .short
    case "long": .long
    case "full": .full
    default: .medium
    }
  }

  mutating func select(_ selector: String) throws -> String {
    var choices: [String: String] = [:]
    while true {
      skipWhitespace()
      if consume("}") { break }
      let key = token(stoppingAt: ["{"])
      guard consume("{") else { throw LinguaFlowError.messageFormat("Invalid select") }
      choices[key] = try block()
    }
    guard let result = choices[selector] ?? choices["other"] else {
      throw LinguaFlowError.messageFormat("Select needs other")
    }
    var selected = Parser(result, arguments: arguments, locale: locale, pound: pound)
    return try selected.message(untilClosingBrace: false)
  }

  mutating func plural(_ number: Double) throws -> String {
    skipWhitespace()
    var offset = 0.0
    let start = index
    if remaining.hasPrefix("offset:") {
      index += 7
      offset = Double(token(stoppingAt: [" ", "\t", "\n", "{"])) ?? 0
    } else {
      index = start
    }
    var choices: [String: String] = [:]
    while true {
      skipWhitespace()
      if consume("}") { break }
      let key = token(stoppingAt: ["{"])
      guard consume("{") else { throw LinguaFlowError.messageFormat("Invalid plural") }
      choices[key] = try block()
    }
    let exact = "=" + (number.rounded() == number ? String(Int(number)) : String(number))
    let category = pluralCategory(number - offset)
    guard let result = choices[exact] ?? choices[category] ?? choices["other"] else {
      throw LinguaFlowError.messageFormat("Plural needs other")
    }
    var selected = Parser(result, arguments: arguments, locale: locale, pound: number - offset)
    return try selected.message(untilClosingBrace: false)
  }

  func pluralCategory(_ number: Double) -> String {
    let language = locale.languageCode ?? "en"
    let integer = Int(number)
    let isInteger = number.rounded() == number
    let mod10 = integer % 10
    let mod100 = integer % 100
    switch language {
    case "ar":
      if number == 0 { return "zero" }
      if number == 1 { return "one" }
      if number == 2 { return "two" }
      if isInteger, (3...10).contains(mod100) { return "few" }
      if isInteger, (11...99).contains(mod100) { return "many" }
    case "ru", "uk", "be":
      if isInteger, mod10 == 1, mod100 != 11 { return "one" }
      if isInteger, (2...4).contains(mod10), !(12...14).contains(mod100) { return "few" }
      if isInteger, mod10 == 0 || (5...9).contains(mod10) || (11...14).contains(mod100) {
        return "many"
      }
    case "pl":
      if number == 1 { return "one" }
      if isInteger, (2...4).contains(mod10), !(12...14).contains(mod100) { return "few" }
      if isInteger { return "many" }
    case "cs", "sk":
      if number == 1 { return "one" }
      if isInteger, (2...4).contains(integer) { return "few" }
      if !isInteger { return "many" }
    case "sl":
      if isInteger, mod100 == 1 { return "one" }
      if isInteger, mod100 == 2 { return "two" }
      if !isInteger || (3...4).contains(mod100) { return "few" }
    case "lt":
      if mod10 == 1, !(11...19).contains(mod100) { return "one" }
      if (2...9).contains(mod10), !(11...19).contains(mod100) { return "few" }
      if !isInteger { return "many" }
    case "lv":
      if mod10 == 0 || (11...19).contains(mod100) { return "zero" }
      if mod10 == 1, mod100 != 11 { return "one" }
    case "ro":
      if number == 1 { return "one" }
      if !isInteger || number == 0 || (1...19).contains(mod100) { return "few" }
    case "he":
      if number == 1 { return "one" }
      if number == 2 { return "two" }
      if isInteger, integer != 0, integer % 10 == 0 { return "many" }
    case "fr", "pt":
      if number >= 0, number < 2 { return "one" }
    default:
      if number == 1 { return "one" }
    }
    return "other"
  }

  mutating func block() throws -> String {
    let start = index
    var depth = 1
    var isQuoted = false
    while index < characters.count {
      let char = characters[index]
      if char == "'" {
        if index + 1 < characters.count, characters[index + 1] == "'" {
          index += 2
          continue
        }
        isQuoted.toggle()
      } else if !isQuoted, char == "{" {
        depth += 1
      } else if !isQuoted, char == "}" {
        depth -= 1
        if depth == 0 {
          let value = String(characters[start..<index])
          index += 1
          return value
        }
      }
      index += 1
    }
    throw LinguaFlowError.messageFormat("Missing closing brace")
  }

  mutating func token(stoppingAt stops: Set<Character>) -> String {
    skipWhitespace()
    let start = index
    while index < characters.count && !stops.contains(characters[index]) { index += 1 }
    return String(characters[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
  }
  mutating func skipWhitespace() {
    while index < characters.count && characters[index].isWhitespace { index += 1 }
  }
  mutating func consume(_ char: Character) -> Bool {
    skipWhitespace()
    guard index < characters.count, characters[index] == char else { return false }
    index += 1
    return true
  }
  mutating func quoted() -> String {
    index += 1
    if index < characters.count, characters[index] == "'" {
      index += 1
      return "'"
    }
    var output = ""
    while index < characters.count {
      let char = characters[index]
      index += 1
      if char == "'" { break }
      output.append(char)
    }
    return output
  }
  var remaining: String { String(characters[index...]) }
}

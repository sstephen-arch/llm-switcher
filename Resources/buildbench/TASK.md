# Build Bench task: BenchKit

Build a small Swift library, **BenchKit**, in this folder (a Swift package is already set up:
`Package.swift`, `Sources/BenchKit/`, `Tests/BenchKitTests/`). Work autonomously; nobody will
answer questions. Make everything below public, exactly as named.

Check your work with:

```
swift build --disable-sandbox 2>&1 | tail -20
swift test --disable-sandbox 2>&1 | tail -30
```

A hidden test suite checks every rule below after each pass, and you will be told which of its
tests fail. Write your own tests too. When everything is done and your tests pass, write `DONE.md`
saying what you built and what you checked (only claim what you actually ran).

## 1. INI parser

```swift
public enum INIError: Error, Equatable { case badLine(Int), emptySection(Int), emptyKey(Int) }
public enum INI { public static func parse(_ text: String) throws -> [String: [String: String]] }
```

- Split the text into lines on `\n`; drop a trailing `\r` from each line. Line numbers start at 1.
- A line that is blank (only spaces/tabs), or whose first non-space character is `;` or `#`, is ignored.
- `[name]` (after trimming the line) starts a section; the name is trimmed. An empty name throws
  `emptySection(line)`. A section that appears twice is one section (keys merge). A declared
  section with no keys is still in the result, with an empty dictionary.
- `key = value` splits at the FIRST `=`; key and value are trimmed. An empty key throws `emptyKey(line)`.
  Keys before any section header go into section `""` (which appears in the result only if it gets a key).
- Values: if the trimmed value is at least 2 characters long and starts and ends with `"`, remove those
  quotes and turn `\"` into `"` and `\\` into `\` (nothing else is changed; `;` and `#` inside quotes stay).
  Otherwise, an inline comment is removed: everything from the first ` ;` or ` #` (a space followed by
  `;` or `#`) to the end of the line, then the value is trimmed again.
- A key that appears twice in a section: the last value wins.
- Any other line (e.g. no `=` and not a section) throws `badLine(line)`.

## 2. LRU cache

```swift
public final class LRUCache<Key: Hashable, Value> {
    public init(capacity: Int)
    public func get(_ key: Key) -> Value?
    public func put(_ key: Key, _ value: Value)
    public var count: Int { get }
    public var keys: [Key] { get }        // most recently used first
}
```

- A capacity below 0 counts as 0. A cache of capacity 0 stores nothing.
- `get` returns the value and makes that key the most recently used. A miss changes nothing.
- `put` inserts or updates the value and makes the key the most recently used; when that leaves more
  than `capacity` entries, the least recently used one is removed.

## 3. Expression evaluator

```swift
public enum ExprError: Error, Equatable { case divisionByZero, unknownVariable(String), syntax }
public enum Expr {
    public static func evaluate(_ s: String, variables: [String: Double] = [:]) throws -> Double
}
```

- Spaces and tabs are ignored between tokens.
- Numbers: one or more digits, optionally followed by `.` and one or more digits (`3`, `2.5`;
  `.5`, `5.` and `1.2.3` are syntax errors).
- Names: a letter or `_`, then letters, digits or `_`. A name is looked up in `variables`; a missing
  one throws `unknownVariable(name)`.
- Operators, from tightest to loosest:
  1. `^` power, right-associative (`2^3^2` = 512);
  2. unary `-` and `+` (so `-2^2` = -4, and `2^-1` = 0.5 because a unary sign may start an operand);
  3. `*`, `/`, `%` (floating-point remainder, like `fmod`), left-associative;
  4. `+`, `-`, left-associative.
- Parentheses group. `/` or `%` by zero throws `divisionByZero`.
- Anything else (empty input, unbalanced parentheses, a dangling operator, two operands in a row,
  an unknown character) throws `syntax`.

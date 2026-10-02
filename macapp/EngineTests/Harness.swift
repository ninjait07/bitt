import Foundation

/// A tiny assert harness so the engine can be tested from the terminal without
/// dragging in XCTest or a package manifest.
enum Check {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failed = 0
    nonisolated(unsafe) static var currentSection = ""

    static func section(_ name: String) {
        currentSection = name
        print("\n\u{001B}[1m\(name)\u{001B}[0m")
    }

    static func that(_ name: String, _ body: () throws -> Bool) {
        do {
            if try body() {
                passed += 1
                print("  ok    \(name)")
            } else {
                failed += 1
                print("  \u{001B}[31mFAIL\u{001B}[0m  \(name)")
            }
        } catch {
            failed += 1
            print("  \u{001B}[31mFAIL\u{001B}[0m  \(name) — threw \(error)")
        }
    }

    /// The async twin of `that`, for checks that have to await the engine.
    static func that(_ name: String, _ body: () async throws -> Bool) async {
        do {
            if try await body() {
                passed += 1
                print("  ok    \(name)")
            } else {
                failed += 1
                print("  \u{001B}[31mFAIL\u{001B}[0m  \(name)")
            }
        } catch {
            failed += 1
            print("  \u{001B}[31mFAIL\u{001B}[0m  \(name) — threw \(error)")
        }
    }

    static func equal<T: Equatable>(_ name: String, _ lhs: @autoclosure () throws -> T,
                                    _ rhs: @autoclosure () throws -> T) {
        do {
            let left = try lhs(), right = try rhs()
            if left == right {
                passed += 1
                print("  ok    \(name)")
            } else {
                failed += 1
                print("  \u{001B}[31mFAIL\u{001B}[0m  \(name)\n          got      \(left)\n          expected \(right)")
            }
        } catch {
            failed += 1
            print("  \u{001B}[31mFAIL\u{001B}[0m  \(name) — threw \(error)")
        }
    }

    static func throwsError(_ name: String, _ body: () throws -> Any) {
        do {
            _ = try body()
            failed += 1
            print("  \u{001B}[31mFAIL\u{001B}[0m  \(name) — should have thrown")
        } catch {
            passed += 1
            print("  ok    \(name)")
        }
    }

    static func summary() -> Int32 {
        print("\n\(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}

import Foundation

/// How many generated cases each property test runs: `gate` cases in `swift test`, or
/// `EXCERPT_PROPERTY_RUNS` when set, as `just properties` sets it.
public func propertyRuns(gate: Int) -> Int {
    ProcessInfo.processInfo.environment["EXCERPT_PROPERTY_RUNS"].flatMap(Int.init) ?? gate
}

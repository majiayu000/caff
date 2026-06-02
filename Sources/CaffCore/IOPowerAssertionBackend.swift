import Foundation
import IOKit.pwr_mgt

/// Abstraction over the IOKit power-assertion C API.
///
/// The default production backend (`SystemIOPowerAssertionBackend`) wraps
/// the real IOKit symbols. Tests use `FakeIOPowerAssertionBackend` to
/// drive failure paths without depending on macOS power-assertion state.
///
/// This is a thin seam by design: it covers only the two C entry points
/// `PowerAssertionController` actually calls. If we ever need more, add
/// them here rather than reaching into IOKit from a test.
public protocol IOPowerAssertionBackend: Sendable {
    func createAssertion(
        type: CFString,
        level: IOPMAssertionLevel,
        reason: CFString
    ) -> (status: IOReturn, id: IOPMAssertionID)

    func releaseAssertion(_ id: IOPMAssertionID) -> IOReturn
}

/// Production backend. Calls the real IOKit API.
public struct SystemIOPowerAssertionBackend: IOPowerAssertionBackend {
    public init() {}

    public func createAssertion(
        type: CFString,
        level: IOPMAssertionLevel,
        reason: CFString
    ) -> (status: IOReturn, id: IOPMAssertionID) {
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(type, level, reason, &assertionID)
        return (result, assertionID)
    }

    public func releaseAssertion(_ id: IOPMAssertionID) -> IOReturn {
        IOPMAssertionRelease(id)
    }
}

import Testing
@testable import SpikDoum
@Test func missingOutputDoesNotChangeSystemRouting() throws {
    let before = try AudioOutputDevices.current()
    #expect(throws: (any Error).self) { try AudioOutputDevices.setDefault(uid: "spikdoum-invalid-output-test") }
    #expect(try AudioOutputDevices.current() == before)
}

import Testing
@testable import SpikDoum
@Test func meetingTargetsExcludeOtherAppsAndRecognizeHelpers() {
    #expect(MeetingAudioTarget.zoom.matches(bundleID: "us.zoom.xos"))
    #expect(MeetingAudioTarget.zoom.matches(bundleID: "us.zoom.xos.helper"))
    #expect(!MeetingAudioTarget.zoom.matches(bundleID: "com.google.Chrome"))
    #expect(MeetingAudioTarget.chrome.matches(bundleID: "com.google.Chrome.helper"))
    #expect(!MeetingAudioTarget.chrome.matches(bundleID: "com.google.Chromecast"))
    #expect(MeetingAudioTarget.safari.matches(bundleID: "com.apple.Safari"))
    #expect(MeetingAudioTarget.all.matches(bundleID: "any.application"))
}

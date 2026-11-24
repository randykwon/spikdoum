import Testing
@testable import SpikDoum
@Test func youtubeDoesNotNeedMicrophoneAndKeepsCoachingManual() {
    let plan = CapturePreset.youtube.plan()
    #expect(plan.systemOnly && plan.systemAudio)
    #expect(plan.target == .all)
    #expect(!plan.automaticAdvice)
}
@Test func meetingsRestoreMicrophoneAfterYouTubeAndSelectCorrectApplication() {
    let zoom = CapturePreset.zoom.plan()
    #expect(!zoom.systemOnly && zoom.systemAudio && zoom.automaticAdvice)
    #expect(zoom.target == .zoom)
    let meet = CapturePreset.googleMeet.plan(browser: .edge)
    #expect(meet.target == .edge && !meet.systemOnly && meet.systemAudio)
    #expect(CapturePreset.googleMeet.plan(browser: .zoom).target == .chrome)
}
@Test func inPersonDoesNotCaptureSystemPlayback() {
    let plan = CapturePreset.inPerson.plan()
    #expect(!plan.systemAudio && !plan.systemOnly)
}

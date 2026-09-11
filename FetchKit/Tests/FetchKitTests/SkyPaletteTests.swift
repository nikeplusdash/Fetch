import Foundation
import Testing
@testable import FetchKit

@Suite("Sky palette")
struct SkyPaletteTests {

    @Test("noon is the palette the asset catalogue is rendered with")
    func noonIsDaylight() {
        #expect(SkyPalette.at(hour: 12) == SkyPalette.day)
    }

    @Test("the day is continuous across midnight")
    func midnightDoesNotJump() {
        let before = SkyPalette.at(hour: 23.99)
        let after = SkyPalette.at(hour: 0)
        #expect(abs(before.top.red - after.top.red) < 0.01)
        #expect(abs(before.bottom.blue - after.bottom.blue) < 0.01)
    }

    @Test("every step of the day is a small one")
    func noVisibleJumps() {
        let stepsPerHour = 1200.0
        var previous = SkyPalette.at(hour: 0)
        for step in 1...Int(24 * stepsPerHour) {
            let now = SkyPalette.at(hour: Double(step) / stepsPerHour)
            let delta = abs(now.top.red - previous.top.red)
                + abs(now.top.green - previous.top.green)
                + abs(now.top.blue - previous.top.blue)
                + abs(now.bottom.red - previous.bottom.red)
                + abs(now.bottom.green - previous.bottom.green)
                + abs(now.bottom.blue - previous.bottom.blue)
            #expect(delta < 0.01, "jump of \(delta) at hour \(Double(step) / stepsPerHour)")
            previous = now
        }
    }

    @Test("the middle of the night is dark and the middle of the day is not")
    func nightIsDarkerThanDay() {
        func brightness(_ palette: SkyPalette) -> Double {
            (palette.top.red + palette.top.green + palette.top.blue
                + palette.bottom.red + palette.bottom.green + palette.bottom.blue) / 6
        }
        #expect(brightness(SkyPalette.at(hour: 2)) < 0.25)
        #expect(brightness(SkyPalette.at(hour: 13)) > 0.55)
    }

    @Test("the horizon is warmer than the zenith at sunset, and not at noon")
    func sunsetIsWarmAtTheHorizon() {
        let atSunset = SkyPalette.at(hour: SkyPalette.SolarTimes.clock.sunset)
        #expect(atSunset.bottom.red > atSunset.bottom.blue)
        #expect(atSunset.bottom.red > atSunset.top.red)

        let atNoon = SkyPalette.at(hour: 12)
        #expect(atNoon.bottom.blue > atNoon.bottom.red)
    }

    @Test("phases follow the sun, not the clock")
    func phasesShiftWithSolarTimes() {
        let winter = SkyPalette.SolarTimes(sunrise: 8.5, sunset: 16)
        let lateAfternoon = SkyPalette.at(hour: 16.5, solar: winter)
        #expect(lateAfternoon.bottom.red > lateAfternoon.bottom.blue)
        #expect(SkyPalette.at(hour: 12, solar: winter) == SkyPalette.day)
    }

    @Test("clouds are dimmer and cooler after dark")
    func cloudsFollowTheLight() {
        let night = SkyPalette.at(hour: 2)
        #expect(night.cloudOpacity < 0.8)
        #expect(night.cloud.blue > night.cloud.red)

        let dusk = SkyPalette.at(hour: SkyPalette.SolarTimes.clock.sunset)
        #expect(dusk.cloud.red > dusk.cloud.blue)
    }
}

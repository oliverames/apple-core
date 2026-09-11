import Foundation
import Testing

@Suite("Power summary")
struct PowerSummaryTests {
    @Test("A discharging battery reports its charge and its time left")
    func discharging() {
        let summary = PowerSummary.from(description: [
            "Is Present": true,
            "Current Capacity": 62,
            "Max Capacity": 100,
            "Is Charging": false,
            "Power Source State": "Battery Power",
            "Time to Empty": 214,
            "Time to Full Charge": -1,
            "BatteryHealth": "Good",
        ])
        #expect(summary.hasBattery)
        #expect(summary.source == .battery)
        #expect(summary.percentRemaining == 62)
        #expect(summary.minutesRemaining == 214)
        #expect(summary.minutesToFullCharge == nil)
        #expect(!summary.timeEstimateIsCalculating)
        #expect(summary.condition == "Good")
    }

    @Test("Raw milliamp-hour capacities become a percentage, not a four-digit number")
    func percentageFromRawCapacities() {
        let summary = PowerSummary.from(description: [
            "Is Present": true,
            "Current Capacity": 4381,
            "Max Capacity": 8694,
            "Power Source State": "AC Power",
        ])
        #expect(summary.percentRemaining == 50)
    }

    @Test("A percentage never leaves 0 to 100")
    func clampsPercentage() {
        let over = PowerSummary.from(description: [
            "Is Present": true,
            "Current Capacity": 105,
            "Max Capacity": 100,
        ])
        #expect(over.percentRemaining == 100)
    }

    @Test("A charging Mac reports time to full, and -1 means still calculating")
    func charging() {
        let summary = PowerSummary.from(description: [
            "Is Present": true,
            "Current Capacity": 20,
            "Max Capacity": 100,
            "Is Charging": true,
            "Power Source State": "AC Power",
            "Time to Empty": -1,
            "Time to Full Charge": -1,
        ])
        #expect(summary.isCharging)
        #expect(summary.source == .ac)
        #expect(summary.minutesRemaining == nil)
        #expect(summary.minutesToFullCharge == nil)
        #expect(summary.timeEstimateIsCalculating)
        #expect(summary.summaryLine().contains("still being estimated"))
    }

    @Test("A settled charge estimate is not reported as calculating")
    func settledChargeEstimate() {
        let summary = PowerSummary.from(description: [
            "Is Present": true,
            "Current Capacity": 40,
            "Max Capacity": 100,
            "Is Charging": true,
            "Power Source State": "AC Power",
            "Time to Empty": -1,
            "Time to Full Charge": 47,
        ])
        #expect(!summary.timeEstimateIsCalculating)
        #expect(summary.summaryLine() == "Charging: 40%, about 47 minutes to full.")
    }

    @Test("A Mac with no battery says so instead of reporting zero per cent")
    func noBattery() {
        let summary = PowerSummary.from(description: ["Is Present": false])
        #expect(!summary.hasBattery)
        #expect(summary.percentRemaining == nil)
        #expect(summary.source == .ac)
        #expect(summary.summaryLine().contains("no battery"))
    }

    @Test("A UPS is not mistaken for the Mac's own battery")
    func uninterruptiblePowerSupply() {
        let summary = PowerSummary.from(description: [
            "Is Present": true,
            "Type": "UPS",
            "Current Capacity": 90,
            "Max Capacity": 100,
            "Power Source State": "AC Power",
        ])
        #expect(summary.source == .ups)
    }

    @Test("Capacities arrive as several numeric types")
    func coercesNumbers() {
        let doubles = PowerSummary.from(description: [
            "Is Present": true,
            "Current Capacity": 33.0,
            "Max Capacity": NSNumber(value: 100),
        ])
        #expect(doubles.percentRemaining == 33)
    }

    @Test("On mains power, zero minutes to empty is not reported as no time left")
    func ignoresTheMainsEstimate() {
        // Exactly what a plugged-in, fully charged MacBook reports.
        let summary = PowerSummary.from(description: [
            "Is Present": true,
            "Current Capacity": 100,
            "Max Capacity": 100,
            "Is Charging": false,
            "Is Charged": true,
            "Power Source State": "AC Power",
            "Time to Empty": 0,
            "Time to Full Charge": 0,
            "Type": "InternalBattery",
        ])
        #expect(summary.minutesRemaining == nil)
        #expect(summary.minutesToFullCharge == nil)
        #expect(!summary.timeEstimateIsCalculating)
        #expect(summary.summaryLine() == "Fully charged at 100%, on mains power.")
    }

    @Test("A full battery reads as charged")
    func fullyCharged() {
        let summary = PowerSummary.from(description: [
            "Is Present": true,
            "Current Capacity": 100,
            "Max Capacity": 100,
            "Is Charged": true,
            "Power Source State": "AC Power",
        ])
        #expect(summary.isFullyCharged)
        #expect(summary.summaryLine() == "Fully charged at 100%, on mains power.")
    }
}

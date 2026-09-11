import Foundation
import Testing

@Suite("Storage and resource totals")
struct SystemResourceSummaryTests {
    private func volume(total: Int64, available: Int64) -> StorageVolumeSummary {
        StorageVolumeSummary(
            name: "Macintosh HD",
            path: "/",
            totalBytes: total,
            availableBytes: available,
            availableForImportantUsageBytes: nil
        )
    }

    @Test("Used space and percentage come from the totals")
    func usage() {
        let disk = volume(total: 1_000_000, available: 250_000)
        #expect(disk.usedBytes == 750_000)
        #expect(disk.percentUsed == 75)
    }

    @Test("A volume that reports no size has no percentage rather than a divide by zero")
    func zeroSizedVolume() {
        #expect(volume(total: 0, available: 0).percentUsed == nil)
    }

    @Test("A volume reporting more free than total never reports negative use")
    func inconsistentVolume() {
        #expect(volume(total: 100, available: 500).usedBytes == 0)
    }

    @Test("Bytes are described in the decimal units Finder uses")
    func byteFormatting() {
        #expect(SystemResourceFormatting.describeBytes(512) == "512 bytes")
        #expect(SystemResourceFormatting.describeBytes(1_500) == "1.5KB")
        #expect(SystemResourceFormatting.describeBytes(2_000_000_000) == "2.0GB")
        #expect(SystemResourceFormatting.describeBytes(-5) == "0 bytes")
    }

    @Test("Uptime is described in the largest units that matter")
    func uptimeFormatting() {
        #expect(SystemResourceFormatting.describeUptime(seconds: 90) == "1m")
        #expect(SystemResourceFormatting.describeUptime(seconds: 3_700) == "1h 1m")
        #expect(SystemResourceFormatting.describeUptime(seconds: 200_000) == "2d 7h")
        #expect(SystemResourceFormatting.describeUptime(seconds: -1) == "0m")
    }

    @Test("Thermal state is words rather than a raw enum value")
    func thermalFormatting() {
        #expect(SystemResourceFormatting.describeThermalState(0) == "nominal")
        #expect(SystemResourceFormatting.describeThermalState(3) == "critical")
        #expect(SystemResourceFormatting.describeThermalState(99) == "unknown")
    }

    @Test("The boot volume is the one a client is pointed at first")
    func bootVolume() {
        let external = StorageVolumeSummary(
            name: "Backup",
            path: "/Volumes/Backup",
            totalBytes: 1,
            availableBytes: 1,
            availableForImportantUsageBytes: nil
        )
        let summary = SystemResourceSummary(
            volumes: [external, volume(total: 10, available: 5)],
            physicalMemoryBytes: 16_000_000_000,
            processorCount: 10,
            uptimeSeconds: 100,
            thermalState: "nominal",
            lowPowerModeEnabled: false
        )
        #expect(summary.bootVolume?.path == "/")
    }
}

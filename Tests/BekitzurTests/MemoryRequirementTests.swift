import BekitzurModels
import Testing

struct MemoryRequirementTests {
    @Test(arguments: [8, 16, 18])
    func tooLittleToWriteNotes(gigabytes: Int) {
        #expect(MemoryRequirement(bytes: UInt64(gigabytes) << 30) == .tooLow(gigabytes: gigabytes))
    }

    @Test func lessThanItsMadeFor() {
        #expect(MemoryRequirement(bytes: 24 << 30) == .low(gigabytes: 24))
    }

    @Test(arguments: [32, 36, 48, 64, 128])
    func enough(gigabytes: Int) {
        #expect(MemoryRequirement(bytes: UInt64(gigabytes) << 30) == .enough)
    }
}

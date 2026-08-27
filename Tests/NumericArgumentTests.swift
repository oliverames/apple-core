import Testing

@Suite("Numeric MCP arguments")
struct NumericArgumentTests {
    @Test("Extreme floating-point values clamp before integer conversion")
    func extremeDoublesClampSafely() {
        #expect(NumericArgument.clampedInt(1e300, to: 1 ... 10) == 10)
        #expect(NumericArgument.clampedInt(-1e300, to: 1 ... 10) == 1)
        #expect(NumericArgument.clampedInt(4.9, to: 1 ... 10) == 4)
        #expect(NumericArgument.clampedInt(.infinity, to: 1 ... 10) == nil)
        #expect(NumericArgument.clampedInt(.nan, to: 1 ... 10) == nil)
    }

    @Test("Finite durations clamp and non-finite durations fail")
    func boundedDoubleValidation() {
        #expect(NumericArgument.clampedDouble(-5, to: 1 ... 300) == 1)
        #expect(NumericArgument.clampedDouble(500, to: 1 ... 300) == 300)
        #expect(NumericArgument.clampedDouble(.infinity, to: 1 ... 300) == nil)
    }

    @Test("Coordinates must be finite and inside geographic bounds")
    func coordinateValidation() {
        #expect(NumericArgument.validatedDouble(90, in: -90 ... 90) == 90)
        #expect(NumericArgument.validatedDouble(91, in: -90 ... 90) == nil)
        #expect(NumericArgument.validatedDouble(-181, in: -180 ... 180) == nil)
        #expect(NumericArgument.validatedDouble(1e300, in: -180 ... 180) == nil)
    }

    @Test("Capture identifiers reject values outside UInt32")
    func captureIdentifierBounds() {
        #expect(NumericArgument.uint32(-1) == nil)
        #expect(NumericArgument.uint32(4_294_967_296) == nil)
        #expect(NumericArgument.uint32(4_294_967_295) == UInt32.max)
    }
}

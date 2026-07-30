import AppCore
import Foundation
import Testing
@testable import Switchyard

@Test func processLogAccumulatorPreservesNormalLinesAndCRLF() {
    let accumulator = LogStreamAccumulator(
        maximumPartialLineByteCount: 1_024,
        counters: PerformanceCounters()
    )

    #expect(
        accumulator.consume(
            Data("first\r\nsecond\n\npar".utf8),
            finish: false
        ) == ["first", "second"]
    )
    #expect(accumulator.retainedPartialByteCount == 3)
    #expect(
        accumulator.consume(
            Data("tial\r\n".utf8),
            finish: false
        ) == ["partial"]
    )
    #expect(
        accumulator.consume(
            Data("tail".utf8),
            finish: true
        ) == ["tail"]
    )
    #expect(accumulator.consume(Data("ignored\n".utf8), finish: false).isEmpty)
}

@Test func processLogAccumulatorBoundsAHugeUnterminatedChunkAndRecovers() {
    let maximumByteCount = 16
    let counters = PerformanceCounters()
    let accumulator = LogStreamAccumulator(
        maximumPartialLineByteCount: maximumByteCount,
        counters: counters
    )
    var input = Data(repeating: 0x78, count: 1_000_000)
    input.append(contentsOf: Data("\nrecovered\r\n".utf8))

    let lines = accumulator.consume(input, finish: false)

    #expect(
        lines == [
            String(repeating: "x", count: maximumByteCount)
                + LogStreamAccumulator.truncationMarker(
                    maximumPartialLineByteCount: maximumByteCount
                ),
            "recovered",
        ]
    )
    #expect(accumulator.retainedPartialByteCount == 0)
    #expect(!accumulator.isDiscardingPartialLine)
    #expect(counters.snapshot()[.partialLogTruncations] == 1)
    #expect(counters.snapshot()[.partialLogDiscardedBytes] == 999_984)
}

@Test func processLogAccumulatorDoesNotRegrowFromSplitOversizedChunks() {
    let maximumByteCount = 8
    let counters = PerformanceCounters()
    let accumulator = LogStreamAccumulator(
        maximumPartialLineByteCount: maximumByteCount,
        counters: counters
    )

    #expect(accumulator.consume(Data("abc".utf8), finish: false).isEmpty)
    #expect(accumulator.retainedPartialByteCount == 3)
    #expect(accumulator.consume(Data("defgh".utf8), finish: false).isEmpty)
    #expect(accumulator.retainedPartialByteCount == maximumByteCount)

    #expect(
        accumulator.consume(Data("ijk".utf8), finish: false) == [
            "abcdefgh"
                + LogStreamAccumulator.truncationMarker(
                    maximumPartialLineByteCount: maximumByteCount
                ),
        ]
    )
    #expect(accumulator.retainedPartialByteCount == 0)
    #expect(accumulator.isDiscardingPartialLine)
    #expect(
        accumulator.consume(
            Data("misleading-suffix".utf8),
            finish: false
        ).isEmpty
    )
    #expect(accumulator.retainedPartialByteCount == 0)

    #expect(
        accumulator.consume(
            Data("\r\nnormal\r\n".utf8),
            finish: false
        ) == ["normal"]
    )
    #expect(!accumulator.isDiscardingPartialLine)
    #expect(counters.snapshot()[.partialLogTruncations] == 1)
    #expect(
        counters.snapshot()[.partialLogDiscardedBytes]
            == UInt64("ijkmisleading-suffix\r".utf8.count)
    )
}

@Test func processLogAccumulatorDoesNotEmitDiscardedSuffixOnFinish() {
    let maximumByteCount = 8
    let accumulator = LogStreamAccumulator(
        maximumPartialLineByteCount: maximumByteCount,
        counters: PerformanceCounters()
    )

    #expect(
        accumulator.consume(Data("123456789".utf8), finish: false) == [
            "12345678"
                + LogStreamAccumulator.truncationMarker(
                    maximumPartialLineByteCount: maximumByteCount
                ),
        ]
    )
    #expect(accumulator.isDiscardingPartialLine)
    #expect(
        accumulator.consume(
            Data("must-not-be-emitted".utf8),
            finish: true
        ).isEmpty
    )
    #expect(accumulator.retainedPartialByteCount == 0)
    #expect(!accumulator.isDiscardingPartialLine)
}

@Test func processLogAccumulatorUsesAByteCapForUnicode() {
    let maximumByteCount = 4
    let accumulator = LogStreamAccumulator(
        maximumPartialLineByteCount: maximumByteCount,
        counters: PerformanceCounters()
    )

    #expect(accumulator.consume(Data("éé".utf8), finish: false).isEmpty)
    #expect(accumulator.retainedPartialByteCount == maximumByteCount)
    #expect(
        accumulator.consume(Data("x".utf8), finish: false) == [
            "éé"
                + LogStreamAccumulator.truncationMarker(
                    maximumPartialLineByteCount: maximumByteCount
                ),
        ]
    )
    #expect(accumulator.retainedPartialByteCount == 0)
}

@Test func processLogAccumulatorDoesNotCountCRLFDelimitersAgainstTheCap() {
    let maximumByteCount = 8
    let counters = PerformanceCounters()
    let accumulator = LogStreamAccumulator(
        maximumPartialLineByteCount: maximumByteCount,
        counters: counters
    )

    #expect(
        accumulator.consume(
            Data("abcdefgh\r\n".utf8),
            finish: false
        ) == ["abcdefgh"]
    )
    #expect(
        accumulator.consume(
            Data("ijklmnop\r".utf8),
            finish: false
        ).isEmpty
    )
    #expect(accumulator.retainedPartialByteCount == maximumByteCount)
    #expect(
        accumulator.consume(
            Data("\n".utf8),
            finish: false
        ) == ["ijklmnop"]
    )
    #expect(counters.snapshot()[.partialLogTruncations] == 0)
    #expect(counters.snapshot()[.partialLogDiscardedBytes] == 0)
}

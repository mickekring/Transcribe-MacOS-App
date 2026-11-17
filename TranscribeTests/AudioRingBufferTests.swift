import Foundation
import Testing
@testable import Transcribe

// MARK: - Helpers

/// Frames numbered from `first`, laid out the way the ring buffer takes
/// them: one run per channel, back to back. Channel `c` holds `c * 1000 + n`
/// for frame `n`, so every sample says which channel and frame it is.
private func planes(first: Int, count: Int, channels: Int) -> [Float] {
    (0..<channels).flatMap { channel in
        (0..<count).map { Float(channel * 1000 + first + $0) }
    }
}

private extension AudioRingBuffer {
    func write(first: Int, count: Int, channels: Int = 1) {
        let data = planes(first: first, count: count, channels: channels)
        data.withUnsafeBufferPointer {
            write(from: $0.baseAddress!, frameCount: count, channelCount: channels)
        }
    }

    /// Asks for `count` frames; returns how many came back and channel 0 of them.
    func read(_ count: Int, channels: Int = 1) -> (frames: Int, samples: [Float]) {
        let all = readAllChannels(count, channels: channels)
        return (all.frames, all.channels.first ?? [])
    }

    func readAllChannels(_ count: Int, channels: Int) -> (frames: Int, channels: [[Float]]) {
        var data = [Float](repeating: -1, count: count * channels)
        let frames = data.withUnsafeMutableBufferPointer {
            read(into: $0.baseAddress!, frameCount: count, channelCount: channels)
        }
        // Each channel starts at a multiple of the requested count
        let perChannel = (0..<channels).map { Array(data[($0 * count)..<($0 * count + frames)]) }
        return (frames, perChannel)
    }
}

private func frames(_ range: Range<Int>) -> [Float] {
    range.map(Float.init)
}

// MARK: - Storage

struct AudioRingBufferTests {

    @Test func readsBackWhatWasWrittenInOrder() {
        let ring = AudioRingBuffer(capacity: 8, channelCount: 1)
        ring.write(first: 0, count: 5)
        #expect(ring.availableFrames == 5)

        let first = ring.read(3)
        #expect(first.frames == 3)
        #expect(first.samples == frames(0..<3))

        let rest = ring.read(2)
        #expect(rest.samples == frames(3..<5))
        #expect(ring.availableFrames == 0)
    }

    @Test func wrapsAroundTheEndOfItsStorage() {
        let ring = AudioRingBuffer(capacity: 8, channelCount: 1)
        ring.write(first: 0, count: 6)
        #expect(ring.read(6).frames == 6)

        // Positions are now at 6 of 8: the next block straddles the end
        ring.write(first: 6, count: 5)
        #expect(ring.availableFrames == 5)
        let wrapped = ring.read(5)
        #expect(wrapped.frames == 5)
        #expect(wrapped.samples == frames(6..<11))

        // And keeps doing so, block after block
        var next = 11
        for _ in 0..<20 {
            ring.write(first: next, count: 3)
            #expect(ring.read(3).samples == frames(next..<(next + 3)))
            next += 3
        }
    }

    @Test func keepsChannelsApart() {
        let ring = AudioRingBuffer(capacity: 8, channelCount: 2)
        ring.write(first: 0, count: 6, channels: 2)
        _ = ring.readAllChannels(5, channels: 2)

        // Wraps in both channels
        ring.write(first: 6, count: 6, channels: 2)
        let read = ring.readAllChannels(7, channels: 2)
        #expect(read.frames == 7)
        #expect(read.channels[0] == frames(5..<12))
        #expect(read.channels[1] == frames(1005..<1012))
    }

    @Test func rejectsAMismatchedChannelCount() {
        let ring = AudioRingBuffer(capacity: 8, channelCount: 2)
        ring.write(first: 0, count: 4, channels: 1)
        #expect(ring.availableFrames == 0)

        ring.write(first: 0, count: 4, channels: 2)
        #expect(ring.read(4, channels: 1).frames == 0)
        #expect(ring.availableFrames == 4)
    }

    // MARK: Overrun and underrun

    @Test func overrunDropsTheOldestFrames() {
        let ring = AudioRingBuffer(capacity: 8, channelCount: 1)
        ring.write(first: 0, count: 6)
        ring.write(first: 6, count: 6)

        // 12 written into 8: frames 0…3 are gone
        #expect(ring.availableFrames == 8)
        let read = ring.read(8)
        #expect(read.frames == 8)
        #expect(read.samples == frames(4..<12))
    }

    @Test func aWriteLargerThanTheBufferKeepsItsNewestFrames() {
        let ring = AudioRingBuffer(capacity: 8, channelCount: 2)
        ring.write(first: 0, count: 3, channels: 2)
        ring.write(first: 3, count: 20, channels: 2)

        #expect(ring.availableFrames == 8)
        let read = ring.readAllChannels(8, channels: 2)
        #expect(read.channels[0] == frames(15..<23))
        #expect(read.channels[1] == frames(1015..<1023))
    }

    @Test func underrunReturnsAShortCount() {
        let ring = AudioRingBuffer(capacity: 8, channelCount: 1)
        #expect(ring.read(4).frames == 0)

        ring.write(first: 0, count: 3)
        let short = ring.read(5)
        #expect(short.frames == 3)
        #expect(short.samples == frames(0..<3))
        #expect(ring.read(5).frames == 0)

        // Without a cushion the next frames are available straight away
        ring.write(first: 3, count: 1)
        #expect(ring.read(5).samples == frames(3..<4))
    }

    @Test func resetDiscardsEverything() {
        let ring = AudioRingBuffer(capacity: 8, channelCount: 1)
        ring.write(first: 0, count: 6)
        ring.reset()
        #expect(ring.availableFrames == 0)
        #expect(ring.read(4).frames == 0)

        ring.write(first: 100, count: 8)
        #expect(ring.read(8).samples == frames(100..<108))
    }

    // MARK: Cushion

    @Test func holdsBackUntilAWriteFindsTheCushionUnread() {
        let ring = AudioRingBuffer(capacity: 64, channelCount: 1, cushionFrames: 4)

        // The first block arrives into an empty buffer: no cushion yet
        ring.write(first: 0, count: 4)
        #expect(ring.read(2).frames == 0)
        #expect(ring.availableFrames == 4)

        // The second finds 4 unread, so from here the reader runs a full
        // block behind the writer
        ring.write(first: 4, count: 4)
        let read = ring.read(2)
        #expect(read.frames == 2)
        #expect(read.samples == frames(0..<2))
        #expect(ring.read(6).samples == frames(2..<8))
    }

    @Test func staysHeldBackWhileLessThanTheCushionIsUnread() {
        let ring = AudioRingBuffer(capacity: 64, channelCount: 1, cushionFrames: 4)
        ring.write(first: 0, count: 3)
        ring.write(first: 3, count: 3)   // finds 3 unread: one short
        #expect(ring.read(2).frames == 0)

        ring.write(first: 6, count: 1)   // finds 6
        #expect(ring.read(7).samples == frames(0..<7))
    }

    @Test func rebuildsTheCushionAfterRunningDry() {
        let ring = AudioRingBuffer(capacity: 64, channelCount: 1, cushionFrames: 4)
        ring.write(first: 0, count: 4)
        ring.write(first: 4, count: 4)

        // Asking for more than there is hands out the rest, then holds back
        let short = ring.read(10)
        #expect(short.frames == 8)
        #expect(short.samples == frames(0..<8))

        ring.write(first: 8, count: 4)   // finds nothing unread
        #expect(ring.read(2).frames == 0)
        ring.write(first: 12, count: 4)  // finds 4
        #expect(ring.read(8).samples == frames(8..<16))
    }

    @Test func aReadThatExactlyEmptiesTheBufferIsNotAnUnderrun() {
        let ring = AudioRingBuffer(capacity: 64, channelCount: 1, cushionFrames: 4)
        ring.write(first: 0, count: 4)
        ring.write(first: 4, count: 4)
        #expect(ring.read(8).frames == 8)

        // Nothing was missing from that read, so the reader is not held back
        ring.write(first: 8, count: 4)
        #expect(ring.read(4).samples == frames(8..<12))
    }

    @Test func resetAsksForTheCushionAgain() {
        let ring = AudioRingBuffer(capacity: 64, channelCount: 1, cushionFrames: 4)
        ring.write(first: 0, count: 4)
        ring.write(first: 4, count: 4)
        #expect(ring.read(2).frames == 2)

        ring.reset()
        ring.write(first: 100, count: 4)
        #expect(ring.read(2).frames == 0)
        ring.write(first: 104, count: 4)
        #expect(ring.read(8).samples == frames(100..<108))
    }

    // MARK: Backlog limit

    @Test func trimsBackToTheCushionWhenTheBacklogGrowsTooLarge() {
        let ring = AudioRingBuffer(capacity: 64, channelCount: 1, cushionFrames: 4, maxBacklogFrames: 8)
        ring.write(first: 0, count: 6)
        ring.write(first: 6, count: 6)   // finds 6 unread: within the limit
        #expect(ring.availableFrames == 12)

        // Finds 12 unread, more than 8: all but the newest 4 are dropped
        // before the new block is added
        ring.write(first: 12, count: 2)
        #expect(ring.availableFrames == 6)
        let read = ring.read(6)
        #expect(read.frames == 6)
        #expect(read.samples == frames(8..<14))
    }

    @Test func aBacklogAtTheLimitIsLeftAlone() {
        let ring = AudioRingBuffer(capacity: 64, channelCount: 1, cushionFrames: 4, maxBacklogFrames: 8)
        ring.write(first: 0, count: 8)
        ring.write(first: 8, count: 4)   // finds exactly 8
        #expect(ring.availableFrames == 12)
        #expect(ring.read(12).samples == frames(0..<12))
    }

    @Test func aReaderThatKeepsUpIsNeverTrimmed() {
        // A writer delivering 4 frames at a time and a reader taking them in
        // twos, as the microphone tap and the stream callback do
        let ring = AudioRingBuffer(capacity: 64, channelCount: 1, cushionFrames: 4, maxBacklogFrames: 12)
        var written = 0
        var expected = 0
        for block in 0..<200 {
            ring.write(first: written, count: 4)
            written += 4
            guard block > 0 else { continue }   // the cushion forms on the second block
            for _ in 0..<2 {
                let read = ring.read(2)
                #expect(read.samples == frames(expected..<(expected + 2)))
                expected += 2
            }
        }
        // The reader ends one block behind: the cushion
        #expect(ring.availableFrames == 4)
    }

    @Test func aWriterThatRunsFastIsTrimmedInsteadOfFallingBehind() {
        // 5 frames in for every 4 out: the backlog creeps up, is cut back to
        // the cushion, and never reaches the capacity
        let ring = AudioRingBuffer(capacity: 64, channelCount: 1, cushionFrames: 4, maxBacklogFrames: 12)
        var written = 0
        var largestBacklog = 0
        var lastSample: Float = -1
        for _ in 0..<400 {
            ring.write(first: written, count: 5)
            written += 5
            largestBacklog = max(largestBacklog, ring.availableFrames)
            let read = ring.read(4)
            // Skips forward when trimmed, but never goes back or repeats
            if let first = read.samples.first {
                #expect(first > lastSample)
            }
            lastSample = read.samples.last ?? lastSample
        }
        #expect(largestBacklog <= 12 + 5)
        #expect(Int(lastSample) >= written - (12 + 5))
    }

    @Test func withoutALimitOnlyTheCapacityBoundsTheBacklog() {
        let ring = AudioRingBuffer(capacity: 16, channelCount: 1, cushionFrames: 4)
        for block in 0..<3 {
            ring.write(first: block * 5, count: 5)
        }
        #expect(ring.availableFrames == 15)
        #expect(ring.read(15).samples == frames(0..<15))
    }
}

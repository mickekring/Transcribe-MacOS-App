import Foundation
import os

/// Thread-safe ring buffer for non-interleaved Float audio samples.
///
/// Designed for SPSC (single-producer, single-consumer) use between
/// the AVAudioEngine mic tap (writer) and the SCStream callback (reader).
/// Uses an unfair lock for short critical sections (memcpy ~4KB per call).
///
/// Storage layout mirrors SCStream's non-interleaved format:
/// `[L0 L1 L2 ... LN] [R0 R1 R2 ... RN]` — each channel stored contiguously.
///
/// The reader can be kept a set distance behind the writer with
/// `cushionFrames` and `maxBacklogFrames`. Both are measured when a write
/// arrives, on what is still unread at that moment — the low point of the
/// backlog — so they mean the same whatever block sizes the two sides use.
final class AudioRingBuffer: @unchecked Sendable {
    private let capacity: Int      // frames per channel
    private let channelCount: Int
    private let cushionFrames: Int
    private let maxBacklogFrames: Int
    private var buffer: [Float]    // channelCount * capacity floats
    private var writePosition: Int = 0
    private var readPosition: Int = 0
    private var availableFramesCount: Int = 0
    /// False while `read` is held back until the cushion has formed.
    private var isPrimed: Bool
    // Allocated on the heap: an `os_unfair_lock` stored in a Swift property
    // and passed with `&` has no stable address, which the lock requires.
    private let lock = OSAllocatedUnfairLock()
    
    /// Creates a ring buffer with the given capacity per channel.
    /// - Parameters:
    ///   - capacity: Number of frames per channel (e.g. 96000 for 2 seconds at 48kHz)
    ///   - channelCount: Number of audio channels (typically 2 for stereo)
    ///   - cushionFrames: `read` returns nothing until a write finds at least
    ///     this many frames still unread — at the start, after `reset()`, and
    ///     again after a read that ran the buffer dry. A reader that drains
    ///     the buffer as fast as it fills would otherwise come up short every
    ///     time the writer is a moment late. 0 (the default) reads whatever
    ///     is there.
    ///   - maxBacklogFrames: When a write finds more than this many frames
    ///     still unread, the oldest are dropped so that `cushionFrames`
    ///     remain. This keeps a writer whose clock runs slightly fast from
    ///     leaving the reader ever further behind. `nil` (the default) only
    ///     limits the backlog to `capacity`.
    init(capacity: Int, channelCount: Int, cushionFrames: Int = 0, maxBacklogFrames: Int? = nil) {
        let cushion = max(0, min(cushionFrames, capacity))
        self.capacity = capacity
        self.channelCount = channelCount
        self.cushionFrames = cushion
        self.maxBacklogFrames = max(cushion, min(maxBacklogFrames ?? capacity, capacity))
        self.buffer = [Float](repeating: 0, count: capacity * channelCount)
        self.isPrimed = cushion == 0
    }
    
    /// Number of frames buffered, including any still held back as cushion.
    var availableFrames: Int {
        lock.lock()
        let count = availableFramesCount
        lock.unlock()
        return count
    }
    
    /// Writes non-interleaved audio frames into the buffer.
    ///
    /// Data layout: `channelCount` contiguous blocks of `frameCount` floats each.
    /// e.g. for stereo: `[L0..LN][R0..RN]`
    ///
    /// If the buffer is full, oldest frames are overwritten (lossy).
    func write(from data: UnsafePointer<Float>, frameCount: Int, channelCount sourceChannels: Int) {
        guard frameCount > 0, sourceChannels == channelCount else { return }
        
        lock.lock()

        // What is unread now, before the new frames are added, is how far
        // the reader really is behind.
        if availableFramesCount > maxBacklogFrames {
            let dropped = availableFramesCount - cushionFrames
            readPosition = (readPosition + dropped) % capacity
            availableFramesCount = cushionFrames
        }
        if !isPrimed, availableFramesCount >= cushionFrames {
            isPrimed = true
        }

        // If a single write exceeds capacity, only the newest `capacity` frames
        // can survive — skip the older source frames entirely.
        let framesToWrite = min(frameCount, capacity)
        let sourceFrameOffset = frameCount - framesToWrite

        for ch in 0..<channelCount {
            let sourceOffset = ch * frameCount + sourceFrameOffset
            let destChannelOffset = ch * capacity
            
            let sourcePtr = data.advanced(by: sourceOffset)
            
            // How many frames fit before wrapping?
            let firstChunk = min(framesToWrite, capacity - writePosition)
            let secondChunk = framesToWrite - firstChunk
            
            buffer.withUnsafeMutableBufferPointer { bufPtr in
                // First chunk: writePosition to end (or frameCount, whichever is smaller)
                memcpy(
                    bufPtr.baseAddress!.advanced(by: destChannelOffset + writePosition),
                    sourcePtr,
                    firstChunk * MemoryLayout<Float>.size
                )
                // Second chunk: wrap around to beginning
                if secondChunk > 0 {
                    memcpy(
                        bufPtr.baseAddress!.advanced(by: destChannelOffset),
                        sourcePtr.advanced(by: firstChunk),
                        secondChunk * MemoryLayout<Float>.size
                    )
                }
            }
        }
        
        writePosition = (writePosition + framesToWrite) % capacity

        // If this write overwrote unread frames, advance the read position past
        // them so it always points at the oldest valid frame.
        let overwritten = availableFramesCount + framesToWrite - capacity
        if overwritten > 0 {
            readPosition = (readPosition + overwritten) % capacity
        }
        availableFramesCount = min(availableFramesCount + framesToWrite, capacity)

        lock.unlock()
    }
    
    /// Reads non-interleaved audio frames from the buffer.
    ///
    /// Output layout: `channelCount` contiguous blocks of `frameCount` floats
    /// each, of which the first returned-count frames are filled.
    ///
    /// - Returns: Number of frames actually read: fewer than requested if the
    ///   buffer holds fewer, and 0 while a cushion is still forming.
    @discardableResult
    func read(into data: UnsafeMutablePointer<Float>, frameCount: Int, channelCount destChannels: Int) -> Int {
        guard frameCount > 0, destChannels == channelCount else { return 0 }
        
        lock.lock()
        
        guard isPrimed else {
            lock.unlock()
            return 0
        }
        
        let framesToRead = min(frameCount, availableFramesCount)
        if framesToRead < frameCount, cushionFrames > 0 {
            // Ran dry: hold back until the cushion has formed again, so this
            // is one gap rather than a short read on every call.
            isPrimed = false
        }
        
        guard framesToRead > 0 else {
            lock.unlock()
            return 0
        }
        
        for ch in 0..<channelCount {
            let destOffset = ch * frameCount
            let srcChannelOffset = ch * capacity
            
            let destPtr = data.advanced(by: destOffset)
            
            let firstChunk = min(framesToRead, capacity - readPosition)
            let secondChunk = framesToRead - firstChunk
            
            buffer.withUnsafeMutableBufferPointer { bufPtr in
                memcpy(
                    destPtr,
                    bufPtr.baseAddress!.advanced(by: srcChannelOffset + readPosition),
                    firstChunk * MemoryLayout<Float>.size
                )
                if secondChunk > 0 {
                    memcpy(
                        destPtr.advanced(by: firstChunk),
                        bufPtr.baseAddress!.advanced(by: srcChannelOffset),
                        secondChunk * MemoryLayout<Float>.size
                    )
                }
            }
        }
        
        readPosition = (readPosition + framesToRead) % capacity
        availableFramesCount -= framesToRead
        
        lock.unlock()
        
        return framesToRead
    }
    
    /// Discards all buffered data and resets read/write positions. A cushion,
    /// if configured, has to form again before the next read returns frames.
    func reset() {
        lock.lock()
        writePosition = 0
        readPosition = 0
        availableFramesCount = 0
        isPrimed = cushionFrames == 0
        lock.unlock()
    }
}

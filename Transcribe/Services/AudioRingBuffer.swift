import Foundation
import os

/// Thread-safe ring buffer for non-interleaved Float audio samples.
///
/// Designed for SPSC (single-producer, single-consumer) use between
/// the AVAudioEngine mic tap (writer) and the SCStream callback (reader).
/// Uses `os_unfair_lock` for short critical sections (memcpy ~4KB per call).
///
/// Storage layout mirrors SCStream's non-interleaved format:
/// `[L0 L1 L2 ... LN] [R0 R1 R2 ... RN]` — each channel stored contiguously.
final class AudioRingBuffer: @unchecked Sendable {
    private let capacity: Int      // frames per channel
    private let channelCount: Int
    private var buffer: [Float]    // channelCount * capacity floats
    private var writePosition: Int = 0
    private var readPosition: Int = 0
    private var availableFramesCount: Int = 0
    private var lock = os_unfair_lock()
    
    /// Creates a ring buffer with the given capacity per channel.
    /// - Parameters:
    ///   - capacity: Number of frames per channel (e.g. 96000 for 2 seconds at 48kHz)
    ///   - channelCount: Number of audio channels (typically 2 for stereo)
    init(capacity: Int, channelCount: Int) {
        self.capacity = capacity
        self.channelCount = channelCount
        self.buffer = [Float](repeating: 0, count: capacity * channelCount)
    }
    
    /// Number of frames available for reading.
    var availableFrames: Int {
        os_unfair_lock_lock(&lock)
        let count = availableFramesCount
        os_unfair_lock_unlock(&lock)
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
        
        os_unfair_lock_lock(&lock)
        
        let framesToWrite = min(frameCount, capacity)
        
        for ch in 0..<channelCount {
            let sourceOffset = ch * frameCount
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
        availableFramesCount = min(availableFramesCount + framesToWrite, capacity)
        
        os_unfair_lock_unlock(&lock)
    }
    
    /// Reads non-interleaved audio frames from the buffer.
    ///
    /// Output layout: `channelCount` contiguous blocks of returned frame count each.
    ///
    /// - Returns: Number of frames actually read (may be less than requested if buffer has fewer).
    @discardableResult
    func read(into data: UnsafeMutablePointer<Float>, frameCount: Int, channelCount destChannels: Int) -> Int {
        guard frameCount > 0, destChannels == channelCount else { return 0 }
        
        os_unfair_lock_lock(&lock)
        
        let framesToRead = min(frameCount, availableFramesCount)
        
        guard framesToRead > 0 else {
            os_unfair_lock_unlock(&lock)
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
        
        os_unfair_lock_unlock(&lock)
        
        return framesToRead
    }
    
    /// Discards all buffered data and resets read/write positions.
    func reset() {
        os_unfair_lock_lock(&lock)
        writePosition = 0
        readPosition = 0
        availableFramesCount = 0
        os_unfair_lock_unlock(&lock)
    }
}

import Foundation

/// The ~100-value amplitude summary uploaded with each memo, so players draw instantly.
public enum Waveform {
    /// RMS per bucket, scaled so the loudest bucket is 1 and quiet audio still shows texture.
    public static func summarize(_ samples: [Float], buckets: Int = AppConfig.waveformBuckets) -> [Float] {
        guard buckets > 0 else { return [] }
        guard !samples.isEmpty else { return [Float](repeating: 0, count: buckets) }
        let size = max(1, samples.count / buckets)
        var values: [Float] = []
        values.reserveCapacity(buckets)
        for b in 0..<buckets {
            let start = b * samples.count / buckets
            let end = min(samples.count, max(start + size, (b + 1) * samples.count / buckets))
            guard start < end else {
                values.append(0)
                continue
            }
            var sum: Float = 0
            for s in samples[start..<end] { sum += s * s }
            values.append((sum / Float(end - start)).squareRoot())
        }
        return normalize(values)
    }

    /// Scales to 0...1 on a gentle curve, so speech doesn't look flat next to one loud laugh.
    public static func normalize(_ values: [Float]) -> [Float] {
        guard let peak = values.max(), peak > 0 else { return values.map { _ in 0 } }
        return values.map { v in
            let scaled = (v / peak).squareRoot()
            return (scaled * 1000).rounded() / 1000
        }
    }

    /// Live meter level (0...1) from an `AVAudioRecorder` average power in dBFS.
    public static func level(fromDecibels db: Float) -> Float {
        let floor: Float = -50
        guard db > floor else { return 0 }
        return min(1, pow((db - floor) / -floor, 1.6))
    }
}

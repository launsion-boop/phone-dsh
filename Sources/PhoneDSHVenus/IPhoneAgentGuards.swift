// SPDX-License-Identifier: MIT
// phone-dsh — guards that keep the UI agent from flailing (tonolink-board.md §6):
// the model is told when its last action left the screen unchanged, and a run that keeps
// repeating itself gets one nudge, then stops with an honest answer instead of using up
// every step.

import CoreGraphics
import Foundation
import ImageIO

/// How different two screenshots look, without a model: mean absolute difference (0–255)
/// of 36×52 grayscale thumbnails. A moved pointer or a blinking cursor stays well below
/// ``unchanged``; a page change, an opened menu or a launched app is far above it.
public enum IPhoneScreenDiff {
    public static let unchanged = 2.0
    static let width = 36, height = 52

    /// Nil when either image cannot be decoded.
    public static func mean(_ a: Data, _ b: Data) -> Double? {
        guard let pa = gray(a), let pb = gray(b) else { return nil }
        var sum = 0
        for i in 0..<pa.count { sum += abs(Int(pa[i]) - Int(pb[i])) }
        return Double(sum) / Double(pa.count)
    }

    static func gray(_ jpeg: Data) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}

/// Detects a run that repeats itself: the same action three times in a row, or going back
/// and forth between two actions twice (A, B, A, B). The first time it nudges the model;
/// if the run repeats itself again after that, it stops.
public struct IPhoneLoopGuard: Sendable {
    public enum Verdict: Equatable, Sendable {
        case proceed
        case nudge(String)
        case stop(String)
    }

    private var keys: [String] = []
    private var raws: [String] = []
    public private(set) var nudged = false

    public init() {}

    /// Actions that differ only by a few points on screen count as the same.
    public static func key(_ action: IPhoneAction) -> String {
        let points = action.points.map { "\(Int(($0.x / 30).rounded())),\(Int(($0.y / 30).rounded()))" }
        return ([action.name] + points + [action.text]).joined(separator: "|")
    }

    public mutating func record(_ action: IPhoneAction) -> Verdict {
        keys.append(Self.key(action)); raws.append(action.raw)
        let n = keys.count
        let repeated = n >= 3 && keys[n - 1] == keys[n - 2] && keys[n - 2] == keys[n - 3]
        let pingPong = n >= 4 && keys[n - 1] != keys[n - 2] && keys[n - 1] == keys[n - 3] && keys[n - 2] == keys[n - 4]
        guard repeated || pingPong else { return .proceed }
        let what = repeated
            ? "repeated \(raws[n - 1]) three times"
            : "gone back and forth between \(raws[n - 2]) and \(raws[n - 1]) twice"
        if nudged {
            return .stop("卡住了：反复执行同样的操作没有进展（\(repeated ? raws[n - 1] : raws[n - 2] + " ⇄ " + raws[n - 1])），已停止")
        }
        nudged = true
        keys.removeAll(); raws.removeAll()
        return .nudge("You have \(what) without finishing. Look carefully at the current screenshot: if it already shows "
            + "what the task asks for, reply Finished or Answer now with what you see. Otherwise try something different.")
    }
}

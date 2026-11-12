import Foundation

/// 键区坐标里的一个点。规则层不依赖 UIKit，平台壳把 CGPoint 转成它。
public struct KeyPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// 字母键在键区坐标里的矩形，供纠错按落点加权。
public struct KeyFrame: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
}

@inline(__always)
func letterIndex(_ letter: UInt8) -> Int? {
    guard letter >= UInt8(ascii: "a"), letter <= UInt8(ascii: "z") else { return nil }
    return Int(letter - UInt8(ascii: "a"))
}

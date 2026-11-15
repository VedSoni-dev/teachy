//
//  SceneLabelLayout.swift
//  leanring-buddy / Scene
//
//  Where the label chips of a 3D model go. Works in the flat plane facing the
//  camera (x to the right, y up), so it is plain 2D geometry:
//
//    - a wide model gets its chips in a row above it (and a second row below
//      when the first is full), each over the part it names;
//    - a tall or roughly square model gets a column of chips on each side;
//    - chips never overlap, and leader lines in one row or column never cross,
//      because chips keep the order of the parts they point at.
//
//  The old placement stacked every chip above the model's top, so close parts
//  made a tall tower of chips with leaders drawn through the model.
//
//  Pure (Foundation + simd).
//

import Foundation
import simd

enum SceneLabelLayout {
    enum Side: String, Equatable {
        case left, right, up, down

        init?(script: String?) {
            switch script?.lowercased() {
            case "left": self = .left
            case "right": self = .right
            case "up", "above", "top": self = .up
            case "down", "below", "bottom": self = .down
            default: return nil
            }
        }
    }

    struct Item: Equatable {
        var id: String
        /// The middle of the part, in the camera plane.
        var anchor: SceneVec2
        /// Chip width and height, in the same units.
        var size: SceneVec2
        /// A side the script asked for.
        var side: Side?
    }

    struct Placement: Equatable {
        var center: SceneVec2
        var side: Side
    }

    /// `low`/`high` is the model's box in the camera plane. `gap` is the clear space between chips.
    static func place(_ items: [Item], low: SceneVec2, high: SceneVec2, gap: Double, margin: Double, rows: Bool? = nil) -> [String: Placement] {
        guard !items.isEmpty else { return [:] }
        let width = max(high.x - low.x, 1e-6), height = max(high.y - low.y, 1e-6)
        let center = (low + high) / 2
        let chipHeight = items.map(\.size.y).max() ?? 0
        let totalWidth = items.map(\.size.x).reduce(0, +) + gap * Double(items.count - 1)

        // Sides: what the script asked for, else rows for a wide model and columns for a tall one.
        var sides: [String: Side] = [:]
        let free = items.filter { $0.side == nil }
        for item in items { if let side = item.side { sides[item.id] = side } }
        let useRows = rows ?? prefersRows(low: low, high: high)
        if useRows {
            // One row above while it fits in about twice the model's width; then the lower parts go below.
            let roomy = max(width * 1.2, (items.map(\.size.x).max() ?? 0) * 1.5)
            if totalWidth <= roomy {
                for item in free { sides[item.id] = .up }
            } else {
                let byHeight = free.sorted { $0.anchor.y > $1.anchor.y || ($0.anchor.y == $1.anchor.y && $0.id < $1.id) }
                var used = 0.0
                for item in byHeight {
                    sides[item.id] = used + item.size.x <= roomy ? .up : .down
                    used += item.size.x + gap
                }
            }
        } else {
            let ordered = free.sorted { $0.anchor.x < $1.anchor.x || ($0.anchor.x == $1.anchor.x && $0.id < $1.id) }
            // Parts left of the middle go left; a lopsided split is evened out so neither column towers.
            var left = ordered.filter { $0.anchor.x < center.x - width * 0.02 }
            var right = ordered.filter { $0.anchor.x >= center.x - width * 0.02 }
            while left.count > right.count + 1, let moved = left.popLast() { right.insert(moved, at: 0) }
            while right.count > left.count + 1, !right.isEmpty { left.append(right.removeFirst()) }
            for item in left { sides[item.id] = .left }
            for item in right { sides[item.id] = .right }
        }

        var result: [String: Placement] = [:]

        for side in [Side.up, .down] {
            let group = items.filter { sides[$0.id] == side }.sorted { $0.anchor.x < $1.anchor.x || ($0.anchor.x == $1.anchor.x && $0.id < $1.id) }
            guard !group.isEmpty else { continue }
            let xs = spread(wanted: group.map(\.anchor.x), sizes: group.map(\.size.x), gap: gap)
            let direction: Double = side == .up ? 1 : -1
            let edge = side == .up ? high.y : low.y
            for (index, item) in group.enumerated() {
                result[item.id] = Placement(center: SceneVec2(xs[index], edge + direction * (margin + chipHeight / 2)), side: side)
            }
        }
        for side in [Side.left, .right] {
            // Top to bottom, so the highest part gets the highest chip.
            let group = items.filter { sides[$0.id] == side }.sorted { $0.anchor.y > $1.anchor.y || ($0.anchor.y == $1.anchor.y && $0.id < $1.id) }
            guard !group.isEmpty else { continue }
            let ys = spread(wanted: group.map { -$0.anchor.y }, sizes: group.map(\.size.y), gap: gap).map { -$0 }
            for (index, item) in group.enumerated() {
                let x = side == .right ? high.x + margin + item.size.x / 2 : low.x - margin - item.size.x / 2
                result[item.id] = Placement(center: SceneVec2(x, ys[index]), side: side)
            }
        }
        return result
    }

    /// A wide model gets rows of chips above and below; a tall or squarish one gets a column each side.
    static func prefersRows(low: SceneVec2, high: SceneVec2) -> Bool {
        (high.x - low.x) > (high.y - low.y) * 1.3
    }

    /// Positions along a line as close to `wanted` as possible, in the same order, with no two
    /// closer than their sizes plus `gap`. `wanted` must be sorted ascending.
    static func spread(wanted: [Double], sizes: [Double], gap: Double) -> [Double] {
        guard wanted.count > 1 else { return wanted }
        // Blocks of touching chips; each block sits at the mean of where its members want to be.
        struct Block { var first: Int; var last: Int; var start: Double; var length: Double }
        // Offsets of each chip's centre from the start of a block that begins at chip `first`.
        func centres(from first: Int, to last: Int) -> [Double] {
            var result: [Double] = []
            var cursor = 0.0
            for index in first...last {
                result.append(cursor + sizes[index] / 2)
                cursor += sizes[index] + gap
            }
            return result
        }
        func make(_ first: Int, _ last: Int) -> Block {
            let offsets = centres(from: first, to: last)
            let length = (offsets.last ?? 0) + sizes[last] / 2
            // The start that minimises the squared distance from the wanted spots.
            var sum = 0.0
            for (position, index) in (first...last).enumerated() { sum += wanted[index] - offsets[position] }
            return Block(first: first, last: last, start: sum / Double(last - first + 1), length: length)
        }
        var blocks: [Block] = []
        for index in wanted.indices {
            blocks.append(make(index, index))
            while blocks.count > 1 {
                let previous = blocks[blocks.count - 2], current = blocks[blocks.count - 1]
                guard previous.start + previous.length + gap > current.start else { break }
                blocks.removeLast(2)
                blocks.append(make(previous.first, current.last))
            }
        }
        var result = [Double](repeating: 0, count: wanted.count)
        for block in blocks {
            let offsets = centres(from: block.first, to: block.last)
            for (position, index) in (block.first...block.last).enumerated() { result[index] = block.start + offsets[position] }
        }
        return result
    }

    /// The box around every chip, so the camera can keep them in frame.
    static func bounds(of placements: [String: Placement], items: [Item]) -> (low: SceneVec2, high: SceneVec2)? {
        var low = SceneVec2(repeating: .greatestFiniteMagnitude), high = SceneVec2(repeating: -.greatestFiniteMagnitude)
        var found = false
        for item in items {
            guard let placement = placements[item.id] else { continue }
            low = simd_min(low, placement.center - item.size / 2)
            high = simd_max(high, placement.center + item.size / 2)
            found = true
        }
        return found ? (low, high) : nil
    }

    /// Where a leader line meets its chip: the middle of the edge facing the model.
    static func leaderEnd(for placement: Placement, size: SceneVec2) -> SceneVec2 {
        switch placement.side {
        case .up: return placement.center - SceneVec2(0, size.y / 2)
        case .down: return placement.center + SceneVec2(0, size.y / 2)
        case .left: return placement.center + SceneVec2(size.x / 2, 0)
        case .right: return placement.center - SceneVec2(size.x / 2, 0)
        }
    }
}

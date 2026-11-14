//
//  McpSSEParser.swift
//  leanring-buddy
//
//  Incremental Server-Sent Events parser (WHATWG rules): feed it bytes as they
//  arrive, in any chunking, and it returns the events completed so far.
//  Works on bytes so a multi-byte character split across chunks survives.
//

import Foundation

nonisolated struct SSEEvent: Equatable, Sendable {
    var event: String = "message"
    var data: String
    var id: String?
    var retryMilliseconds: Int?
}

nonisolated struct SSEParser: Sendable {
    private var unfinishedLine: [UInt8] = []
    private var lastByteWasCarriageReturn = false
    private var hasSeenFirstByte = false

    private var dataLines: [String] = []
    private var eventName: String = ""
    private var pendingRetry: Int?
    /// Sticks across events, as the spec says; used for `Last-Event-ID` on reconnect.
    private(set) var lastEventID: String?

    init() {}

    mutating func feed(_ chunk: Data) -> [SSEEvent] {
        var completedEvents: [SSEEvent] = []
        for byte in chunk {
            // A CRLF pair split across two chunks must count as one line ending.
            if lastByteWasCarriageReturn {
                lastByteWasCarriageReturn = false
                if byte == 0x0A { continue }
            }
            if byte == 0x0A || byte == 0x0D {
                lastByteWasCarriageReturn = (byte == 0x0D)
                if let event = finishLine() { completedEvents.append(event) }
                continue
            }
            unfinishedLine.append(byte)
        }
        return completedEvents
    }

    mutating func feed(_ text: String) -> [SSEEvent] {
        feed(Data(text.utf8))
    }

    private mutating func finishLine() -> SSEEvent? {
        var lineBytes = unfinishedLine
        unfinishedLine.removeAll(keepingCapacity: true)
        if !hasSeenFirstByte {
            hasSeenFirstByte = true
            if lineBytes.starts(with: [0xEF, 0xBB, 0xBF]) { lineBytes.removeFirst(3) }
        }
        let line = String(decoding: lineBytes, as: UTF8.self)

        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil } // comment / keep-alive

        let field: String
        var value: String
        if let colonIndex = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colonIndex])
            value = String(line[line.index(after: colonIndex)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = line
            value = ""
        }

        switch field {
        case "data": dataLines.append(value)
        case "event": eventName = value
        case "id": if !value.contains("\0") { lastEventID = value }
        case "retry": if let milliseconds = Int(value), milliseconds >= 0 { pendingRetry = milliseconds }
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            dataLines.removeAll()
            eventName = ""
            pendingRetry = nil
        }
        // A block with no data lines only resets state (it may still have set id/retry).
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(
            event: eventName.isEmpty ? "message" : eventName,
            data: dataLines.joined(separator: "\n"),
            id: lastEventID,
            retryMilliseconds: pendingRetry
        )
    }
}

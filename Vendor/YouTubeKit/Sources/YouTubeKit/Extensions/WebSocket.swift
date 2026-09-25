//
//  WebSocket.swift
//  YouTubeKit
//
//  Created by Alexander Eichhorn on 29.08.23.
//

import Foundation

@available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
extension JSONDecoder {
    
    func decode<T: Decodable>(_ type: T.Type, from message: URLSessionWebSocketTask.Message) throws -> T {
        switch message {
        case .data(let data):
            return try decode(type, from: data)
        case .string(let string):
            return try decode(type, from: string.data(using: .utf8) ?? Data())
        @unknown default:
            // If a future Foundation release adds another message kind, fail
            // this extraction cleanly instead of terminating the app.
            throw YouTubeKitError.extractError
        }
    }
    
}

@available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
extension URLSessionWebSocketTask {
    
    func send(_ value: some Encodable, encoder: JSONEncoder = JSONEncoder()) async throws {
        let encoded = try encoder.encode(value)
        try await send(.data(encoded))
    }
    
}

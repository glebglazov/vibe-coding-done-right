//
//  DestinationProtocol.swift
//  vcdr
//
//  Created by Gleb Glazov on 21/9/25.
//

import Foundation

protocol TextDestination {
    var name: String { get }
    func send(text: String, onPrepareSend: (() async -> Void)?) async throws
    func isAvailable() async -> Bool
}

enum DestinationError: Error {
    case unavailable
    case sendFailed(String)

    var localizedDescription: String {
        switch self {
        case .unavailable:
            return "Destination is not available"
        case .sendFailed(let message):
            return message
        }
    }
}
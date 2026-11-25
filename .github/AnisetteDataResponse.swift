//
//  AnisetteDataResponse.swift
//  AnisetteKit
//
//  Created by Magesh K on 07/09/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

import Foundation

public struct AnisetteDataResponse: Sendable, Codable, Equatable, Hashable {
    public let oneTimePassword: String
    public let machineID: String
    public let clientInfo: String?
    public let deviceID: String?
    public let localUserID: String?
    public let routingInfo: String?

    public init(
        oneTimePassword: String,
        machineID: String,
        clientInfo: String? = nil,
        deviceID: String? = nil,
        localUserID: String? = nil,
        routingInfo: String? = nil
    ) {
        self.oneTimePassword = oneTimePassword
        self.machineID = machineID
        self.clientInfo = clientInfo
        self.deviceID = deviceID
        self.localUserID = localUserID
        self.routingInfo = routingInfo
    }

    public init(from dictionary: [String: String]) throws {
        guard let otp = dictionary[AnisetteConstants.Headers.oneTimePassword],
              let mid = dictionary[AnisetteConstants.Headers.machineID] else
        {
            throw AnisetteError.invalidResponse(reason: "Missing \(AnisetteConstants.Headers.oneTimePassword) or \(AnisetteConstants.Headers.machineID) from response")
        }
        self.oneTimePassword = otp
        self.machineID = mid
        self.clientInfo = header(dictionary, AnisetteConstants.Headers.clientInfo)
        self.deviceID = header(dictionary, AnisetteConstants.Headers.deviceID)
        self.localUserID = header(dictionary, AnisetteConstants.Headers.localUserID)
        self.routingInfo = header(dictionary, AnisetteConstants.Headers.routingInfo)
    }
}

private func header(_ dictionary: [String: String], _ name: String) -> String? {
    if let direct = dictionary[name], !direct.isEmpty { return direct }
    let wanted = name.lowercased()
    return dictionary.first { $0.key.lowercased() == wanted && !$0.value.isEmpty }?.value
}

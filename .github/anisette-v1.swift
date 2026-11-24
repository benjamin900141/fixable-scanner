        if !provider.requiresLocalLibraries {
            do {
                let response = try await provider.getAnisetteHeaders(
                    libDir: libDir?.path ?? "",
                    provisioningDir: provisioningDir.path,
                    identifier: identifier.uuidBytes,
                    adiPb: []
                )
                if !response.oneTimePassword.isEmpty && !response.machineID.isEmpty {
                    let headers = AnisetteRequestHeaders.defaultHeaders
                        .applyingOverrides(customHeaders)
                        .with {
                            $0.oneTimePassword = response.oneTimePassword
                            $0.machineID = response.machineID
                            if $0.deviceID == nil { $0.deviceID = identifier.uuidString.uppercased() }
                            if let storedRinfo = getStoredRoutingInfo(for: identifier) { $0.routingInfo = storedRinfo }
                            if $0.date == nil && $0.clientTime == nil { $0.date = Date() }
                            if customHeaders?.clientInfo == nil { $0.clientInfo = self.clientInfo }
                            if customHeaders?.userAgent == nil { $0.userAgent = self.userAgent }
                        }
                    return (AnisetteHeadersDTO.toDictionary(from: headers), nil)
                }
            } catch {
                verboseLog("[AnisetteKit] Direct anisette headers were not available.")
            }
        }

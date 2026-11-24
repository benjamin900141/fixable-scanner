        if !provider.requiresLocalLibraries {
            do {
                let response = try await provider.getAnisetteHeaders(
                    libDir: libDir?.path ?? "",
                    provisioningDir: provisioningDir.path,
                    identifier: identifier.uuidBytes,
                    adiPb: []
                )
                let info = response.clientInfo ?? ""
                if response.oneTimePassword.isEmpty || response.machineID.isEmpty || info.isEmpty || info.contains("macOS;") {
                    throw AnisetteError.invalidAnisetteData
                }
                let headers = AnisetteRequestHeaders.defaultHeaders
                    .applyingOverrides(customHeaders)
                    .with {
                        $0.oneTimePassword = response.oneTimePassword
                        $0.machineID = response.machineID
                        $0.clientInfo = info
                        if let device = response.deviceID, !device.isEmpty { $0.deviceID = device }
                        if let localUser = response.localUserID, !localUser.isEmpty { $0.localUserID = localUser }
                        if let routing = response.routingInfo, !routing.isEmpty { $0.routingInfo = routing }
                        if $0.deviceID == nil || $0.deviceID?.isEmpty == true {
                            $0.deviceID = identifier.uuidString.uppercased()
                        }
                        if let storedRinfo = getStoredRoutingInfo(for: identifier), !storedRinfo.isEmpty {
                            $0.routingInfo = storedRinfo
                        }
                        if $0.date == nil && $0.clientTime == nil { $0.date = Date() }
                        if customHeaders?.userAgent == nil { $0.userAgent = self.userAgent }
                    }
                return (AnisetteHeadersDTO.toDictionary(from: headers), nil)
            } catch {
                verboseLog("[AnisetteKit] Direct anisette headers were not available.")
            }
        }

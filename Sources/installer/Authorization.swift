//
//  Authorization.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import Foundation
import Security
import ServiceManagement

/// Handles macOS authorization for privileged operations
struct Authorization {

  /// Request authorization to install privileged helper
  static func requestInstallRights() throws -> AuthorizationRef {
    var authRef: AuthorizationRef?

    var status = AuthorizationCreate(nil, nil, [], &authRef)
    guard status == errAuthorizationSuccess, let auth = authRef else {
      throw AuthorizationError.createFailed(status)
    }

    let flags: AuthorizationFlags = [
      .interactionAllowed,
      .preAuthorize,
      .extendRights,
    ]

    status = kSMRightBlessPrivilegedHelper.withCString { rightPtr in
      var authItem = AuthorizationItem(
        name: rightPtr,
        valueLength: 0,
        value: nil,
        flags: 0
      )

      return withUnsafeMutablePointer(to: &authItem) { itemPtr in
        var authRights = AuthorizationRights(count: 1, items: itemPtr)
        return AuthorizationCopyRights(auth, &authRights, nil, flags, nil)
      }
    }

    guard status == errAuthorizationSuccess else {
      AuthorizationFree(auth, [])
      throw AuthorizationError.copyRightsFailed(status)
    }

    return auth
  }
}

enum AuthorizationError: Error, LocalizedError {
  case createFailed(OSStatus)
  case copyRightsFailed(OSStatus)

  var errorDescription: String? {
    switch self {
    case .createFailed(let status):
      return "AuthorizationCreate failed: \(status)"
    case .copyRightsFailed(let status):
      return "AuthorizationCopyRights failed: \(status)"
    }
  }
}

import Foundation
import UIKit
import GoogleSignIn

/// Wraps Google Sign-In for the Drive scope. The client ID is configured in
/// `Info.plist` (`GIDClientID`) plus the reversed-client-id URL scheme.
@MainActor
struct DriveAuth {
    static let driveScope = "https://www.googleapis.com/auth/drive.file"

    /// Returns the existing user (post sign-in) or nil when signed out.
    static var currentUser: GIDGoogleUser? { GIDSignIn.sharedInstance.currentUser }

    /// Restores a previous session if present (call on app launch).
    static func restorePreviousSignIn() async -> GIDGoogleUser? {
        await withCheckedContinuation { cont in
            GIDSignIn.sharedInstance.restorePreviousSignIn { user, _ in
                cont.resume(returning: user)
            }
        }
    }

    static func signIn(presenting: UIViewController) async throws -> GIDGoogleUser {
        try await withCheckedThrowingContinuation { cont in
            GIDSignIn.sharedInstance.signIn(
                withPresenting: presenting,
                hint: nil,
                additionalScopes: [driveScope]
            ) { result, error in
                if let error { cont.resume(throwing: error); return }
                guard let user = result?.user else {
                    cont.resume(throwing: NSError(
                        domain: "DriveAuth", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No user returned"]
                    ))
                    return
                }
                let granted = user.grantedScopes ?? []
                if !granted.contains(driveScope) {
                    user.addScopes([driveScope], presenting: presenting) { addResult, addError in
                        if let addError { cont.resume(throwing: addError); return }
                        cont.resume(returning: addResult?.user ?? user)
                    }
                } else {
                    cont.resume(returning: user)
                }
            }
        }
    }

    static func signOut() {
        GIDSignIn.sharedInstance.signOut()
    }

    /// Refreshes and returns a current OAuth access token.
    static func freshAccessToken() async throws -> String {
        guard let user = currentUser else {
            throw NSError(domain: "DriveAuth", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Not signed in to Google"])
        }
        return try await withCheckedThrowingContinuation { cont in
            user.refreshTokensIfNeeded { refreshed, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: refreshed?.accessToken.tokenString ?? user.accessToken.tokenString)
            }
        }
    }
}

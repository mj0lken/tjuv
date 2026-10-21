import Foundation
import LocalAuthentication

/// Manages biometric (Touch ID) and password authentication for securely disarming Tjuv.
final class AuthManager {
    static let shared = AuthManager()
    
    var requireAuthToDisarm: Bool {
        get { UserDefaults.standard.bool(forKey: "requireAuthToDisarm") }
        set { UserDefaults.standard.set(newValue, forKey: "requireAuthToDisarm") }
    }
    
    var isBiometricsAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }
    
    func authenticateToDisarm(reason: String = "Disarm Tjuv Anti-Theft Alarm", completion: @escaping (Bool) -> Void) {
        guard requireAuthToDisarm else {
            completion(true)
            return
        }
        
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                DispatchQueue.main.async {
                    completion(success)
                }
            }
        } else {
            // Biometrics/Passcode not available on system, allow disarm
            completion(true)
        }
    }
}

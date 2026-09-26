import Observation

/// Re-registering wrapper around withObservationTracking: `apply` runs
/// immediately and again after every change to the @Observable properties it
/// read on the previous run. MainActor-confined.
@MainActor
func observeOnMain(_ apply: @escaping @MainActor () -> Void) {
    withObservationTracking {
        apply()
    } onChange: {
        Task { @MainActor in observeOnMain(apply) }
    }
}

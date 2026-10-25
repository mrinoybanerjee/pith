import Testing

// Native windows share the application's key window and first responder. `scripts/test.sh` runs
// each test of this suite in its own process.
@Suite(.serialized) @MainActor
struct NativeInteractionTests {}

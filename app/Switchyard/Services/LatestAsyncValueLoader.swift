import Foundation

@MainActor
final class LatestAsyncValueLoader<Request: Equatable & Sendable> {
    private var generation: UInt64 = 0
    private var currentRequest: Request?

    func load<Value: Sendable>(
        request: Request,
        operation: @escaping @Sendable (Request) async -> Value,
        isCurrent: (Request) -> Bool,
        publish: (Value) -> Void
    ) async {
        generation &+= 1
        let requestedGeneration = generation
        currentRequest = request

        let value = await operation(request)

        guard !Task.isCancelled,
              generation == requestedGeneration,
              currentRequest == request,
              isCurrent(request) else {
            return
        }
        publish(value)
    }
}

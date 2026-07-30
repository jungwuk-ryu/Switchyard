import Testing
@testable import Switchyard

@MainActor
@Suite("Latest Async Value Loader")
struct LatestAsyncValueLoaderTests {
    @Test(
        "publishes B when B finishes before an older A request",
        .timeLimit(.minutes(1))
    )
    func newerRequestWinsWhenItFinishesFirst() async {
        let source = ControlledValueSource<String?, String?>()
        let loader = LatestAsyncValueLoader<String?>()
        var requestedValue: String? = "A"
        var publishedValues: [String] = []

        let firstLoad = Task {
            await loader.load(
                request: "A",
                operation: { request in
                    await source.value(for: request)
                },
                isCurrent: { request in
                    request == requestedValue
                },
                publish: { value in
                    if let value {
                        publishedValues.append(value)
                    }
                }
            )
        }
        await source.waitUntilStarted("A")

        requestedValue = "B"
        let secondLoad = Task {
            await loader.load(
                request: "B",
                operation: { request in
                    await source.value(for: request)
                },
                isCurrent: { request in
                    request == requestedValue
                },
                publish: { value in
                    if let value {
                        publishedValues.append(value)
                    }
                }
            )
        }
        await source.waitUntilStarted("B")

        await source.finish("B", with: "image-B")
        await secondLoad.value
        await source.finish("A", with: "image-A")
        await firstLoad.value

        #expect(publishedValues == ["image-B"])
    }

    @Test(
        "publishes nil without allowing an older image to return",
        .timeLimit(.minutes(1))
    )
    func nilRequestSupersedesOlderImage() async {
        let source = ControlledValueSource<String?, String?>()
        let loader = LatestAsyncValueLoader<String?>()
        var requestedValue: String? = "A"
        var publishedValue: String? = "existing"
        var publishCount = 0

        let imageLoad = Task {
            await loader.load(
                request: "A",
                operation: { request in
                    await source.value(for: request)
                },
                isCurrent: { request in
                    request == requestedValue
                },
                publish: { value in
                    publishedValue = value
                    publishCount += 1
                }
            )
        }
        await source.waitUntilStarted("A")

        requestedValue = nil
        let nilLoad = Task {
            await loader.load(
                request: nil,
                operation: { request in
                    await source.value(for: request)
                },
                isCurrent: { request in
                    request == requestedValue
                },
                publish: { value in
                    publishedValue = value
                    publishCount += 1
                }
            )
        }
        await source.waitUntilStarted(nil)

        await source.finish(nil, with: nil)
        await nilLoad.value
        await source.finish("A", with: "image-A")
        await imageLoad.value

        #expect(publishedValue == nil)
        #expect(publishCount == 1)
    }

    @Test(
        "does not publish after the awaiting task is cancelled",
        .timeLimit(.minutes(1))
    )
    func cancellationPreventsPublish() async {
        let source = ControlledValueSource<String, String>()
        let loader = LatestAsyncValueLoader<String>()
        var publishedValue: String?

        let load = Task {
            await loader.load(
                request: "A",
                operation: { request in
                    await source.value(for: request)
                },
                isCurrent: { _ in true },
                publish: { value in
                    publishedValue = value
                }
            )
        }
        await source.waitUntilStarted("A")

        load.cancel()
        await source.finish("A", with: "image-A")
        await load.value

        #expect(publishedValue == nil)
    }
}

private actor ControlledValueSource<Request: Hashable & Sendable, Value: Sendable> {
    private var continuations: [
        Request: CheckedContinuation<Value, Never>
    ] = [:]
    private var startedRequests: Set<Request> = []
    private var startWaiters: [
        Request: [CheckedContinuation<Void, Never>]
    ] = [:]

    func value(for request: Request) async -> Value {
        startedRequests.insert(request)
        let waiters = startWaiters.removeValue(forKey: request) ?? []
        waiters.forEach { $0.resume() }

        return await withCheckedContinuation { continuation in
            continuations[request] = continuation
        }
    }

    func waitUntilStarted(_ request: Request) async {
        guard !startedRequests.contains(request) else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters[request, default: []].append(continuation)
        }
    }

    func finish(_ request: Request, with value: Value) {
        continuations.removeValue(forKey: request)?.resume(returning: value)
    }
}

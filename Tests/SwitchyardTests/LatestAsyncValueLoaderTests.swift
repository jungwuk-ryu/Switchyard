import Foundation
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

    @Test(
        "publishes only the newest invocation when a request returns to the same value",
        .timeLimit(.minutes(1))
    )
    func repeatedRequestValueStillUsesLatestGeneration() async {
        let source = SequencedControlledValueSource<String, String>()
        let loader = LatestAsyncValueLoader<String>()
        var requestedValue = "A"
        var publishedValues: [String] = []

        let firstALoad = Task {
            await loader.load(
                request: "A",
                operation: { request in
                    await source.value(for: request)
                },
                isCurrent: { request in
                    request == requestedValue
                },
                publish: { value in
                    publishedValues.append(value)
                }
            )
        }
        await source.waitUntilStarted(.init(request: "A", ordinal: 1))

        requestedValue = "B"
        let bLoad = Task {
            await loader.load(
                request: "B",
                operation: { request in
                    await source.value(for: request)
                },
                isCurrent: { request in
                    request == requestedValue
                },
                publish: { value in
                    publishedValues.append(value)
                }
            )
        }
        await source.waitUntilStarted(.init(request: "B", ordinal: 1))

        requestedValue = "A"
        let secondALoad = Task {
            await loader.load(
                request: "A",
                operation: { request in
                    await source.value(for: request)
                },
                isCurrent: { request in
                    request == requestedValue
                },
                publish: { value in
                    publishedValues.append(value)
                }
            )
        }
        await source.waitUntilStarted(.init(request: "A", ordinal: 2))

        await source.finish(.init(request: "A", ordinal: 2), with: "value-A2")
        await secondALoad.value
        await source.finish(.init(request: "B", ordinal: 1), with: "value-B")
        await bLoad.value
        await source.finish(.init(request: "A", ordinal: 1), with: "value-A1")
        await firstALoad.value

        #expect(publishedValues == ["value-A2"])
    }

    @Test(
        "a pre-cancelled older invocation cannot supersede the active request",
        .timeLimit(.minutes(1))
    )
    func preCancelledInvocationDoesNotTakeGenerationOrPrepareState() async {
        let source = ControlledValueSource<URL, String>()
        let startGate = ControlledValueSource<String, Void>()
        let loader = ContainerDirectoryRequestLoader()
        let currentURL = URL(fileURLWithPath: "/container/B", isDirectory: true)
        let staleURL = URL(fileURLWithPath: "/container/A", isDirectory: true)
        var preparedURLs: [URL] = []
        var publishedValues: [String] = []

        let activeLoad = Task {
            await loader.load(
                request: currentURL,
                prepare: {
                    preparedURLs.append(currentURL)
                },
                operation: { request in
                    await source.value(for: request)
                },
                isCurrent: { request in
                    request == currentURL
                },
                publish: { value in
                    publishedValues.append(value)
                }
            )
        }
        await source.waitUntilStarted(currentURL)

        let staleLoad = Task {
            await startGate.value(for: "stale")
            await loader.load(
                request: staleURL,
                prepare: {
                    preparedURLs.append(staleURL)
                },
                operation: { _ in
                    "stale"
                },
                isCurrent: { request in
                    request == currentURL
                },
                publish: { value in
                    publishedValues.append(value)
                }
            )
        }
        await startGate.waitUntilStarted("stale")
        staleLoad.cancel()
        await startGate.finish("stale", with: ())
        await staleLoad.value

        await source.finish(currentURL, with: "current")
        await activeLoad.value

        #expect(preparedURLs == [currentURL])
        #expect(publishedValues == ["current"])
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

private struct ControlledRequestInvocation<Request: Hashable & Sendable>:
    Hashable,
    Sendable
{
    let request: Request
    let ordinal: Int
}

private actor SequencedControlledValueSource<
    Request: Hashable & Sendable,
    Value: Sendable
> {
    typealias Invocation = ControlledRequestInvocation<Request>

    private var invocationCountByRequest: [Request: Int] = [:]
    private var continuations: [
        Invocation: CheckedContinuation<Value, Never>
    ] = [:]
    private var startedInvocations: Set<Invocation> = []
    private var startWaiters: [
        Invocation: [CheckedContinuation<Void, Never>]
    ] = [:]

    func value(for request: Request) async -> Value {
        let ordinal = invocationCountByRequest[request, default: 0] + 1
        invocationCountByRequest[request] = ordinal
        let invocation = Invocation(request: request, ordinal: ordinal)
        startedInvocations.insert(invocation)
        let waiters = startWaiters.removeValue(forKey: invocation) ?? []
        waiters.forEach { $0.resume() }

        return await withCheckedContinuation { continuation in
            continuations[invocation] = continuation
        }
    }

    func waitUntilStarted(_ invocation: Invocation) async {
        guard !startedInvocations.contains(invocation) else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters[invocation, default: []].append(continuation)
        }
    }

    func finish(_ invocation: Invocation, with value: Value) {
        continuations.removeValue(forKey: invocation)?.resume(returning: value)
    }
}

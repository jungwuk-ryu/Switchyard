import Darwin
import Foundation
@testable import RuntimeCatalog
import Testing

@Test func runtimeProcessRunnerDrainsBothPipesWhileBoundingCapturedBytes() throws {
    let fixture = try RuntimeProcessFixture()
    defer { fixture.cleanUp() }

    let captureLimit = 64 * 1_024
    let result = try RuntimeProcessRunner(
        maximumCapturedBytesPerStream: captureLimit,
        terminationGrace: 0.5,
        cancellationPollingInterval: 0.01
    ).run(
        executableURL: fixture.executableURL,
        arguments: ["flood"],
        timeout: 5
    )

    #expect(result.terminationStatus == 0)
    #expect(result.standardOutput == Data(repeating: 0x4f, count: captureLimit))
    #expect(result.standardError == Data(repeating: 0x45, count: captureLimit))
    #expect(result.standardOutputWasTruncated)
    #expect(result.standardErrorWasTruncated)
}

@Test func runtimeProcessRunnerTimeoutTerminatesAndReapsExactChild() throws {
    let fixture = try RuntimeProcessFixture()
    defer { fixture.cleanUp() }

    do {
        _ = try RuntimeProcessRunner(
            maximumCapturedBytesPerStream: 1_024,
            terminationGrace: 0.5,
            cancellationPollingInterval: 0.01
        ).run(
            executableURL: fixture.executableURL,
            arguments: [
                "ignore-term",
                fixture.processIDURL.path,
                fixture.terminationMarkerURL.path
            ],
            timeout: 2
        )
        Issue.record("Expected the fake process to time out.")
    } catch let error as RuntimeProcessExecutionError {
        #expect(error == .timedOut)
    }

    let processID = try fixture.recordedProcessID()
    fixture.ownedProcessID = processID
    #expect(try fixture.recordedTerminationProcessID() == processID)
    #expect(fixture.waitForExactProcessToDisappear(processID))
    fixture.ownedProcessID = nil
}

@Test func runtimeProcessRunnerDoesNotBlockWhenKillConfirmationDoesNotArrive() throws {
    let fixture = try RuntimeProcessFixture()
    defer { fixture.cleanUp() }

    let startedAt = ProcessInfo.processInfo.systemUptime
    var reportedProcessID: pid_t?
    do {
        _ = try RuntimeProcessRunner(
            maximumCapturedBytesPerStream: 1_024,
            terminationGrace: 0.01,
            cancellationPollingInterval: 0.01,
            postKillConfirmationTimeout: 0.01,
            captureShutdownTimeout: 0.1,
            postKillCompletionWait: { _, _ in .timedOut }
        ).run(
            executableURL: fixture.executableURL,
            arguments: [
                "ignore-term",
                fixture.processIDURL.path,
                fixture.terminationMarkerURL.path
            ],
            timeout: 5,
            cancellationRequested: {
                FileManager.default.fileExists(
                    atPath: fixture.processIDURL.path
                )
            }
        )
        Issue.record("Expected the fake process termination to be unconfirmed.")
    } catch let error as RuntimeProcessExecutionError {
        if case let .terminationUnconfirmed(processIdentifier) = error {
            reportedProcessID = processIdentifier
        } else {
            Issue.record("Unexpected error: \(error)")
        }
    }

    let processID = try fixture.recordedProcessID()
    fixture.ownedProcessID = processID
    #expect(reportedProcessID == processID)
    #expect(try fixture.recordedTerminationProcessID() == processID)
    #expect(ProcessInfo.processInfo.systemUptime - startedAt < 2)
    #expect(fixture.waitForExactProcessToDisappear(processID))
    fixture.ownedProcessID = nil
}

@Test func runtimeProcessRunnerCancellationTerminatesAndReapsExactChild() throws {
    let fixture = try RuntimeProcessFixture()
    defer { fixture.cleanUp() }

    do {
        _ = try RuntimeProcessRunner(
            maximumCapturedBytesPerStream: 1_024,
            terminationGrace: 0.5,
            cancellationPollingInterval: 0.01
        ).run(
            executableURL: fixture.executableURL,
            arguments: [
                "wait",
                fixture.processIDURL.path,
                fixture.terminationMarkerURL.path
            ],
            timeout: 5,
            cancellationRequested: {
                FileManager.default.fileExists(
                    atPath: fixture.processIDURL.path
                )
            }
        )
        Issue.record("Expected the fake process to be cancelled.")
    } catch let error as RuntimeProcessExecutionError {
        #expect(error == .cancelled)
    }

    let processID = try fixture.recordedProcessID()
    fixture.ownedProcessID = processID
    #expect(try fixture.recordedTerminationProcessID() == processID)
    #expect(fixture.waitForExactProcessToDisappear(processID))
    fixture.ownedProcessID = nil
}

@Test func runtimeProcessRunnerDoesNotWaitForDescendantHeldPipes() throws {
    let fixture = try RuntimeProcessFixture()
    defer { fixture.cleanUp() }
    let startedAt = ProcessInfo.processInfo.systemUptime

    let result = try RuntimeProcessRunner(
        maximumCapturedBytesPerStream: 1_024,
        terminationGrace: 0.25,
        cancellationPollingInterval: 0.01,
        captureShutdownTimeout: 0.25
    ).run(
        executableURL: fixture.executableURL,
        arguments: [
            "fork-hold",
            fixture.processIDURL.path,
            fixture.terminationMarkerURL.path
        ],
        timeout: 2
    )

    let descendantProcessID = try fixture.recordedProcessID()
    fixture.ownedProcessID = descendantProcessID
    #expect(result.terminationStatus == 0)
    #expect(ProcessInfo.processInfo.systemUptime - startedAt < 1.5)
    #expect(Darwin.kill(descendantProcessID, SIGTERM) == 0)
    #expect(fixture.waitForExactProcessToDisappear(descendantProcessID))
    #expect(
        try fixture.recordedTerminationProcessID() == descendantProcessID
    )
    fixture.ownedProcessID = nil
}

private final class RuntimeProcessFixture {
    let rootURL: URL
    let executableURL: URL
    let processIDURL: URL
    let terminationMarkerURL: URL
    var ownedProcessID: pid_t?

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Switchyard-RuntimeProcessRunner-\(UUID().uuidString)",
            isDirectory: true
        )
        executableURL = rootURL.appendingPathComponent("fake-process.pl")
        processIDURL = rootURL.appendingPathComponent("process.pid")
        terminationMarkerURL = rootURL.appendingPathComponent("terminated.pid")

        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        try Self.script.write(
            to: executableURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )
    }

    func recordedProcessID() throws -> pid_t {
        let value = try String(contentsOf: processIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(pid_t(value))
    }

    func recordedTerminationProcessID() throws -> pid_t {
        let value = try String(contentsOf: terminationMarkerURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(pid_t(value))
    }

    func waitForExactProcessToDisappear(
        _ processID: pid_t,
        timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while processExists(processID),
              ProcessInfo.processInfo.systemUptime < deadline {
            usleep(10_000)
        }
        return !processExists(processID)
    }

    func cleanUp() {
        if let ownedProcessID, processExists(ownedProcessID) {
            _ = Darwin.kill(ownedProcessID, SIGKILL)
            _ = waitForExactProcessToDisappear(ownedProcessID)
        }
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func processExists(_ processID: pid_t) -> Bool {
        errno = 0
        if Darwin.kill(processID, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private static let script = """
    #!/usr/bin/perl
    use strict;
    use warnings;

    my $mode = shift @ARGV // "";
    if ($mode eq "flood") {
        binmode STDOUT;
        binmode STDERR;
        print STDOUT ("O" x (2 * 1024 * 1024));
        print STDERR ("E" x (2 * 1024 * 1024));
        exit 0;
    }

    if ($mode eq "wait" || $mode eq "ignore-term") {
        my ($pid_path, $termination_path) = @ARGV;
        $SIG{TERM} = sub {
            open my $marker, ">", $termination_path or die $!;
            print {$marker} "$$\\n";
            close $marker or die $!;
            exit 0 if $mode eq "wait";
        };

        open my $pid_file, ">", $pid_path or die $!;
        print {$pid_file} "$$\\n";
        close $pid_file or die $!;

        while (1) {
            select undef, undef, undef, 0.05;
        }
    }

    if ($mode eq "fork-hold") {
        my ($pid_path, $termination_path) = @ARGV;
        my $child = fork();
        die "fork failed" unless defined $child;

        if ($child == 0) {
            $SIG{TERM} = sub {
                open my $marker, ">", $termination_path or die $!;
                print {$marker} "$$\\n";
                close $marker or die $!;
                exit 0;
            };

            open my $pid_file, ">", $pid_path or die $!;
            print {$pid_file} "$$\\n";
            close $pid_file or die $!;

            for (1 .. 80) {
                select undef, undef, undef, 0.05;
            }
            exit 0;
        }

        for (1 .. 100) {
            last if -e $pid_path;
            select undef, undef, undef, 0.01;
        }
        exit((-e $pid_path) ? 0 : 3);
    }

    die "unknown mode";
    """
}

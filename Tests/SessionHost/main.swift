import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

// The session host's macOS-runnable half, compiled with the Apelind sources
// it exercises (Scripts/test-session-host.sh): task records surviving a
// restart, builds and environment tasks started again after one, the
// caller policy, the protected-edit rules on a temporary
// install root, the managed-package rules, the install bridge against a
// fake irisind, the approval ledger, the deb control reader, the copies a
// tool call's attachments travel as, and a real PTY.

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

var failures = 0
var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ what: String, line: UInt = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL \(what) (line \(line))")
    }
}

func expectError(_ what: String, code: ApelinError.Code? = nil, line: UInt = #line, _ body: () throws -> Void) {
    checks += 1
    do {
        try body()
        failures += 1
        print("FAIL \(what): no error (line \(line))")
    } catch let error as ApelinError {
        if let code, error.code != code {
            failures += 1
            print("FAIL \(what): \(error) (line \(line))")
        }
    } catch {
        if code != nil {
            failures += 1
            print("FAIL \(what): \(error) (line \(line))")
        }
    }
}

@MainActor
func expectErrorAsync(
    _ what: String,
    code: ApelinError.Code? = nil,
    line: UInt = #line,
    _ body: () async throws -> Void,
) async {
    checks += 1
    do {
        try await body()
        failures += 1
        print("FAIL \(what): no error (line \(line))")
    } catch let error as ApelinError {
        if let code, error.code != code {
            failures += 1
            print("FAIL \(what): \(error) (line \(line))")
        }
    } catch {
        failures += 1
        print("FAIL \(what): \(error) (line \(line))")
    }
}

let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("apelin-session-host-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }
let scratchPath = CanonicalPath.resolve(scratch.path)!

func write(_ path: String, _ text: String, mode: mode_t = 0o644) {
    try! FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true,
    )
    FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
    chmod(path, mode)
}

func run(_ executable: String, _ arguments: [String], in directory: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    try! process.run()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0, "\(executable) \(arguments) failed")
}

func sha256(_ path: String) -> String {
    let descriptor = open(path, O_RDONLY)
    defer { close(descriptor) }
    return String(try! ProtectedEditPolicy.sha256(descriptor: descriptor).dropFirst(7))
}

/// A `.deb` with a gzip control member, written by hand as ar.
func makeDeb(at path: String, package: String, version: String) {
    let work = scratchPath + "/deb-\(UUID().uuidString)"
    write(
        work + "/control/control",
        "Package: \(package)\nVersion: \(version)\nArchitecture: iphoneos-arm64e\nDescription: test\n",
    )
    write(work + "/data/usr/share/\(package)/hello", "hello\n")
    run(
        "/usr/bin/tar",
        ["--format", "ustar", "-czf", work + "/control.tar.gz", "-C", work + "/control", "./control"],
        in: work,
    )
    run("/usr/bin/tar", ["--format", "ustar", "-czf", work + "/data.tar.gz", "-C", work + "/data", "."], in: work)
    let archive = arArchive([
        ("debian-binary", Data("2.0\n".utf8)),
        ("control.tar.gz", FileManager.default.contents(atPath: work + "/control.tar.gz")!),
        ("data.tar.gz", FileManager.default.contents(atPath: work + "/data.tar.gz")!),
    ])
    FileManager.default.createFile(atPath: path, contents: archive)
}

/// An ar archive of these members, as a deb is one.
func arArchive(_ members: [(name: String, contents: Data)]) -> Data {
    var archive = Data("!<arch>\n".utf8)
    for (name, contents) in members {
        func field(_ value: String, _ width: Int) -> String {
            value.padding(toLength: width, withPad: " ", startingAt: 0)
        }
        archive.append(Data((field(name + "/", 16) + field("0", 12) + field("0", 6) + field("0", 6)
                + field("100644", 8) + field(String(contents.count), 10) + "`\n").utf8))
        archive.append(contents)
        if contents.count % 2 == 1 {
            archive.append(0x0A)
        }
    }
    return archive
}

// MARK: - Task records persist and resume

do {
    let directory = scratch.appendingPathComponent("tasks")
    let first = TaskRegistry(directory: directory)
    await first.load()
    let resumable = await first.create(kind: .install, owner: nil)
    let plain = await first.create(kind: .build, owner: .build, ownerKey: "b1")
    let done = await first.create(kind: .environment, owner: .environment)
    await first.append(resumable.taskID, kind: "stage", payload: .object(["stage": .string("staged")]))
    await first.setResume(resumable.taskID, .object(["installationID": .string("x")]))
    await first.append(plain.taskID, kind: "log", payload: .object(["line": .string("one")]))
    await first.finish(done.taskID, .succeeded)
    let counts = await first.activeByKind
    check(counts == ["install": 1, "build": 1], "active tasks counted by kind")

    // A new host on the same directory: what was running comes back.
    let second = TaskRegistry(directory: directory)
    let unfinished = await second.load()
    check(Set(unfinished.map(\.id)) == [resumable.taskID, plain.taskID], "unfinished tasks are handed back on relaunch")
    check(unfinished.first { $0.id == resumable.taskID }?.resume?["installationID"]?.stringValue == "x", "resume data survives")
    await second.interrupt(plain.taskID)
    let interrupted = await second.record(plain.taskID)
    check(interrupted?.state == .interrupted, "a task nobody resumes is interrupted")
    let replay = try await second.attach(plain.taskID, as: .buildAttach, afterSeq: .start, waitMilliseconds: 0)
    check(replay.events.map(\.kind) == ["log", "state"] && replay.events.map(\.seq.rawValue) == [1, 2], "events replay numbered from 1 with no gaps")
    check(replay.finished, "an interrupted task reads as finished")
    let resumed = try await second.attach(
        resumable.taskID,
        as: .buildAttach,
        afterSeq: EventSeq(1),
        waitMilliseconds: 0,
    )
    check(resumed.events.isEmpty && resumed.state == .running, "a resumed task keeps running")
    let finished = await second.record(done.taskID)
    check(finished?.state == .succeeded, "finished tasks stay finished")
}

// MARK: - Builds and environment tasks start again after a restart

/// apelin-build in miniature, over a real channel: it answers a task's
/// request at once, then emits a log line and the final `state`, unless told
/// to hang (a host that dies before the task ends).
final class FakeTaskWorker: @unchecked Sendable {
    let host: WorkerChannel
    let worker: WorkerChannel
    let lock = NSLock()
    var seen: [(taskID: TaskID?, resumed: Bool, operation: AppOperation)] = []
    var hang = false
    /// Where events go: the registry of the host that is running now.
    var registry: TaskRegistry?

    init() throws {
        let (local, remote) = try WorkerChannel.makePair()
        host = WorkerChannel(adopting: local)
        worker = WorkerChannel(adopting: remote)
        worker.onRequest { [self] request in
            let hang = lock.withLock { () -> Bool in
                seen.append((request.taskID, request.resumed, request.request.operation))
                return self.hang
            }
            if let taskID = request.taskID, !hang {
                Task {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    try? self.worker.sendEvent(
                        taskID: taskID,
                        kind: "log",
                        payload: .object(["line": .string(request.resumed ? "again" : "first")]),
                    )
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    try? self.worker.sendEvent(
                        taskID: taskID,
                        kind: TaskEvent.stateKind,
                        payload: .object(["state": .string(TaskState.succeeded.rawValue)]),
                    )
                }
            }
            return (.success(request.request.requestID, Acknowledged()), [])
        }
        host.onEvent { [self] frame in
            guard let taskID = frame.header.taskID, let kind = frame.header.name, let registry = lock.withLock({ self.registry }) else { return }
            let payload = frame.body.isEmpty ? nil : try? JSONCoding.decode(JSONValue.self, from: frame.body)
            Task { await registry.append(taskID, kind: kind, payload: payload) }
        }
        worker.start()
        host.start()
    }

    func resumer(_ registry: TaskRegistry, refuse: Bool = false) -> TaskResume {
        lock.withLock { self.registry = registry }
        return TaskResume(
            registry: registry,
            dispatch: { [host] record, request in
                try await host.call(request, taskID: record.id, resumed: true).0
            },
            recheck: { caller, _ in
                refuse && caller.isAgent ? ApelinError(.denied, "approval required") : nil
            },
        )
    }
}

do {
    let directory = scratch.appendingPathComponent("resume-tasks")
    let fake = try FakeTaskWorker()
    let build = try WireRequest(BuildStartRequest(projectID: "p1", configuration: .debug))

    // A build the first host started: a stage, then the host is killed.
    var host = TaskRegistry(directory: directory)
    await host.load()
    let started = await host.create(kind: .build, owner: .build)
    await host.setResume(started.taskID, TaskResume.plan(build, descriptorCount: 0, caller: .app))
    await host.append(started.taskID, kind: "stage", payload: .object(["stage": .string("compile")]))

    // Others it left: an import from a descriptor, a cancelled build, a
    // clone whose URL carries a token, a toolchain removal, an agent's build.
    let fromDescriptor = await host.create(kind: .environment, owner: .environment)
    let importRequest = try WireRequest(SDKImportRequest(source: .file(DescriptorSlot(index: 0))))
    await host.setResume(fromDescriptor.taskID, TaskResume.plan(importRequest, descriptorCount: 1, caller: .app))
    let cancelled = await host.create(kind: .build, owner: .build)
    await host.setResume(cancelled.taskID, TaskResume.plan(build, descriptorCount: 0, caller: .app))
    _ = try await host.requestCancel(cancelled.taskID)
    let secretClone = await host.create(kind: .environment, owner: .environment)
    let cloneRequest = try WireRequest(
        GitCloneRequest(url: "https://me:s3cret-token@example.com/r.git", branch: "main", projectName: "R"),
    )
    await host.setResume(secretClone.taskID, TaskResume.plan(cloneRequest, descriptorCount: 0, caller: .app))
    let removal = await host.create(kind: .environment, owner: .environment)
    try await host.setResume(
        removal.taskID,
        TaskResume.plan(WireRequest(ToolchainRemoveRequest(id: "t1")), descriptorCount: 0, caller: .app),
    )
    let agentBuild = await host.create(kind: .build, owner: .build)
    await host.setResume(
        agentBuild.taskID,
        TaskResume.plan(build, descriptorCount: 0, caller: .worker(.agent, instance: "s1")),
    )
    // A transfer import, even of a file in the inbox: a project it placed
    // would be placed again.
    let transferImport = await host.create(kind: .environment, owner: .environment)
    try await host.setResume(
        transferImport.taskID,
        TaskResume.plan(
            WireRequest(TransferImportRequest(source: .inbox(path: "Hello.apeproj"))),
            descriptorCount: 0,
            caller: .app,
        ),
    )
    let stored = (try? String(
        contentsOf: directory.appendingPathComponent("\(secretClone.taskID.rawValue).json"),
        encoding: .utf8,
    )) ?? ""
    check(!stored.contains("s3cret") && stored.contains("credentials"), "a URL with credentials is never written into the record")
    // A token can ride in a query or a fragment as well as in the userinfo.
    let queryImport = await host.create(kind: .environment, owner: .environment)
    let queryRequest = try WireRequest(SDKImportRequest(source: .url("https://example.com/sdk.tar.xz?token=q-s3cret")))
    await host.setResume(queryImport.taskID, TaskResume.plan(queryRequest, descriptorCount: 0, caller: .app))
    let fragmentClone = await host.create(kind: .environment, owner: .environment)
    let fragmentRequest = try WireRequest(
        GitCloneRequest(url: "https://example.com/r.git#f-s3cret", branch: "main", projectName: "F"),
    )
    await host.setResume(fragmentClone.taskID, TaskResume.plan(fragmentRequest, descriptorCount: 0, caller: .app))
    for task in [queryImport, fragmentClone] {
        let text = (try? String(
            contentsOf: directory.appendingPathComponent("\(task.taskID.rawValue).json"),
            encoding: .utf8,
        )) ?? ""
        check(!text.contains("s3cret") && text.contains("credentials"), "a URL with a query or fragment is never written into the record")
    }

    // The next host: everything comes back and is picked up.
    host = TaskRegistry(directory: directory)
    let unfinished = await host.load()
    check(unfinished.count == 9, "the restarted host gets every unfinished task back")
    let resume = fake.resumer(host, refuse: true)
    for record in unfinished {
        let handled = await resume.resume(record)
        check(handled, "every planned task is handled by the resumer")
    }
    let working = await host.activeByKind
    check(working["build"] == 1, "the resumed build counts as work while it runs")
    let finished = try await waitForEnd(host, started)
    check(finished.state == .succeeded, "the resumed build finishes")
    check(finished.events.map(\.kind) == ["stage", "resumed", "log", "state"], "events go on after the restart, resumed first: \(finished.events.map(\.kind))")
    check(finished.events.map(\.seq.rawValue) == [1, 2, 3, 4], "the numbering has no gap across the restart")
    check(finished.events[2].payload?["line"]?.stringValue == "again", "the worker was told it is a resume")
    let sent = fake.lock.withLock { fake.seen }
    check(sent.count == 1 && sent.first?.taskID == started.taskID && sent.first?.resumed == true && sent.first?.operation == .buildStart,
          "only the build is sent again, under its own task ID, marked resumed")
    let plan = try await host.record(started.taskID)?.resume?.decode(TaskResume.Plan.self)
    check(plan?.resumes == 1, "the resume is counted in the record")

    let descriptorEnd = try await waitForEnd(host, fromDescriptor)
    check(descriptorEnd.state == .interrupted && descriptorEnd.events.last?.payload?["message"]?.stringValue?.isEmpty == false,
          "a task started with a descriptor ends interrupted, saying why")
    let cancelledEnd = try await waitForEnd(host, cancelled)
    check(cancelledEnd.state == .cancelled, "a cancel asked for before the restart stays cancelled")
    let secretEnd = try await waitForEnd(host, secretClone)
    check(secretEnd.state == .interrupted && secretEnd.events.last?.payload?["message"]?.stringValue?.contains("credentials") == true,
          "a clone with credentials in its URL ends interrupted")
    let removalEnd = try await waitForEnd(host, removal)
    check(removalEnd.state == .interrupted, "a toolchain removal is not resumed")
    for task in [queryImport, fragmentClone] {
        let end = try await waitForEnd(host, task)
        check(end.state == .interrupted && end.events.last?.payload?["message"]?.stringValue?.contains("credentials") == true,
              "a task whose URL has a query or fragment ends interrupted, saying why")
    }
    let agentEnd = try await waitForEnd(host, agentBuild)
    check(agentEnd.state == .interrupted && agentEnd.events.last?.payload?["message"]?.stringValue?.contains("agent session") == true,
          "an agent's build is not resumed: its session ended with the old host, so nothing would read it")
    let transferEnd = try await waitForEnd(host, transferImport)
    check(transferEnd.state == .interrupted && transferEnd.events.last?.payload?["message"]?.stringValue?.isEmpty == false,
          "a transfer import is never resumed, so a project is never placed twice")

    // A crash loop: each host dies before the task ends; the third gives up.
    fake.lock.withLock { fake.hang = true; fake.seen = [] }
    host = TaskRegistry(directory: directory)
    await host.load()
    let looping = await host.create(kind: .environment, owner: .environment)
    try await host.setResume(
        looping.taskID,
        TaskResume.plan(
            WireRequest(SDKImportRequest(source: .inbox(path: "x.sdk"))),
            descriptorCount: 0,
            caller: .app,
        ),
    )
    for restart in 1 ... TaskResume.maximumResumes + 1 {
        host = TaskRegistry(directory: directory)
        let records = await host.load()
        check(records.map(\.id) == [looping.taskID], "restart \(restart) hands the import back")
        _ = await fake.resumer(host).resume(records[0])
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    let loopEnd = try await host.attach(looping.taskID, as: .environmentAttach, afterSeq: .start, waitMilliseconds: 0)
    check(loopEnd.state == .interrupted && fake.lock.withLock { fake.seen.count } == TaskResume.maximumResumes,
          "a task resumed \(TaskResume.maximumResumes) times without ending is interrupted, not resumed again")
    check(loopEnd.events.map(\.kind) == ["resumed", "resumed", "state"] && loopEnd.events.map(\.seq.rawValue) == [1, 2, 3], "each resume is an event")
    let left = await host.activeCount
    check(left == 0, "nothing is left to keep the host up")

    // The host forgets a resumed build's earlier package.
    let artifacts = ArtifactRegistry(file: scratch.appendingPathComponent("resume-artifacts.json"))
    let buildID = TaskID.make()
    await artifacts.record(
        event: .object([
            "artifactID": .string(buildID.rawValue),
            "path": .string("/x.deb"),
            "digest": .string(String(repeating: "a", count: 64)),
        ]),
        buildID: buildID,
    )
    await artifacts.forget(buildID: buildID)
    let forgotten = await artifacts.artifact(buildID.rawValue)
    check(forgotten == nil, "a resumed build's earlier artifact is forgotten")
}

// MARK: - A load check keeps its answer with nobody attached

do {
    // The respring a load check triggers takes the app down; the task, its
    // events and the answer in its final state stay on the host's disk.
    let directory = scratch.appendingPathComponent("confirm-tasks")
    let first = TaskRegistry(directory: directory)
    await first.load()
    let check1 = await first.create(kind: .confirmLoaded, owner: .diagnostics)
    check(check1.attachOperation == .confirmLoadedAttach, "a load check is read with confirmLoadedAttach")
    let answer = ConfirmLoadedResponse(
        loaded: true,
        evidence: [LoadEvidence(kind: "log", passed: true, detail: "confirmed: Marker logged by pid 55.")],
    )
    await first.append(check1.taskID, kind: "stage", payload: .object(["stage": .string("listening")]))
    await first.append(check1.taskID, kind: "stage", payload: .object(["stage": .string("trigger")]))
    try await first.append(check1.taskID, kind: TaskEvent.stateKind, payload: .object([
        "state": .string("succeeded"),
        ConfirmLoadedResponse.stateMember: JSONValue(encoding: answer),
    ]))
    let counts = await first.activeByKind
    check(counts["confirmLoaded"] == nil, "a finished load check is no longer work")

    let second = TaskRegistry(directory: directory)
    let unfinished = await second.load()
    check(unfinished.isEmpty, "a finished load check is not resumed")
    let batch = try await second.attach(check1.taskID, as: .confirmLoadedAttach, afterSeq: .start, waitMilliseconds: 0)
    check(batch.finished && batch.state == .succeeded, "the load check reads as finished after a restart")
    let read = try batch.events.last.map { try ConfirmLoadedResponse.from(finalState: $0) }
    check(read == answer, "its answer is in the final state")
    await expectErrorAsync("a load check read as a build", code: .badRequest) {
        _ = try await second.attach(check1.taskID, as: .buildAttach, afterSeq: .start, waitMilliseconds: 0)
    }

    // One the host stopped under is interrupted, like any task nobody resumes.
    let running = await second.create(kind: .confirmLoaded, owner: .diagnostics)
    let third = TaskRegistry(directory: directory)
    for record in await third.load() {
        await third.interrupt(record.id)
    }
    let after = try await third.attach(running.taskID, as: .confirmLoadedAttach, afterSeq: .start, waitMilliseconds: 0)
    check(after.state == .interrupted, "a load check the host stopped under ends interrupted")
}

// MARK: - Caller policy

do {
    check(CallerPolicy.allows(.app, .protectedEditCommit), "the app may edit")
    check(CallerPolicy.allows(.worker(.agent, instance: "s"), .buildStart), "the agent may build")
    check(CallerPolicy.allows(.worker(.agent, instance: "s"), .approvalDigestState), "the agent may read the ledger")
    check(CallerPolicy.allows(.worker(.agent, instance: "s"), .toolHostCall), "the agent may call tools")
    check(CallerPolicy.allows(.worker(.agent, instance: "s"), .confirmLoaded) && CallerPolicy.allows(.worker(.agent, instance: "s"), .confirmLoadedAttach), "the agent starts and reads a load check")
    // Accounts are the app's alone: a session's agent never starts, answers
    // or reads a sign-in, and never lists or forgets an account.
    for operation: AppOperation in [.protectedEditOpen, .protectedEditCommit, .ptyOpen, .ptyAttach, .agentApprove, .agentSteer, .agentCompact,
                                    .agentRegenerate, .agentModelSwitch,
                                    .toolchainRemove, .sdkRemove, .environmentCancel,
                                    .agentAccountList, .agentAPIConfiguration, .agentModelList, .agentModelActivate, .agentSignIn, .agentSignInRespond, .agentSignInCancel, .agentSignOut,
                                    .agentCredentialImport, .transferExport, .transferInspect, .transferImport]
    {
        check(!CallerPolicy.allows(.worker(.agent, instance: "s"), operation), "the agent may not call \(operation.rawValue)")
    }
    // The device's toolchains and SDKs: listed, set up, imported, tested
    // again, and the tasks it started read back (AgentEnvironmentRules and
    // EnvironmentHandler narrow each one). Removal stays the app's.
    for operation: AppOperation in [.toolchainStatus, .toolchainCatalog, .toolchainSetup, .toolchainSelfTest, .sdkList, .sdkImport, .environmentAttach] {
        check(CallerPolicy.allows(.worker(.agent, instance: "s"), operation), "the agent reaches the device's toolchains and SDKs (\(operation.rawValue))")
    }
    let agentEnvironmentOperations = CallerPolicy.agentOperations.filter {
        $0.domain == .toolchain || $0.domain == .sdk || $0.domain == .environment
    }
    check(
        agentEnvironmentOperations == [.toolchainStatus, .toolchainCatalog, .toolchainSetup, .toolchainSelfTest, .sdkList, .sdkImport, .environmentAttach],
        "and exactly those of the environment domains: \(agentEnvironmentOperations.map(\.rawValue).sorted())",
    )
    // The project's other conversations: AgentHandler narrows each one.
    for operation: AppOperation in [.agentOpen, .agentPrompt, .agentList, .agentAttach, .agentAbort, .agentClose] {
        check(CallerPolicy.allows(.worker(.agent, instance: "s"), operation), "the agent reaches its project's conversations (\(operation.rawValue))")
        check(!CallerPolicy.allows(.worker(.environment, instance: nil), operation), "the environment worker does not (\(operation.rawValue))")
    }
    let environment = Caller.worker(.environment, instance: nil)
    check(CallerPolicy.allows(environment, .installPackage) && CallerPolicy.allows(environment, .removePackage), "the environment worker installs its toolchain package")
    check(!CallerPolicy.allows(environment, .protectedEditCommit) && !CallerPolicy.allows(environment, .ptyOpen), "and nothing of the app's")
    // The diagnostics worker asks for a protected crash report by id and for
    // the respring confirmLoaded triggers, and nothing else.
    let diagnostics = Caller.worker(.diagnostics, instance: nil)
    for operation in AppOperation.allCases {
        let expected = operation == .crashOpen || operation == .respring
        check(CallerPolicy.allows(diagnostics, operation) == expected, "diagnostics calls only crashOpen and respring (\(operation.rawValue))")
    }
    for role: WorkerRole in [.build, .logReader] {
        for operation in AppOperation.allCases {
            check(!CallerPolicy.allows(.worker(role, instance: nil), operation), "\(role.rawValue) calls nothing (\(operation.rawValue))")
        }
    }
    // Only an agent worker reaches agentRunCode.
    check(CallerPolicy.allows(.worker(.agent, instance: "s"), .agentRunCode), "the agent runs code through the host")
    check(!CallerPolicy.allows(environment, .agentRunCode), "the environment worker does not")
}

// MARK: - An agent's conversations stay in its project, under its mode

do {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("conversation-tasks"))
    await registry.load()
    let table = AgentSessionTable()
    let project = ResolvedProject(id: "p-conversations", name: "Conversations", path: scratchPath + "/Conversations")
    let other = ResolvedProject(id: "p-other", name: "Other", path: scratchPath + "/Other")
    func session(
        _ id: String,
        in project: ResolvedProject = project,
        mode: ApprovalMode = .confirm,
        parent: String? = nil,
        depth: Int = 0,
    ) async -> AgentSessionTable.Entry {
        let entry = await AgentSessionTable.Entry(
            sessionID: id,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: id),
            project: project,
            mode: mode,
            createdAt: Date(),
            parentSessionID: parent,
            depth: depth,
        )
        await table.add(entry)
        return entry
    }
    let opener = await session("c-opener", mode: .confirm)

    // Open: always the opener's project and current mode, with a prompt;
    // nothing of its own beyond prompt, title, provider, model, effort and tier.
    let asked = AgentOpenRequest(
        projectID: "p-other",
        projectName: "Other",
        temporaryID: UUID().uuidString,
        sessionID: UUID().uuidString,
        provider: .anthropic,
        model: "claude-sonnet-5-5",
        approvalMode: .relaxed,
        reasoningEffort: .high,
        serviceTier: .priority,
        contextWindow: 256_000,
        prompt: "Write the README",
        closeWhenFinished: true,
        title: "  Docs\nsecond line",
    )
    let child = try AgentConversationRules.childOpen(asked, opener: opener, target: project)
    check(child.projectID == project.id && child.projectName == project.name, "an opened conversation is in the project the host resolved, not the one the request spelled")
    check(child.temporaryID == nil && child.sessionID == nil && child.closeWhenFinished == nil, "and is new, in no temporary workspace, and not headless")
    check(child.approvalMode == .confirm, "and runs under the opener's mode, never a laxer one it asked for")
    check(
        child.provider == .anthropic && child.model == "claude-sonnet-5-5" && child.reasoningEffort == .high
            && child.serviceTier == .priority && child.contextWindow == 256_000,
        "provider, model, effort, tier and context window go as sent",
    )
    check(child.prompt == "Write the README" && child.title == "Docs", "the prompt goes as sent, the title on one trimmed line")
    let relaxed = await session("c-relaxed", mode: .relaxed)
    let relaxedChild = try AgentConversationRules.childOpen(
        AgentOpenRequest(approvalMode: .confirm, prompt: "go"),
        opener: relaxed,
        target: project,
    )
    check(relaxedChild.approvalMode == .relaxed, "a Relaxed opener's conversation is Relaxed")
    expectError("an opened conversation needs a prompt", code: .badRequest) {
        _ = try AgentConversationRules.childOpen(AgentOpenRequest(prompt: "  \n "), opener: opener, target: project)
    }
    // Another project: General Chat included, never a temporary one.
    let crossChild = try AgentConversationRules.childOpen(AgentOpenRequest(prompt: "Import the repository"), opener: opener, target: other)
    check(crossChild.projectID == other.id && crossChild.projectName == other.name && crossChild.approvalMode == .confirm, "a conversation opens in another project under the opener's mode")
    let temporaryProject = ResolvedProject(id: "temporary:\(UUID().uuidString)", name: "t", path: scratchPath)
    let general = await session("c-general", in: temporaryProject)
    let fromGeneral = try AgentConversationRules.childOpen(AgentOpenRequest(prompt: "Import the repository"), opener: general, target: project)
    check(fromGeneral.projectID == project.id, "General Chat opens a conversation in a project")
    expectError("but never in a temporary chat", code: .denied) {
        _ = try AgentConversationRules.childOpen(AgentOpenRequest(prompt: "go"), opener: general, target: temporaryProject)
    }
    expectError("nor in another temporary chat from a project", code: .denied) {
        _ = try AgentConversationRules.childOpen(AgentOpenRequest(prompt: "go"), opener: opener, target: temporaryProject)
    }
    let deep = await session("c-deep", parent: "c-opener", depth: AgentConversations.maximumDepth)
    expectError("a chain of openings stops at the maximum depth", code: .denied) {
        _ = try AgentConversationRules.childOpen(AgentOpenRequest(prompt: "go"), opener: deep, target: project)
    }
    expectError("in another project too", code: .denied) {
        _ = try AgentConversationRules.childOpen(AgentOpenRequest(prompt: "go"), opener: deep, target: other)
    }
    let middle = await session("c-middle", parent: "c-opener", depth: AgentConversations.maximumDepth - 1)
    check((try? AgentConversationRules.childOpen(AgentOpenRequest(prompt: "go"), opener: middle, target: project)) != nil, "one short of the depth still opens")

    // The approval an open or a message in another project spends: the
    // user's of exactly that call.
    func otherProjectAsk(_ tool: String, action: String, projectID: String, sessionID: String? = nil, text: String) -> JSONValue {
        var detail: [String: JSONValue] = [
            "action": .string(action), "projectID": .string(projectID), "projectName": .string("Other"), "text": .string(text),
        ]
        if let sessionID {
            detail["sessionID"] = .string(sessionID)
        }
        return .object(["tool": .string(tool), "detail": .object([AgentConversationRules.otherProjectDetail: .object(detail)])])
    }
    let openAsk = otherProjectAsk("apelin_conversation_create", action: "create", projectID: other.id, text: "Import the repository")
    check(AgentConversationRules.coversOpen(crossChild, target: other, asked: openAsk), "an approval of this open in this project covers it")
    let third = ResolvedProject(id: "p-third", name: "Third", path: scratchPath + "/Third")
    check(!AgentConversationRules.coversOpen(crossChild, target: third, asked: openAsk), "not one in another project")
    check(
        !AgentConversationRules.coversOpen(AgentOpenRequest(prompt: "Delete everything"), target: other, asked: openAsk),
        "nor another prompt",
    )
    check(
        !AgentConversationRules.coversOpen(crossChild, target: other, asked: otherProjectAsk("apelin_conversation_send", action: "send", projectID: other.id, text: "Import the repository")),
        "nor an approval of another tool",
    )

    // The cap counts running agent-opened sessions and held places.
    let capped = ResolvedProject(id: "p-capped", name: "Capped", path: scratchPath + "/Capped")
    var children: [AgentSessionTable.Entry] = []
    for index in 0 ..< AgentConversations.maximumOpenChildren - 1 {
        await children.append(session("c-child-\(index)", in: capped, parent: "c-opener", depth: 1))
    }
    _ = await session("c-app-session", in: capped)
    let belowCap = await table.reserveChild(project: capped.id, registry: registry)
    check(belowCap, "a place is free below the cap")
    let pastCap = await table.reserveChild(project: capped.id, registry: registry)
    check(!pastCap, "a held place counts toward the cap")
    let otherProject = await table.reserveChild(project: project.id, registry: registry)
    check(otherProject, "another project has its own places")
    await table.releaseChild(project: project.id)
    await table.add(
        AgentSessionTable.Entry(
            sessionID: "c-child-last",
            task: registry.create(kind: .agent, owner: .agent, ownerKey: "c-child-last"),
            project: capped,
            mode: .confirm,
            createdAt: Date(),
            parentSessionID: "c-opener",
            depth: 1,
        ),
        releasingReservation: true,
    )
    let afterOpen = await table.reserveChild(project: capped.id, registry: registry)
    check(!afterOpen, "an open session takes the place it held")
    await registry.finish(children[0].task.taskID, .succeeded)
    let afterEnd = await table.reserveChild(project: capped.id, registry: registry)
    check(afterEnd, "one that ended frees its place")
    await table.releaseChild(project: capped.id)

    // Prompt: another session of the same project, as a message from the
    // sender, with nothing else of the sender's.
    let target = await session("c-target")
    let sent = AgentPromptRequest(
        sessionID: "c-target",
        text: "Review Tweak.x",
        messageID: UUID(),
        provider: .openAI,
        model: "gpt",
        reasoningEffort: .max,
        serviceTier: .ultrafast,
        approvalMode: .relaxed,
        fromSessionID: "c-forged",
    )
    let rewritten = try AgentConversationRules.childPrompt(sent, sender: opener, target: target, descriptorCount: 0)
    check(rewritten.sessionID == "c-target" && rewritten.text == "Review Tweak.x", "the message goes to the target as typed")
    check(rewritten.fromSessionID == "c-opener", "and is marked with the sender the host knows, not the one it claimed")
    check(
        rewritten.approvalMode == nil && rewritten.provider == nil && rewritten.model == nil
            && rewritten.reasoningEffort == nil && rewritten.serviceTier == nil && rewritten.attachments == nil
            && rewritten.messageID == nil,
        "and carries no mode, provider, model, effort, tier, files or message id of the sender's",
    )
    expectError("a message carries no descriptors", code: .badRequest) {
        _ = try AgentConversationRules.childPrompt(sent, sender: opener, target: target, descriptorCount: 1)
    }
    let attached = AgentPromptRequest(
        sessionID: "c-target",
        text: "x",
        attachments: [AgentInputAttachment(descriptor: DescriptorSlot(index: 0), name: "a", mimeType: "text/plain")],
    )
    expectError("nor attachments", code: .badRequest) {
        _ = try AgentConversationRules.childPrompt(attached, sender: opener, target: target, descriptorCount: 0)
    }
    expectError("a conversation does not message itself", code: .badRequest) {
        _ = try AgentConversationRules.childPrompt(
            AgentPromptRequest(sessionID: "c-opener", text: "x"),
            sender: opener,
            target: opener,
            descriptorCount: 0,
        )
    }
    let elsewhere = await session("c-elsewhere", in: other)
    let toElsewhere = try AgentConversationRules.childPrompt(
        AgentPromptRequest(sessionID: "c-elsewhere", text: "Build it"),
        sender: opener,
        target: elsewhere,
        descriptorCount: 0,
    )
    check(toElsewhere.fromSessionID == "c-opener", "a message goes to another project's conversation the same way")
    let sendAsk = otherProjectAsk("apelin_conversation_send", action: "send", projectID: other.id, sessionID: "c-elsewhere", text: "Build it")
    check(AgentConversationRules.coversSend(toElsewhere, target: elsewhere, asked: sendAsk), "an approval of this message to this conversation covers it")
    check(
        !AgentConversationRules.coversSend(AgentPromptRequest(sessionID: "c-elsewhere", text: "Push it"), target: elsewhere, asked: sendAsk),
        "not another text",
    )
    let elsewhereToo = await session("c-elsewhere-too", in: other)
    check(!AgentConversationRules.coversSend(toElsewhere, target: elsewhereToo, asked: sendAsk), "nor another conversation")
    let temporaryTarget = await session("c-temporary-target", in: temporaryProject)
    expectError("nor a temporary chat, which is the user's alone", code: .denied) {
        _ = try AgentConversationRules.childPrompt(
            AgentPromptRequest(sessionID: "c-temporary-target", text: "x"),
            sender: opener,
            target: temporaryTarget,
            descriptorCount: 0,
        )
    }
    expectError("nor one the host does not know", code: .notFound) {
        _ = try AgentConversationRules.childPrompt(
            AgentPromptRequest(sessionID: "c-gone", text: "x"),
            sender: opener,
            target: nil,
            descriptorCount: 0,
        )
    }
    expectError("nor an empty message", code: .badRequest) {
        _ = try AgentConversationRules.childPrompt(
            AgentPromptRequest(sessionID: "c-target", text: " "),
            sender: opener,
            target: target,
            descriptorCount: 0,
        )
    }
    let fromApp = AgentConversationRules.appPrompt(sent)
    check(fromApp.fromSessionID == nil && fromApp.approvalMode == .relaxed && fromApp.model == "gpt", "the app's prompt keeps everything but a forged sender")

    // Abort and close: only the conversations the caller opened.
    let mine = await session("c-mine", parent: "c-opener", depth: 1)
    check((try? AgentConversationRules.mayStop(mine, caller: opener, sessionID: "c-mine")) != nil, "an agent stops a conversation it opened")
    expectError("not one the app opened", code: .denied) {
        try AgentConversationRules.mayStop(target, caller: opener, sessionID: "c-target")
    }
    expectError("nor one a sibling opened", code: .denied) {
        try AgentConversationRules.mayStop(mine, caller: target, sessionID: "c-mine")
    }
    expectError("nor its opener", code: .denied) {
        try AgentConversationRules.mayStop(opener, caller: mine, sessionID: "c-opener")
    }

    // Attach and list: the project's sessions only.
    let named = await table.entry(task: target.task.taskID)
    check(named?.sessionID == "c-target", "a task names its session")
    check((try? AgentConversationRules.mayRead(target.task.taskID, target: target, caller: opener)) != nil, "an agent reads a conversation of its project")
    expectError("not one of another project the user has not let it reach", code: .denied) {
        try AgentConversationRules.mayRead(elsewhere.task.taskID, target: elsewhere, caller: opener)
    }
    check(
        (try? AgentConversationRules.mayRead(elsewhere.task.taskID, target: elsewhere, caller: opener, reachable: true)) != nil,
        "one it may reach, it reads",
    )
    check(
        (try? AgentConversationRules.mayRead(elsewhere.task.taskID, target: elsewhere, caller: relaxed)) != nil,
        "and in Relaxed mode every project's",
    )
    expectError("never a temporary chat's", code: .denied) {
        try AgentConversationRules.mayRead(temporaryTarget.task.taskID, target: temporaryTarget, caller: relaxed, reachable: true)
    }
    let build = await registry.create(kind: .build, owner: .build, ownerKey: nil)
    let noConversation = await table.entry(task: build.taskID)
    expectError("nor a task that is no conversation", code: .denied) {
        try AgentConversationRules.mayRead(build.taskID, target: noConversation, caller: opener)
    }
    let listed = await table.summaries(registry: registry, projectID: project.id)
    check(!listed.isEmpty && listed.allSatisfy { $0.projectID == project.id }, "an agent's list names only its project's sessions")
    check(listed.first { $0.sessionID == "c-mine" }?.parentSessionID == "c-opener", "and says who opened each")
    check(listed.first { $0.sessionID == "c-target" }?.parentSessionID == nil, "the app's have no opener")
    check(listed.allSatisfy { $0.projectName == project.name }, "and names each one's project folder")
    let generalListed = await table.summaries(registry: registry, projectID: temporaryProject.id)
    check(generalListed.allSatisfy { $0.projectName == nil }, "a temporary chat names none")
    let everything = await table.summaries(registry: registry)
    check(everything.contains { $0.projectID == other.id }, "the app's list names every project's")
    await table.setTitle("Docs pass", session: "c-mine")
    let retitled = await table.summaries(registry: registry, projectID: project.id)
    check(retitled.first { $0.sessionID == "c-mine" }?.title == "Docs pass", "a session is listed by the title its agent gave it")

    // conversationOpened on the opener's task.
    let opened = AgentConversationRules.openedEvent(
        sessionID: "c-mine",
        task: mine.task,
        title: "Docs",
        prompt: "Write the README",
    )
    check(
        opened["sessionID"]?.stringValue == "c-mine" && opened["task"]?["taskID"]?.stringValue == mine.task.taskID.rawValue
            && opened["task"]?["kind"]?.stringValue == "agent" && opened["title"]?.stringValue == "Docs"
            && opened["prompt"]?.stringValue == "Write the README",
        "conversationOpened names the session, its task, its title and its prompt",
    )
    check(AgentConversationRules.openedEvent(sessionID: "s", task: mine.task, title: nil, prompt: "p")["title"] == nil, "and leaves out a title it was not given")
    let openedElsewhere = AgentConversationRules.openedEvent(sessionID: "s", task: mine.task, title: nil, prompt: "p", project: other)
    check(
        openedElsewhere["projectID"]?.stringValue == other.id && openedElsewhere["projectName"]?.stringValue == other.name,
        "and names the project it opened in, which the app adopts it into",
    )
    check(AgentConversationRules.title(String(repeating: "x", count: 200))?.count == AgentConversationRules.maximumTitleLength, "a title is bounded")
    check(AgentConversationRules.title(" \n ") == nil, "and an empty one is none")
}

// MARK: - Protected edit

do {
    let root = scratchPath + "/root"
    let home = root + "/var/mobile"
    try FileManager.default.createDirectory(
        atPath: home + "/Documents/wiki.qaq.apelin",
        withIntermediateDirectories: true,
    )
    write(root + "/etc/hosts", "127.0.0.1 localhost\n")
    write(root + "/etc/run.sh", "#!/bin/sh\n", mode: 0o755)
    FileManager.default.createFile(atPath: root + "/etc/macho", contents: Data([0xCF, 0xFA, 0xED, 0xFE, 1, 2, 3, 4]))
    write(root + "/etc/linked", "a\n")
    link(root + "/etc/linked", root + "/etc/linked2")
    symlink(root + "/etc/hosts", root + "/etc/hosts-link")
    write(root + "/var/lib/dpkg/status", "Package: x\n")
    write(root + "/Library/LaunchDaemons/com.example.plist", "<plist/>\n")
    write(scratchPath + "/outside", "x\n")

    let hosts = try ProtectedEditPolicy.evaluate(root + "/etc/hosts", installRoot: root)
    check(!hosts.needsConfirmation && hosts.version.sha256 != nil, "a regular file is editable")
    expectError("a symlink", code: .denied) { _ = try ProtectedEditPolicy.evaluate(root + "/etc/hosts-link", installRoot: root) }
    expectError("an executable", code: .denied) { _ = try ProtectedEditPolicy.evaluate(root + "/etc/run.sh", installRoot: root) }
    expectError("a Mach-O", code: .denied) { _ = try ProtectedEditPolicy.evaluate(root + "/etc/macho", installRoot: root) }
    expectError("a hard-linked file", code: .denied) { _ = try ProtectedEditPolicy.evaluate(root + "/etc/linked", installRoot: root) }
    expectError("the dpkg database", code: .denied) { _ = try ProtectedEditPolicy.evaluate(root + "/var/lib/dpkg/status", installRoot: root) }
    expectError("outside the install root", code: .denied) { _ = try ProtectedEditPolicy.evaluate(scratchPath + "/outside", installRoot: root) }
    expectError("a .. escape", code: .denied) { _ = try ProtectedEditPolicy.evaluate(root + "/etc/../../outside", installRoot: root) }
    expectError("a folder", code: .denied) { _ = try ProtectedEditPolicy.evaluate(root + "/etc", installRoot: root) }
    let daemon = try ProtectedEditPolicy.evaluate(root + "/Library/LaunchDaemons/com.example.plist", installRoot: root)
    check(daemon.needsConfirmation, "a LaunchDaemons plist needs confirmation")

    let editor = ProtectedEditor(installRoot: root, backups: BackupStore(home: home))
    chmod(root + "/etc/hosts", 0o640)
    let (opened, descriptor) = try await editor.open(ProtectedEditOpenRequest(path: root + "/etc/hosts"))
    var firstBytes = [UInt8](repeating: 0, count: 9)
    check(pread(descriptor.rawValue, &firstBytes, 9, 0) == 9 && String(decoding: firstBytes, as: UTF8.self) == "127.0.0.1", "the open hands back the contents")
    let commit = ProtectedEditCommitRequest(
        grantID: opened.grantID,
        contents: nil,
        contentsBase64: Data("10.0.0.1 router\n".utf8).base64EncodedString(),
        expectedVersion: opened.version,
    )
    let saved = try await editor.commit(commit, descriptors: [])
    check(String(data: FileManager.default.contents(atPath: root + "/etc/hosts")!, encoding: .utf8) == "10.0.0.1 router\n", "the commit replaces the contents")
    var after = stat()
    stat(root + "/etc/hosts", &after)
    check(after.st_mode & 0o7777 == 0o640, "the mode is kept")
    check(saved.version.inode != opened.version.inode, "the replace is a new inode (atomic rename)")
    let backup = home + "/Documents/wiki.qaq.apelin/backups/" + saved.backupID
    check(String(data: FileManager.default.contents(atPath: backup) ?? Data(), encoding: .utf8) == "127.0.0.1 localhost\n", "the old contents are backed up first")
    await expectErrorAsync("a grant is spent once", code: .notFound) { _ = try await editor.commit(commit, descriptors: []) }

    let (stale, _) = try await editor.open(ProtectedEditOpenRequest(path: root + "/etc/hosts"))
    usleep(10000)
    write(root + "/etc/hosts", "changed elsewhere\n", mode: 0o640)
    await expectErrorAsync("a file changed after the open is not overwritten", code: .conflict) {
        _ = try await editor.commit(
            ProtectedEditCommitRequest(
                grantID: stale.grantID,
                contents: nil,
                contentsBase64: "eA==",
                expectedVersion: stale.version,
            ),
            descriptors: [],
        )
    }
    check(String(data: FileManager.default.contents(atPath: root + "/etc/hosts")!, encoding: .utf8) == "changed elsewhere\n", "the outside change survives")

    let (plist, _) = try await editor.open(
        ProtectedEditOpenRequest(path: root + "/Library/LaunchDaemons/com.example.plist"),
    )
    check(plist.needsConfirmation, "the open says the plist needs confirmation")
    await expectErrorAsync("an unconfirmed LaunchDaemons save", code: .denied) {
        _ = try await editor.commit(
            ProtectedEditCommitRequest(
                grantID: plist.grantID,
                contents: nil,
                contentsBase64: "eA==",
                expectedVersion: plist.version,
            ),
            descriptors: [],
        )
    }
    let (plistAgain, _) = try await editor.open(
        ProtectedEditOpenRequest(path: root + "/Library/LaunchDaemons/com.example.plist"),
    )
    _ = try await editor.commit(
        ProtectedEditCommitRequest(
            grantID: plistAgain.grantID,
            contents: nil,
            contentsBase64: "eA==",
            expectedVersion: plistAgain.version,
            confirmed: true,
        ),
        descriptors: [],
    )
    check(FileManager.default.contents(atPath: root + "/Library/LaunchDaemons/com.example.plist") == Data("x".utf8), "a confirmed LaunchDaemons save goes through")

    // Backups refuse a Documents swapped for a link.
    let trap = scratchPath + "/trap-home"
    try FileManager.default.createDirectory(atPath: trap, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        atPath: scratchPath + "/elsewhere/wiki.qaq.apelin",
        withIntermediateDirectories: true,
    )
    symlink(scratchPath + "/elsewhere", trap + "/Documents")
    expectError("a backup through a linked Documents", code: .unavailable) { _ = try BackupStore(home: trap).save(path: root + "/etc/hosts") }

    // fileRead scopes.
    let folder = DataFolder(home: home)
    let scopes = FileScopes(installRoot: root, dataFolder: folder)
    write(home + "/Documents/wiki.qaq.apelin/Projects/Hello/apelin-project.json", "{\"projectID\": \"p-1\"}")
    write(home + "/Documents/wiki.qaq.apelin/Projects/Hello/Tweak.x", "%hook\n")
    symlink(scratchPath + "/outside", home + "/Documents/wiki.qaq.apelin/Projects/Hello/escape")
    if case let .directory(path) = try scopes.resolve("p-1", caller: .worker(.agent, instance: "s")) {
        let (file, resolved) = try FileScopes.open("Tweak.x", inside: path)
        check(resolved.hasSuffix("/Projects/Hello/Tweak.x") && file.rawValue >= 0, "a project ID scope reads its file")
        expectError("a link out of the scope", code: .denied) { _ = try FileScopes.open("escape", inside: path) }
        expectError("a .. path", code: .badRequest) { _ = try FileScopes.open("../Hello/Tweak.x", inside: path) }
    } else {
        check(false, "the project ID resolves")
    }
    expectError("a grant scope for a worker", code: .denied) { _ = try scopes.resolve("grant:x", caller: .worker(.agent, instance: "s")) }
}

// MARK: - Managed packages

func record(
    _ id: String = UUID().uuidString.lowercased(),
    package: String,
    version: String,
    status: InstallationRecord.Status = .installed,
    created: Date = Date(),
) -> InstallationRecord {
    InstallationRecord(
        installationID: id,
        origin: .build,
        artifactID: "a",
        artifactDigest: String(repeating: "0", count: 64),
        projectID: "p",
        buildID: "b",
        packageID: package,
        version: version,
        packagingDigest: nil,
        transactionID: UUID().uuidString.lowercased(),
        taskID: nil,
        status: status,
        createdAt: created,
        updatedAt: created,
        followedSeq: 0,
        receipt: status == .installed ? .init(
            state: "succeeded",
            exitStatus: 0,
            packageID: package,
            version: version,
            failure: nil,
            failureText: nil,
            finishedAt: created,
        ) : nil,
        removalTransactionID: nil,
        removalTaskID: nil,
        removalReceipt: nil,
    )
}

do {
    let installed = DpkgStatusDatabase.parse("""
    Package: com.example.tweak
    Status: install ok installed
    Version: 1.0

    Package: bash
    Status: install ok installed
    Priority: required
    Version: 5.2

    Package: com.example.other
    Status: install ok installed
    Version: 2.0

    Package: com.example.gone
    Status: deinstall ok config-files
    Version: 1.0

    Package: com.example.essential
    Essential: yes
    Status: install ok installed
    Version: 1
    """)
    check(installed.count == 5 && installed["bash"]?.priority == "required" && installed["com.example.gone"]?.isInstalled == false, "the dpkg status file parses")

    for reserved in ["wiki.qaq.apelin", "wiki.qaq.apelin.dev.tweak", "wiki.qaq.irisin", "dpkg", "apt", "firmware", "gsc.ipad", "cy+cpu.arm64", "com.example.essential"] {
        expectError("installing \(reserved)", code: .denied) { try ManagedPackagePolicy.checkInstall(packageID: reserved, installed: installed, records: []) }
    }
    expectError("a bad package ID", code: .badRequest) { try ManagedPackagePolicy.checkInstall(packageID: "Bad ID", installed: installed, records: []) }
    expectError("overwriting a package Apelin did not install", code: .conflict) {
        try ManagedPackagePolicy.checkInstall(packageID: "com.example.other", installed: installed, records: [])
    }
    try ManagedPackagePolicy.checkInstall(packageID: "com.example.new", installed: installed, records: [])
    try ManagedPackagePolicy.checkInstall(packageID: "com.example.gone", installed: installed, records: [])
    let ours = record(package: "com.example.tweak", version: "1.0")
    try ManagedPackagePolicy.checkInstall(packageID: "com.example.tweak", installed: installed, records: [ours])
    expectError("upgrading our package after an outside replacement", code: .conflict) {
        try ManagedPackagePolicy.checkInstall(
            packageID: "com.example.tweak",
            installed: installed,
            records: [record(package: "com.example.tweak", version: "0.9")],
        )
    }

    try ManagedPackagePolicy.checkRemoval(ours, installed: installed, records: [ours])
    expectError("removing with no record", code: .notFound) { try ManagedPackagePolicy.checkRemoval(nil, installed: installed, records: []) }
    let replaced = record(package: "com.example.tweak", version: "0.9")
    expectError("removing a package replaced from outside", code: .conflict) { try ManagedPackagePolicy.checkRemoval(replaced, installed: installed, records: [replaced]) }
    let gone = record(package: "com.example.gone", version: "1.0")
    expectError("removing a package no longer installed", code: .conflict) { try ManagedPackagePolicy.checkRemoval(gone, installed: installed, records: [gone]) }
    let failed = record(package: "com.example.tweak", version: "1.0", status: .failed)
    expectError("removing a failed install", code: .denied) { try ManagedPackagePolicy.checkRemoval(failed, installed: installed, records: [failed]) }
    let core = record(package: "bash", version: "5.2")
    expectError("removing a core package even with a record", code: .denied) { try ManagedPackagePolicy.checkRemoval(core, installed: installed, records: [core]) }
    let older = record(package: "com.example.tweak", version: "1.0", created: Date(timeIntervalSinceNow: -60))
    expectError("removing through a superseded record", code: .conflict) { try ManagedPackagePolicy.checkRemoval(older, installed: installed, records: [older, ours]) }
}

// MARK: - Deb control

do {
    let deb = scratchPath + "/peek.deb"
    makeDeb(at: deb, package: "com.example.peek", version: "1.2-3")
    let descriptor = open(deb, O_RDONLY)
    let control = try DebControlPeek.read(descriptor: descriptor)
    close(descriptor)
    check(control == .init(packageID: "com.example.peek", version: "1.2-3", architecture: "iphoneos-arm64e"), "the control file is read from a gzip member")
    write(scratchPath + "/not.deb", "hello")
    let other = open(scratchPath + "/not.deb", O_RDONLY)
    defer { close(other) }
    var refused = false
    do { _ = try DebControlPeek.read(descriptor: other) } catch DebControlPeek.Failure.notADebian { refused = true }
    check(refused, "a file that is not ar is not a deb")
    // dpkg-deb's own output (GNU tar, gzip): the console smoke fixture.
    if let repository = ProcessInfo.processInfo.environment["APELIN_REPOSITORY"] {
        let fixture = open(repository + "/Documents/Console/fixtures/apelin-smoke_1.0_all.deb", O_RDONLY)
        defer { close(fixture) }
        let smoke = try? DebControlPeek.read(descriptor: fixture)
        check(smoke == .init(packageID: "com.example.apelin-smoke", version: "1.0", architecture: "all"), "dpkg-deb's archive reads too")
    }
}

// MARK: - Approval ledger

do {
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("approvals"))
    let template = "sha256:" + String(repeating: "a", count: 64)
    let changed = "sha256:" + String(repeating: "b", count: 64)
    try await ledger.recordTemplate(template, kind: .build, project: "p-1")
    try await ledger.recordTemplate("sha256:" + String(repeating: "c", count: 64), kind: .build, project: "p-1")
    let base = try await ledger.state(of: template, kind: .build, project: "p-1")
    check(base.baseline == .matchesTemplate && base.templateDigest == template, "the template digest is the baseline, and the first record wins")
    let before = try await ledger.state(of: changed, kind: .build, project: "p-1")
    check(before.baseline == .changed, "a changed description asks")
    try await ledger.recordApproval(changed, kind: .build, project: "p-1")
    let reloaded = ApprovalLedger(directory: scratch.appendingPathComponent("approvals"))
    let afterApproval = try await reloaded.state(of: changed, kind: .build, project: "p-1")
    check(afterApproval.baseline == .approved && afterApproval.lastApprovedDigest == changed, "an approval is kept on disk")
    let packaging = try await reloaded.state(of: changed, kind: .packaging, project: "p-1")
    check(packaging.baseline == .changed, "approvals are per kind")
    let mode = await reloaded.mode(session: "unknown")
    check(mode == .confirm, "an unknown agent session is held to Confirm")
    await reloaded.allowRemoval(installationID: "i", session: "s")
    let firstTake = await reloaded.takeRemoval(installationID: "i", session: "s")
    let secondTake = await reloaded.takeRemoval(installationID: "i", session: "s")
    check(firstTake && !secondTake, "a removal approval is spent once")
    await expectErrorAsync("a project ID with a slash", code: .badRequest) { _ = try await reloaded.state(of: changed, kind: .build, project: "../x") }
}

// MARK: - Agent notices (AgentNoticeChecks.swift)

await agentNoticeChecks()

// MARK: - shell_run as root (RootRunChecks.swift)

await rootRunChecks(scratch: scratch, scratchPath: scratchPath)

// MARK: - Install bridge against a fake irisind

final class FakeIrisin: InstallService, @unchecked Sendable {
    struct Transaction {
        var kind: String
        var package: String?
        var version: String?
        var digest: String?
        var events: [InstallTransactionEvent] = []
        var polls = 0
    }

    let root: String
    let lock = NSLock()
    var transactions: [UUID: Transaction] = [:]
    var submissions = 0
    var duplicates = 0
    var installedVersions: [String: String] = [:]
    var failNext = false
    /// The end-to-end toolchain test lays a package's files down when it is
    /// installed (from the submitted descriptor) and takes them away when it
    /// is removed, as irisind would.
    var onInstall: ((Int32) throws -> Void)?
    var onRemove: ((String) -> Void)?

    init(root: String) {
        self.root = root
    }

    func serviceInfo() async throws -> InstallServiceInfo {
        InstallServiceInfo(externalVersion: 1, capabilities: InstallServiceRequirement.capabilities, installRoot: root)
    }

    func submitInstall(transaction: UUID, descriptor: Int32, sha256: String) async throws -> InstallTransactionStatus {
        let control = try? DebControlPeek.read(descriptor: descriptor)
        let actual = try ProtectedEditPolicy.sha256(descriptor: descriptor)
        var unpacked = true
        if let onInstall, actual == "sha256:" + sha256, lock.withLock({ transactions[transaction] == nil && !failNext }) {
            do { try onInstall(descriptor) } catch { unpacked = false }
        }
        return lock.withLock {
            submissions += 1
            if transactions[transaction] != nil {
                duplicates += 1
                return status(transaction, duplicate: true)
            }
            var events = [InstallTransactionEvent(sequence: 1, kind: "started", text: "started")]
            if actual != "sha256:" + sha256 || failNext || !unpacked {
                events.append(
                    InstallTransactionEvent(
                        sequence: 2,
                        kind: "failure",
                        text: "the digest did not match",
                        problem: "installationStopped",
                    ),
                )
                events.append(InstallTransactionEvent(sequence: 3, kind: "exit", text: "exit 1", exitStatus: 1))
                failNext = false
            } else {
                events.append(
                    InstallTransactionEvent(sequence: 2, kind: "phase", text: "verifying", phase: "verifying"),
                )
                events.append(
                    InstallTransactionEvent(
                        sequence: 3,
                        kind: "package",
                        text: "unpacking",
                        step: "unpacking",
                        packageID: control?.packageID,
                        version: control?.version,
                    ),
                )
                events.append(
                    InstallTransactionEvent(sequence: 4, kind: "phase", text: "completed", phase: "completed"),
                )
                events.append(InstallTransactionEvent(sequence: 5, kind: "exit", text: "exit 0", exitStatus: 0))
            }
            transactions[transaction] = Transaction(
                kind: "install",
                package: control?.packageID,
                version: control?.version,
                digest: sha256,
                events: events,
            )
            return status(transaction, duplicate: false)
        }
    }

    func removePackage(transaction: UUID, packageID: String) async throws -> InstallTransactionStatus {
        if lock.withLock({ transactions[transaction] == nil }) {
            onRemove?(packageID)
        }
        return lock.withLock {
            if transactions[transaction] != nil {
                return status(transaction, duplicate: true)
            }
            transactions[transaction] = Transaction(kind: "remove", package: packageID, events: [
                InstallTransactionEvent(sequence: 1, kind: "started", text: "started"),
                InstallTransactionEvent(
                    sequence: 2,
                    kind: "package",
                    text: "removing",
                    step: "removing",
                    packageID: packageID,
                ),
                InstallTransactionEvent(sequence: 3, kind: "exit", text: "exit 0", exitStatus: 0),
            ])
            return status(transaction, duplicate: false)
        }
    }

    func respring(transaction: UUID) async throws -> InstallTransactionStatus {
        lock.withLock {
            transactions[transaction] = Transaction(
                kind: "respring",
                events: [InstallTransactionEvent(sequence: 1, kind: "exit", text: "exit 0", exitStatus: 0)],
            )
            return status(transaction, duplicate: false)
        }
    }

    func status(of transaction: UUID) async throws -> InstallTransactionStatus {
        try lock.withLock {
            guard transactions[transaction] != nil else { throw InstallServiceError(.notFound) }
            return status(transaction, duplicate: false)
        }
    }

    /// Events come out two at a time, as a running helper's would.
    func events(
        of transaction: UUID,
        after: UInt64,
    ) async throws -> (status: InstallTransactionStatus, events: [InstallTransactionEvent]) {
        try lock.withLock {
            guard var entry = transactions[transaction] else { throw InstallServiceError(.notFound) }
            entry.polls += 1
            transactions[transaction] = entry
            let visible = entry.events.prefix(min(entry.events.count, entry.polls * 2))
            return (
                status(transaction, duplicate: false, visible: visible.count),
                visible.filter { $0.sequence > after },
            )
        }
    }

    private func status(_ transaction: UUID, duplicate: Bool, visible: Int? = nil) -> InstallTransactionStatus {
        let entry = transactions[transaction]!
        let shown = visible ?? 0
        let finished = shown == entry.events.count
        let exit = entry.events.last?.exitStatus
        let state: InstallTransactionState = finished ? (exit == 0 ? .succeeded : .failed) : .running
        if finished, state == .succeeded, entry.kind == "install", let package = entry.package {
            installedVersions[package] = entry.version
        }
        if finished, state == .succeeded, entry.kind == "remove", let package = entry.package {
            installedVersions[package] = nil
        }
        return InstallTransactionStatus(
            transaction: transaction,
            kind: entry.kind,
            state: state,
            nextSequence: UInt64(shown + 1),
            exitStatus: finished ? exit : nil,
            packageID: entry.package,
            version: entry.version,
            failure: state == .failed ? "installationStopped" : nil,
            failureText: state == .failed ? "the digest did not match" : nil,
            duplicate: duplicate,
        )
    }
}

/// The package database as the fake irisind leaves it.
struct FakeDatabase: InstalledPackageSource {
    let irisin: FakeIrisin
    var extra: [String: InstalledPackage] = [:]

    func installedPackages() throws -> [String: InstalledPackage] {
        var result = extra
        irisin.lock.withLock {
            for (package, version) in irisin.installedVersions {
                result[package] = InstalledPackage(
                    packageID: package,
                    version: version,
                    status: "install ok installed",
                    essential: false,
                    priority: "optional",
                )
            }
        }
        return result
    }
}

func waitForEnd(_ registry: TaskRegistry, _ handle: TaskHandle) async throws -> TaskEventBatch {
    var batch = try await registry.attach(
        handle.taskID,
        as: handle.kind.attachOperation,
        afterSeq: .start,
        waitMilliseconds: 0,
    )
    for _ in 0 ..< 200 where !batch.finished {
        try await Task.sleep(nanoseconds: 20_000_000)
        batch = try await registry.attach(
            handle.taskID,
            as: handle.kind.attachOperation,
            afterSeq: .start,
            waitMilliseconds: 0,
        )
    }
    return batch
}

// MARK: - Worker events keep their order

do {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("event-order"))
    await registry.load()
    let build = await registry.create(kind: .build, owner: .build)
    // As the host applies a build worker's events: an artifact is recorded
    // (an await) before it is appended; the final state follows at once.
    // Then the worker exits, which ends whatever it still owns.
    let feed = TaskEventFeed<(kind: String, payload: JSONValue?)> { event in
        if event.kind == "exit" {
            return await registry.ownerExited(role: .build, key: nil)
        }
        if event.kind == "artifact" {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await registry.append(build.taskID, kind: event.kind, payload: event.payload)
    }
    feed.send((kind: "log", payload: .object(["line": .string("linked")])))
    feed.send((kind: "artifact", payload: .object(["artifactID": .string(build.taskID.rawValue)])))
    feed.send((kind: TaskEvent.stateKind, payload: .object(["state": .string(TaskState.succeeded.rawValue)])))
    feed.send((kind: "exit", payload: nil))
    let batch = try await waitForEnd(registry, build)
    check(batch.state == .succeeded, "a worker's exit after its final state does not fail the task")
    check(batch.events.map(\.kind) == ["log", "artifact", "state"], "worker events are appended in the order they came, none dropped after the state")
    check(batch.events.map(\.seq.rawValue) == [1, 2, 3], "worker events are numbered in arrival order")
}

do {
    let base = scratchPath + "/install"
    let data = base + "/home/Documents/wiki.qaq.apelin"
    let state = URL(fileURLWithPath: base + "/state")
    try FileManager.default.createDirectory(atPath: data + "/Projects/Hello/.build", withIntermediateDirectories: true)
    let deb = data + "/Projects/Hello/.build/hello.deb"
    makeDeb(at: deb, package: "com.example.hello", version: "1.0")
    let digest = sha256(deb)

    let irisin = FakeIrisin(root: base)
    let registry = TaskRegistry(directory: state.appendingPathComponent("tasks"))
    await registry.load()
    let artifacts = ArtifactRegistry(file: state.appendingPathComponent("artifacts.json"))
    let installations = InstallationStore(directory: state.appendingPathComponent("installations"))
    let approvals = ApprovalLedger(directory: state.appendingPathComponent("approvals"))
    let extra = [
        "com.example.foreign": InstalledPackage(
            packageID: "com.example.foreign",
            version: "1",
            status: "install ok installed",
            essential: false,
            priority: nil,
        ),
    ]
    func bridge() -> InstallBridge {
        InstallBridge(
            paths: .init(installRoot: base, dataFolder: data, staging: state.appendingPathComponent("staging")),
            service: irisin,
            registry: registry,
            artifacts: artifacts,
            installations: installations,
            packages: FakeDatabase(irisin: irisin, extra: extra),
            approvals: approvals,
            pollInterval: 0.01,
        )
    }
    let install = bridge()

    let packaging = "sha256:" + String(repeating: "d", count: 64)
    let buildTask = await registry.create(kind: .build, owner: .build, ownerKey: "b")
    let recorded = await artifacts.record(event: .object([
        "artifactID": .string("art-1"),
        "digest": .string(digest),
        "packageID": .string("com.example.hello"),
        "version": .string("1.0"),
        "path": .string(deb),
        "projectID": .string("p-1"),
        "packagingDigest": .string(packaging),
    ]), buildID: buildTask.taskID)
    check(recorded?.buildID == buildTask.taskID.rawValue, "an artifact event is recorded with its build")
    let missing = await artifacts.record(event: .object(["artifactID": .string("x")]), buildID: buildTask.taskID)
    check(missing == nil, "an artifact event without path and digest is not recorded")

    await expectErrorAsync("a wrong digest", code: .conflict) {
        _ = try await install.install(
            InstallPackageRequest(artifactID: "art-1", digest: String(repeating: "e", count: 64)),
            caller: .app,
        )
    }
    await expectErrorAsync("an unknown artifact", code: .notFound) {
        _ = try await install.install(InstallPackageRequest(artifactID: "nope", digest: digest), caller: .app)
    }
    await expectErrorAsync("a file install from the agent", code: .denied) {
        _ = try await install.install(
            InstallPackageRequest(artifactID: "file:Projects/Hello/.build/hello.deb", digest: digest),
            caller: .worker(.agent, instance: "s"),
        )
    }
    await expectErrorAsync("an agent install of a changed packaging description", code: .denied) {
        _ = try await install.install(
            InstallPackageRequest(artifactID: "art-1", digest: "sha256:" + digest),
            caller: .worker(.agent, instance: "s"),
        )
    }
    await expectErrorAsync("an install from the build worker", code: .denied) {
        _ = try await install.install(
            InstallPackageRequest(artifactID: "art-1", digest: digest),
            caller: .worker(.build, instance: "b"),
        )
    }

    // Approved: the agent's install goes through, bound to the packaging digest.
    try await approvals.recordApproval(packaging, kind: .packaging, project: "p-1")
    let handle = try await install.install(
        InstallPackageRequest(artifactID: "art-1", digest: "sha256:" + digest),
        caller: .worker(.agent, instance: "s"),
    )
    let batch = try await waitForEnd(registry, handle)
    check(batch.state == .succeeded, "the install succeeds (\(batch.events.last?.payload?["message"]?.stringValue ?? ""))")
    let irisinEvents = batch.events.filter { $0.kind == "irisin" }.compactMap { $0.payload?["seq"]?.doubleValue }
    check(irisinEvents == [1, 2, 3, 4, 5], "every irisind event is relayed once, in order")
    let result = try batch.events.first { $0.kind == "result" }?.payload?.decode(InstallResult.self)
    check(result?.packageID == "com.example.hello" && result?.projectID == "p-1" && result?.artifactDigest == digest, "the result names the package, project and digest")
    let stored = await installations.record(result?.installationID ?? "")
    check(stored?.status == .installed && stored?.receipt?.state == "succeeded" && stored?.transactionID == result?.transactionID, "the installation record keeps the receipt")
    check(stored.map { UUID(uuidString: $0.transactionID) != nil && $0.transactionID == $0.transactionID.lowercased() } == true, "the transaction ID is a lowercase UUID")
    check((try? FileManager.default.contentsOfDirectory(atPath: state.appendingPathComponent("staging").path))?.isEmpty ?? true, "the staged copy is removed after the run")

    // A package someone else installed is not overwritten, a core one never.
    let foreign = data + "/foreign.deb"
    makeDeb(at: foreign, package: "com.example.foreign", version: "2")
    await expectErrorAsync("overwriting a foreign package", code: .conflict) {
        _ = try await install.install(
            InstallPackageRequest(artifactID: "file:foreign.deb", digest: sha256(foreign)),
            caller: .app,
        )
    }
    let core = data + "/core.deb"
    makeDeb(at: core, package: "wiki.qaq.irisin", version: "9")
    await expectErrorAsync("installing the install service", code: .denied) {
        _ = try await install.install(
            InstallPackageRequest(artifactID: "file:core.deb", digest: sha256(core)),
            caller: .app,
        )
    }
    symlink(scratchPath + "/peek.deb", data + "/linked.deb")
    await expectErrorAsync("a file through a link out of the data folder") {
        _ = try await install.install(
            InstallPackageRequest(artifactID: "file:linked.deb", digest: sha256(scratchPath + "/peek.deb")),
            caller: .app,
        )
    }

    // Removal: the agent needs this removal approved; the app does not.
    let installationID = result!.installationID
    await expectErrorAsync("an unapproved agent removal", code: .denied) {
        _ = try await install.remove(
            RemovePackageRequest(installationID: installationID),
            caller: .worker(.agent, instance: "s"),
        )
    }
    // The session asks the way apelin-agent does (its EventRelay test holds
    // the same payload), the app approves, and the host grants it once.
    let removalSession = await AgentSessionTable.Entry(
        sessionID: "s",
        task: registry.create(kind: .agent, owner: .agent, ownerKey: "s"),
        project: ResolvedProject(id: "p-1", name: "Hello", path: data + "/Projects/Hello"),
        mode: .confirm,
        createdAt: Date(),
    )
    await AgentSessionTable.shared.add(removalSession)
    await registry.append(removalSession.task.taskID, kind: "approvalRequested", payload: .object([
        "approvalID": .string("remove-hello"),
        "tool": .string("apelin_package_remove"),
        "arguments": .string(#"{"installation_id":"\#(installationID)"}"#),
        "detail": .object(["packageRemoval": .object(["installationID": .string(installationID)])]),
    ]))
    _ = try await AgentApprovals.relay(
        AgentApproveRequest(sessionID: "s", approvalID: "remove-hello", decision: .approve),
        registry: registry,
        ledger: approvals,
        forward: { true },
        accepted: { $0 },
    )
    let removal = try await install.remove(
        RemovePackageRequest(installationID: installationID),
        caller: .worker(.agent, instance: "s"),
    )
    let removed = try await waitForEnd(registry, removal)
    check(removed.state == .succeeded && removed.events.contains { $0.kind == "removed" }, "the removal succeeds")
    let removalLeft = await approvals.takeRemoval(installationID: installationID, session: "s")
    check(!removalLeft, "an approved removal is spent by the removal it allowed")
    // The environment worker's toolchain package: its own source, its own
    // package family, and its own records only.
    let artifactsFolder = data + "/Environment/Artifacts"
    try FileManager.default.createDirectory(atPath: artifactsFolder, withIntermediateDirectories: true)
    makeDeb(
        at: artifactsFolder + "/toolchain-abc123.deb",
        package: "wiki.qaq.apelin.toolchain.abc123",
        version: "16.0+abc123",
    )
    let toolchainDigest = sha256(artifactsFolder + "/toolchain-abc123.deb")
    let environmentCaller = Caller.worker(.environment, instance: nil)
    await expectErrorAsync("the environment worker installing a build artifact", code: .denied) {
        _ = try await install.install(
            InstallPackageRequest(artifactID: "art-1", digest: digest),
            caller: environmentCaller,
        )
    }
    await expectErrorAsync("the environment worker removing a project package", code: .denied) {
        _ = try await install.remove(RemovePackageRequest(installationID: installationID), caller: environmentCaller)
    }
    await expectErrorAsync("the agent installing a toolchain", code: .denied) {
        _ = try await install.install(
            InstallPackageRequest(artifactID: "toolchain-abc123", digest: toolchainDigest),
            caller: .worker(.agent, instance: "s"),
        )
    }
    let toolchainHandle = try await install.install(
        InstallPackageRequest(artifactID: "toolchain-abc123", digest: toolchainDigest),
        caller: environmentCaller,
    )
    let toolchainBatch = try await waitForEnd(registry, toolchainHandle)
    let toolchainResult = try toolchainBatch.events.first { $0.kind == "result" }?.payload?.decode(InstallResult.self)
    check(toolchainBatch.state == .succeeded && toolchainResult?.packageID == "wiki.qaq.apelin.toolchain.abc123", "a toolchain package installs from Environment/Artifacts")
    makeDeb(at: artifactsFolder + "/toolchain-evil.deb", package: "bash", version: "9")
    await expectErrorAsync("a toolchain artifact that is another package", code: .conflict) {
        _ = try await install.install(
            InstallPackageRequest(
                artifactID: "toolchain-evil",
                digest: sha256(artifactsFolder + "/toolchain-evil.deb"),
            ),
            caller: environmentCaller,
        )
    }
    expectError("a toolchain-family package from a project", code: .denied) {
        try ManagedPackagePolicy.checkInstall(
            packageID: "wiki.qaq.apelin.toolchain.abc123",
            origin: .build,
            installed: [:],
            records: [],
        )
    }
    let toolchainRemoval = try await install.remove(
        RemovePackageRequest(installationID: toolchainResult!.installationID),
        caller: environmentCaller,
    )
    let toolchainRemoved = try await waitForEnd(registry, toolchainRemoval)
    check(toolchainRemoved.state == .succeeded, "the environment worker removes its toolchain package")

    let afterRemoval = await installations.record(installationID)
    check(afterRemoval?.status == .removed, "the record says removed")
    await expectErrorAsync("removing twice", code: .denied) {
        _ = try await install.remove(RemovePackageRequest(installationID: installationID), caller: .app)
    }

    // Resume: a host that stopped after staging submits again under the same
    // transaction ID; irisind answers dup and installs nothing twice.
    let resumeDeb = data + "/resume.deb"
    makeDeb(at: resumeDeb, package: "com.example.resume", version: "1")
    let resumeHandle = try await install.install(
        InstallPackageRequest(artifactID: "file:resume.deb", digest: sha256(resumeDeb)),
        caller: .app,
    )
    _ = try await waitForEnd(registry, resumeHandle)
    let resumeBatch = try await registry.attach(
        resumeHandle.taskID,
        as: .buildAttach,
        afterSeq: .start,
        waitMilliseconds: 0,
    )
    let resumeID = try resumeBatch.events.first { $0.kind == "result" }!
        .payload!.decode(InstallResult.self).installationID
    // Rewind the record to "submitted" with nothing followed, and the task to running, as a crash would leave them.
    try await installations.update(resumeID) { $0.status = .submitted; $0.followedSeq = 0 }
    let crashed = await registry.create(kind: .install, owner: nil)
    await registry.setResume(crashed.taskID, .object(["installationID": .string(resumeID)]))
    let submissionsBefore = irisin.lock.withLock { irisin.submissions }
    let fresh = bridge()
    let picked = await fresh.resume(registry.record(crashed.taskID)!)
    check(picked, "an install task with resume data is picked up")
    let resumedBatch = try await waitForEnd(registry, crashed)
    check(resumedBatch.state == .succeeded, "the resumed install finishes")
    check(irisin.lock.withLock { irisin.submissions } == submissionsBefore, "a submitted install is followed, not submitted again")

    try await installations.update(resumeID) { $0.status = .staged; $0.followedSeq = 0 }
    try? FileManager.default.createDirectory(
        at: state.appendingPathComponent("staging"),
        withIntermediateDirectories: true,
    )
    try FileManager.default.copyItem(
        atPath: resumeDeb,
        toPath: state.appendingPathComponent("staging/\(resumeID).deb").path,
    )
    let crashedAgain = await registry.create(kind: .install, owner: nil)
    await registry.setResume(crashedAgain.taskID, .object(["installationID": .string(resumeID)]))
    let duplicatesBefore = irisin.lock.withLock { irisin.duplicates }
    _ = await bridge().resume(registry.record(crashedAgain.taskID)!)
    let again = try await waitForEnd(registry, crashedAgain)
    check(again.state == .succeeded && irisin.lock.withLock { irisin.duplicates } == duplicatesBefore + 1, "a staged install is submitted again under its own ID and answered dup")
}

// MARK: - Toolchain setup end to end

if let harness = ProcessInfo.processInfo.environment["APELIN_ENVIRONMENT_HARNESS"], !harness.isEmpty {
    try await toolchainEndToEnd(harness: harness)
} else {
    print("skip: toolchain setup end to end (APELIN_ENVIRONMENT_HARNESS is not set)")
}

// MARK: - Tool attachment copies

do {
    let copies = AttachmentCopies(directory: URL(fileURLWithPath: scratchPath + "/attachments"))
    let source = scratchPath + "/attachment-source"
    write(source, "attachment bytes\n")
    let writable = open(source, O_RDWR)
    defer { close(writable) }

    let copy = try copies.copy(writable, maximumBytes: 1024)
    var info = stat()
    check(fstat(copy.descriptor.rawValue, &info) == 0 && info.st_nlink == 0, "a copy has no name left")
    check(fcntl(copy.descriptor.rawValue, F_GETFL) & O_ACCMODE == O_RDONLY, "a copy is read-only to its receiver")
    var byte: UInt8 = 0x41
    check(pwrite(copy.descriptor.rawValue, &byte, 1, 0) < 0, "writing through a copy fails")
    check(copy.byteCount == 17, "a copy is the whole file")
    check(copy.sha256 == "sha256:" + sha256(source), "a copy's digest is its bytes'")
    _ = "changed".withCString { pwrite(writable, $0, strlen($0), 0) }
    var buffer = [UInt8](repeating: 0, count: 32)
    let count = pread(copy.descriptor.rawValue, &buffer, buffer.count, 0)
    check(String(decoding: buffer.prefix(max(0, count)), as: UTF8.self) == "attachment bytes\n", "the sender changing its file afterwards does not reach the copy")
    check((try? FileManager.default.contentsOfDirectory(atPath: scratchPath + "/attachments"))?.isEmpty == true, "nothing is left in the copies' directory")
    let mode = (
        try? FileManager.default.attributesOfItem(atPath: scratchPath + "/attachments")[.posixPermissions] as? NSNumber,
    )?.intValue
    check(mode == 0o700, "the copies' directory is private")

    expectError("a file over the bound is refused", code: .badRequest) { _ = try copies.copy(writable, maximumBytes: 4) }
    let directory = open(scratchPath, O_RDONLY)
    expectError("a directory is refused", code: .badRequest) { _ = try copies.copy(directory, maximumBytes: 1024) }
    close(directory)
    let writeOnly = open(source, O_WRONLY)
    expectError("a descriptor the host cannot read is refused", code: .badRequest) { _ = try copies.copy(writeOnly, maximumBytes: 1024) }
    close(writeOnly)

    write(scratchPath + "/attachments/attachment.left", "x")
    copies.sweep()
    check(!FileManager.default.fileExists(atPath: scratchPath + "/attachments/attachment.left"), "a copy a dead host left is swept")

    try? FileManager.default.createSymbolicLink(
        atPath: scratchPath + "/attachments-link",
        withDestinationPath: scratchPath + "/attachments",
    )
    let linked = AttachmentCopies(directory: URL(fileURLWithPath: scratchPath + "/attachments-link"))
    expectError("a symlinked copies' directory is refused", code: .unavailable) { _ = try linked.copy(writable, maximumBytes: 1024) }
}

// MARK: - Credentials and a real terminal

do {
    let mine = ProcessCredentials(pid: getpid())
    check(mine?.matches(SpawnIdentity(uid: getuid(), gid: getgid())) == true, "the kernel's credentials for this process read back")
    check(mine?.matches(.mobile) == (getuid() == 501 && getgid() == 501), "a process that is not mobile does not pass for mobile")

    let launch = TerminalSession.Launch(
        shell: "/bin/sh",
        arguments: ["-i"],
        environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "HOME": scratchPath, "PS1": "$ "],
        identity: nil,
        workingDirectory: scratchPath,
        fallbackDirectory: "/",
        columns: 80,
        rows: 24,
    )
    let queue = DispatchQueue(label: "terminal-test")
    let session = try TerminalSession.spawn(launch, queue: queue)
    let output = NSMutableData()
    let ended = DispatchSemaphore(value: 0)
    var exitStatus: Int32 = -1
    session.start(onOutput: { output.append($0) }, onExit: { exitStatus = $0; ended.signal() })
    let peer = try session.attachPeer()
    _ = "echo apelin-$((40+2)); pwd; exit 3\n".withCString { Darwin.write(peer, $0, strlen($0)) }
    check(ended.wait(timeout: .now() + 10) == .success, "the shell exits")
    let text = queue.sync { String(decoding: output as Data, as: UTF8.self) }
    check(text.contains("apelin-42"), "input through the attached socket reaches the shell, output comes back")
    check(text.contains(scratchPath) || text.contains(scratch.path), "the shell starts in the working directory")
    check((exitStatus >> 8) & 0xFF == 3, "the exit status is reported")
    close(peer)
}

// MARK: - The terminal's git takes no bare repository it was not told of

do {
    let launch = try TerminalHost.launch(
        installRoot: "/",
        home: scratchPath,
        directory: scratchPath,
        columns: 80,
        rows: 24,
    )
    let environment = launch.environment
    let protected = environment.filter { $0.key.hasPrefix("GIT_CONFIG_") }
    check(protected == [
        "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": "safe.bareRepository",
        "GIT_CONFIG_VALUE_0": "explicit",
    ], "the terminal's login environment sets safe.bareRepository=explicit as protected config, and nothing else")

    // A bare layout the agent's files could have made, with a pager in its
    // config: the real git finds it from inside without the setting, and
    // refuses it with the terminal's environment.
    let bare = scratchPath + "/terminal-bare/sub"
    write(bare + "/HEAD", "ref: refs/heads/main\n")
    write(bare + "/objects/info/.keep", "")
    write(bare + "/refs/heads/.keep", "")
    write(bare + "/config", "[core]\n\tbare = true\n\tpager = touch pager-ran\n")
    func gitDirectory(_ extra: [String: String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--absolute-git-dir"]
        process.currentDirectoryURL = URL(fileURLWithPath: bare + "/objects")
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": scratchPath,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CEILING_DIRECTORIES": scratchPath + "/terminal-bare",
        ].merging(extra) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, output)
    }
    let found = gitDirectory([:])
    check(found.status == 0 && found.output.contains("terminal-bare/sub"),
          "git takes the bare layout as a repository: \(found.output)")
    let refused = gitDirectory(protected)
    check(refused.status != 0 && refused.output.contains("bare repository"),
          "with the terminal's environment git refuses it: \(refused.output)")
}

// MARK: - The terminal and shell_run get the project's toolchain and SDK

/// A home whose data folder registers a toolchain (installed beside it, as
/// irisind puts one under the install root) and two SDKs, and a project
/// bound to the older SDK. The records carry an installation ID and an
/// origin with a credential in it, neither of which may reach a variable.
let developmentHome = scratchPath + "/development-home"
let developmentData = developmentHome + "/Documents/wiki.qaq.apelin"
let developmentToolchain = scratchPath + "/development-jb/usr/lib/apelin/toolchains/clt-27.0"
let developmentBin = developmentToolchain + "/usr/bin"
let developmentNewSDK = developmentData + "/SDKs/iphoneos27.0-1a2b3c4d"
let developmentOldSDK = developmentData + "/SDKs/iphoneos18.5-5e6f7a8b"
let developmentProject = developmentData + "/Projects/Env"
write(developmentBin + "/clang", "#!/bin/sh\n", mode: 0o755)
for (id, version, path) in [("iphoneos27.0-1a2b3c4d", "27.0", developmentNewSDK), ("iphoneos18.5-5e6f7a8b", "18.5", developmentOldSDK)] {
    write(path + "/SDKSettings.json", "{}")
    write(
        developmentData + "/SDKs/.registry/\(id).json",
        #"{"id":"\#(id)","canonicalName":"\#(id)","version":"\#(version)","path":"\#(path)","targets":[],"warnings":[],"digest":"1a"}"#,
    )
}

write(
    developmentData + "/Environment/Toolchains/registry.json",
    #"{"defaultID":"clt-27.0","toolchains":[{"id":"clt-27.0","version":"27.0","components":[{"kind":"c","selfCheckPassed":true}],"path":"\#(developmentToolchain)","contentDigest":"ab","installationID":"inst-secret","origin":"082-1 https://user:tok3n@example.invalid/p"}]}"#,
)
write(
    developmentProject + "/apelin-project.json",
    #"{"projectID":"p-env","deploymentTarget":"15.0","environment":{"toolchain":{"id":"clt-27.0"},"sdk":{"id":"iphoneos18.5-5e6f7a8b"}}}"#,
)

do {
    // Outside a project: the default toolchain and the newest SDK it reads.
    let launch = try TerminalHost.launch(
        installRoot: "/",
        home: developmentHome,
        directory: developmentHome,
        columns: 80,
        rows: 24,
    )
    let environment = launch.environment
    let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    check(path.first == developmentBin, "the terminal's PATH starts with the default toolchain's tools: \(path)")
    check(path.dropFirst().first == "/usr/local/bin" && path.contains("/usr/bin"), "then the bootstrap's and the system's directories: \(path)")
    check(environment["SDKROOT"] == developmentNewSDK, "SDKROOT is the newest SDK it reads: \(String(describing: environment["SDKROOT"]))")
    check(environment["IPHONEOS_DEPLOYMENT_TARGET"] == "16.0", "outside a project the deployment target is Apelin's default")
    check(environment["APELIN_TOOLCHAIN_BIN"] == developmentBin, "the toolchain is named for the login profile snippet")
    check(environment.values.allSatisfy { !$0.contains("tok3n") && !$0.contains("inst-secret") }, "no record field but paths reaches the terminal")
    check(environment["GIT_CONFIG_KEY_0"] == "safe.bareRepository", "the terminal keeps its protected git config")
}

do {
    // In a project: what it binds, the same for the terminal and shell_run.
    let launch = try TerminalHost.launch(
        installRoot: "/",
        home: developmentHome,
        directory: developmentProject,
        project: developmentProject,
        columns: 80,
        rows: 24,
    )
    check(launch.environment["SDKROOT"] == developmentOldSDK, "a project's terminal has the SDK the project binds")
    check(launch.environment["IPHONEOS_DEPLOYMENT_TARGET"] == "15.0", "and its deployment target")

    let project = ResolvedProject(id: "p-env", name: "Env", path: developmentProject)
    let entries = AgentRunCode.environment(preset: nil, project: project, installRoot: "/var/jb", home: developmentHome)
    let variables = Dictionary(entries.map { entry in
        let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : "")
    }) { first, _ in first }
    check(entries.count == variables.count, "shell_run gets each variable once: \(entries)")
    check(variables["PATH"] == "\(developmentBin):/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/local/bin:/usr/bin:/bin",
          "shell_run's PATH is the toolchain's tools, then its search path: \(String(describing: variables["PATH"]))")
    check(variables["SDKROOT"] == developmentOldSDK && variables["IPHONEOS_DEPLOYMENT_TARGET"] == "15.0",
          "shell_run has the project's SDK and deployment target, as its terminal does")
    check(variables["HOME"] == developmentHome && variables["APELIN_PROJECT_ROOT"] == developmentProject && variables["TMPDIR"] == "/var/jb/var/tmp",
          "and what it had before")
    check(entries.allSatisfy { !$0.contains("tok3n") && !$0.contains("inst-secret") }, "no record field but paths reaches shell_run")

    // A temporary chat binds nothing: the defaults.
    let temporary = ResolvedProject(id: "temporary:\(UUID().uuidString)", name: "t", path: developmentProject)
    let general = AgentRunCode.environment(preset: nil, project: temporary, installRoot: "/", home: developmentHome)
    check(general.contains("SDKROOT=\(developmentNewSDK)") && general.contains("IPHONEOS_DEPLOYMENT_TARGET=16.0"),
          "a temporary chat's shell_run has the default toolchain's SDK: \(general)")

    // A preset is a read-only command the host chose the words of: its own
    // short list, no compiler on its path.
    let preset = AgentRunCode.Preset(argv: ["/bin/ls"], environment: ["GIT_PAGER=cat"])
    let presetEntries = AgentRunCode.environment(preset: preset, project: project, installRoot: "/var/jb", home: developmentHome)
    check(presetEntries.first == "GIT_PAGER=cat", "a preset's own environment comes first")
    check(presetEntries.contains("PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/local/bin:/usr/bin:/bin"), "a preset keeps the bare search path")
    check(!presetEntries.contains { $0.hasPrefix("SDKROOT=") || $0.hasPrefix("APELIN_TOOLCHAIN_BIN=") || $0.contains(developmentBin) },
          "and no toolchain or SDK: \(presetEntries)")
}

// MARK: - Agent approvals are found and spent only when they apply

do {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("agent-tasks"))
    await registry.load()
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("agent-approvals"))
    let sessions = AgentSessionTable.shared
    func session(_ id: String) async -> AgentSessionTable.Entry {
        let entry = await AgentSessionTable.Entry(
            sessionID: id,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: id),
            project: ResolvedProject(id: "p-agent", name: "Agent", path: scratchPath),
            mode: .confirm,
            createdAt: Date(),
        )
        await sessions.add(entry)
        return entry
    }
    func ask(
        _ entry: AgentSessionTable.Entry,
        _ approvalID: String,
        tool: String,
        detail: JSONValue? = nil,
        workingDirectory: String = ".",
    ) async {
        var payload: [String: JSONValue] = [
            "approvalID": .string(approvalID),
            "tool": .string(tool),
            "workingDirectory": .string(workingDirectory),
        ]
        if let detail {
            payload["detail"] = detail
        }
        await registry.append(entry.task.taskID, kind: "approvalRequested", payload: .object(payload))
    }
    // What apelin-agent puts in a shell_run request's `detail`: the command,
    // as ApelinAgent's RunCodeInvocation encodes it (ApelinAgentWorker's
    // tests hold that shape).
    func command(_ invocation: String, _ value: JSONValue) -> JSONValue {
        .object(["command": .object([invocation: value])])
    }
    let makeCommand = command("argv", .object(["_0": .array([.string("make")])]))
    func runCode(_ entry: AgentSessionTable.Entry, _ approvalID: String) -> AgentRunCodeRequest {
        AgentRunCodeRequest(
            sessionID: entry.sessionID,
            spec: .argv(["make"]),
            approval: .user(approvalID: approvalID),
        )
    }

    // A long session: the request comes after more events than one attach
    // batch holds.
    let long = await session("agent-long")
    for index in 0 ..< 1200 {
        await registry.append(long.task.taskID, kind: "text", payload: .object(["text": .string("\(index)")]))
    }
    let digest = "sha256:" + String(repeating: "d", count: 64)
    let changed: JSONValue = .object([
        "descriptionChanged": .object(["kind": .string("build"), "digest": .string(digest)]),
    ])
    await ask(long, "late-build", tool: "apelin_project_build", detail: changed)
    await ask(long, "late-run", tool: "shell_run", detail: makeCommand)
    let approveBuild = AgentApproveRequest(sessionID: long.sessionID, approvalID: "late-build", decision: .approve)
    try await AgentApprovals.recordInLedger(approveBuild, entry: long, registry: registry, ledger: ledger)
    let recorded = try await ledger.state(of: digest, kind: .build, project: "p-agent")
    check(recorded.baseline == .approved, "an approval asked after the first thousand events is recorded")
    await sessions.record(long.sessionID, approvalID: "late-run", decision: .approve)
    var lateRunPassed = true
    do {
        try await AgentApprovals.authorize(runCode(long, "late-run"), entry: long, registry: registry, ledger: ledger, installRoot: "/")
    } catch {
        lateRunPassed = false
    }
    check(lateRunPassed, "a shell_run approval asked after the first thousand events lets the call through")
    await expectErrorAsync("a shell_run approval is used once", code: .denied) {
        try await AgentApprovals.authorize(runCode(long, "late-run"), entry: long, registry: registry, ledger: ledger, installRoot: "/")
    }

    // An approval that does not apply is refused and left as the app gave it.
    let short = await session("agent-short")
    await ask(short, "for-build", tool: "apelin_project_build")
    await sessions.record(short.sessionID, approvalID: "for-build", decision: .approve)
    await expectErrorAsync("an approval asked for another tool", code: .denied) {
        try await AgentApprovals.authorize(
            runCode(short, "for-build"),
            entry: short,
            registry: registry,
            ledger: ledger,
            installRoot: "/",
        )
    }
    let kept = await sessions.entry(short.sessionID)?.approvals["for-build"]
    check(kept == .approve, "a refused shell_run call does not spend an approval asked for another tool")
    await sessions.record(short.sessionID, approvalID: "never-asked", decision: .approve)
    await expectErrorAsync("an approval the session never asked for", code: .denied) {
        try await AgentApprovals.authorize(
            runCode(short, "never-asked"),
            entry: short,
            registry: registry,
            ledger: ledger,
            installRoot: "/",
        )
    }
    let unasked = await sessions.entry(short.sessionID)?.approvals["never-asked"]
    check(unasked == .approve, "a refused shell_run call does not spend an approval with no request behind it")

    // An approval runs the command it was asked for, in the directory it was
    // asked for, and nothing else.
    let bound = await session("agent-bound")
    func authorized(_ run: AgentRunCodeRequest) async -> Bool {
        do {
            try await AgentApprovals.authorize(run, entry: bound, registry: registry, ledger: ledger, installRoot: "/")
            return true
        } catch {
            return false
        }
    }
    await ask(bound, "make-here", tool: "shell_run", detail: makeCommand)
    await sessions.record(bound.sessionID, approvalID: "make-here", decision: .approve)
    let other = AgentRunCodeRequest(
        sessionID: bound.sessionID,
        spec: .argv(["rm", "-rf", "Sources"]),
        approval: .user(approvalID: "make-here"),
    )
    let otherPassed = await authorized(other)
    check(!otherPassed, "an approval cited for another command is refused")
    let elsewhere = AgentRunCodeRequest(
        sessionID: bound.sessionID,
        spec: .argv(["make"]),
        workingDirectory: "Sources",
        approval: .user(approvalID: "make-here"),
    )
    let elsewherePassed = await authorized(elsewhere)
    check(!elsewherePassed, "an approval cited in another working directory is refused")
    let stillThere = await sessions.entry(bound.sessionID)?.approvals["make-here"]
    check(stillThere == .approve, "a run that is not the approved one does not spend the approval")
    let matchingPassed = await authorized(runCode(bound, "make-here"))
    check(matchingPassed, "the approved command in the approved directory runs")

    // Shell text the agent could not reduce to argv runs as an sh script.
    let shellText = "make 2>&1 | tail -n 20"
    await ask(bound, "make-piped", tool: "shell_run", detail: command("shell", .object(["_0": .string(shellText)])))
    await sessions.record(bound.sessionID, approvalID: "make-piped", decision: .approve)
    let piped = AgentRunCodeRequest(
        sessionID: bound.sessionID,
        spec: .script(interpreter: "sh", source: shellText),
        approval: .user(approvalID: "make-piped"),
    )
    let pipedPassed = await authorized(piped)
    check(pipedPassed, "approved shell text runs as the sh script it became")
    await ask(bound, "no-command", tool: "shell_run")
    await sessions.record(bound.sessionID, approvalID: "no-command", decision: .approve)
    let noCommandPassed = await authorized(runCode(bound, "no-command"))
    check(!noCommandPassed, "a shell_run approval that names no command is refused")
    // An approval asked under the name run_code had before the rename is no
    // approval for shell_run: the worker and the host change together.
    await ask(bound, "make-earlier-name", tool: "run_code", detail: makeCommand)
    await sessions.record(bound.sessionID, approvalID: "make-earlier-name", decision: .approve)
    let earlierNamePassed = await authorized(runCode(bound, "make-earlier-name"))
    check(!earlierNamePassed, "an approval recorded under run_code's earlier name is refused")
}

// MARK: - An agent sets up a toolchain or imports an SDK only as the user approved it

do {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("agent-environment-tasks"))
    await registry.load()
    let sessions = AgentSessionTable.shared
    func session(_ id: String, mode: ApprovalMode = .confirm) async -> AgentSessionTable.Entry {
        let entry = await AgentSessionTable.Entry(
            sessionID: id,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: id),
            project: ResolvedProject(id: "p-environment", name: "Environment", path: scratchPath),
            mode: mode,
            createdAt: Date(),
        )
        await sessions.add(entry)
        return entry
    }
    // What apelin-agent writes into apelin_toolchain_setup's and apelin_sdk_import's
    // approvalRequested `detail` (ApelinAgentWorker's tests hold that shape).
    func ask(_ entry: AgentSessionTable.Entry, _ approvalID: String, tool: String, detail: JSONValue) async {
        await registry.append(entry.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string(approvalID), "tool": .string(tool), "detail": detail,
        ]))
    }
    let setupDetail: JSONValue = .object(["toolchainSetup": .object([
        "productID": .string("082-1"), "version": .string("16.4"), "components": .array([.string("c")]), "sizeBytes": .number(1),
    ])])
    let sourceURL = "https://github.com/owngoal-dev/iOS-SDKs.git"
    let importDetail: JSONValue = .object(["sdkImport": .object([
        "source": .string("OwnGoal iOS SDKs"), "url": .string(sourceURL), "branch": .string("sdk/iPhoneOS17.5"), "version": .string("17.5"),
    ])])
    func authorized(_ request: some OperationRequest, _ entry: AgentSessionTable.Entry?, descriptors: Int = 0) async -> Bool {
        guard let wire = try? WireRequest(request) else { return false }
        do {
            try await AgentEnvironmentRules.authorize(wire, descriptorCount: descriptors, entry: entry, registry: registry)
            return true
        } catch {
            return false
        }
    }
    let setup = ToolchainSetupRequest(source: .appleCatalog(productID: "082-1"), components: [.c])
    let strict = await session("environment-strict")

    // The source rules hold in every mode.
    let relaxed = await session("environment-relaxed", mode: .relaxed)
    let relaxedSetup = await authorized(setup, relaxed)
    check(relaxedSetup, "a Relaxed session sets up a catalog toolchain without asking")
    let unnamed = await authorized(ToolchainSetupRequest(source: .appleCatalog(productID: nil)), relaxed)
    check(!unnamed, "but always names the product the user is shown")
    let packageFile = await authorized(ToolchainSetupRequest(source: .package(DescriptorSlot(index: 0))), relaxed, descriptors: 1)
    check(!packageFile, "and never sets one up from a file")
    for source: SDKSource in [
        .url("https://example.com/iPhoneOS17.5.sdk.tar.xz"), .inbox(path: "sdk"), .file(DescriptorSlot(index: 0)),
        .repository(url: "https://user:token@github.com/owngoal-dev/iOS-SDKs.git", branch: "sdk/iPhoneOS17.5"),
        .repository(url: sourceURL + "?token=1", branch: "sdk/iPhoneOS17.5"),
        .repository(url: sourceURL + "#frag", branch: "sdk/iPhoneOS17.5"),
        .repository(url: "http://github.com/owngoal-dev/iOS-SDKs.git", branch: "sdk/iPhoneOS17.5"),
    ] {
        let passed = await authorized(SDKImportRequest(source: source), relaxed)
        check(!passed, "an agent imports an SDK only from an HTTPS repository without credentials (\(source))")
    }
    let relaxedImport = await authorized(SDKImportRequest(source: .repository(url: sourceURL, branch: "sdk/iPhoneOS17.5")), relaxed)
    check(relaxedImport, "a Relaxed session imports from a source without asking")
    let noSession = await authorized(setup, nil)
    check(!noSession, "a worker with no session sets up nothing")

    // Under Confirm: exactly the approved setup, once.
    let unapproved = await authorized(setup, strict)
    check(!unapproved, "a Strict session needs the user's approval")
    await ask(strict, "setup-1", tool: "apelin_toolchain_setup", detail: setupDetail)
    let notYetGiven = await authorized(setup, strict)
    check(!notYetGiven, "asking is not approving")
    await sessions.record(strict.sessionID, approvalID: "setup-1", decision: .approve)
    let otherProduct = await authorized(ToolchainSetupRequest(source: .appleCatalog(productID: "082-2"), components: [.c]), strict)
    check(!otherProduct, "an approval covers the product it named only")
    let otherComponents = await authorized(ToolchainSetupRequest(source: .appleCatalog(productID: "082-1"), components: [.c, .swift]), strict)
    check(!otherComponents, "and its components only")
    let approvedSetup = await authorized(setup, strict)
    check(approvedSetup, "the approved setup goes through")
    let again = await authorized(setup, strict)
    check(!again, "once: a second setup asks again")
    let importRequest = SDKImportRequest(source: .repository(url: sourceURL, branch: "sdk/iPhoneOS17.5"))
    await ask(strict, "import-1", tool: "apelin_sdk_import", detail: importDetail)
    await sessions.record(strict.sessionID, approvalID: "import-1", decision: .approve)
    let otherBranch = await authorized(SDKImportRequest(source: .repository(url: sourceURL, branch: "sdk/iPhoneOS18.5")), strict)
    check(!otherBranch, "an import approval covers its branch only")
    let setupFromImport = await authorized(setup, strict)
    check(!setupFromImport, "and no setup")
    let approvedImport = await authorized(importRequest, strict)
    check(approvedImport, "the approved import goes through")
    await ask(strict, "denied-1", tool: "apelin_sdk_import", detail: importDetail)
    await sessions.record(strict.sessionID, approvalID: "denied-1", decision: .deny)
    let afterDenial = await authorized(importRequest, strict)
    check(!afterDenial, "a denied approval lets nothing through")

    // An agent reads only the environment tasks its session started.
    let started = await registry.create(kind: .environment, owner: .environment, ownerKey: nil)
    let foreign = await registry.create(kind: .environment, owner: .environment, ownerKey: nil)
    await sessions.recordStarted(started.taskID, session: strict.sessionID)
    let readsOwn = await sessions.started(started.taskID, session: strict.sessionID)
    let readsForeign = await sessions.started(foreign.taskID, session: strict.sessionID)
    let readsOthers = await sessions.started(started.taskID, session: relaxed.sessionID)
    check(readsOwn && !readsForeign && !readsOthers, "a task counts as the session's only when that session started it")
}

// MARK: - A workspace's build spends the one approval the user gave for it

do {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("agent-external-build-tasks"))
    await registry.load()
    let sessions = AgentSessionTable.shared
    let entry = await AgentSessionTable.Entry(
        sessionID: "external-build-strict",
        task: registry.create(kind: .agent, owner: .agent, ownerKey: "external-build-strict"),
        project: ResolvedProject(id: "p-workspace", name: "Workspace", path: scratchPath),
        mode: .confirm,
        createdAt: Date(),
    )
    await sessions.add(entry)
    // What apelin-agent writes into a workspace build's approvalRequested
    // `detail` (ApelinAgentWorker's tests hold that shape): no bootstrap
    // when the build names none.
    func ask(_ approvalID: String, configuration: String, bootstrap: String? = nil) async {
        var detail: [String: JSONValue] = [
            "projectID": .string("p-workspace"), "script": .string("apelin/build.sh"), "configuration": .string(configuration),
        ]
        detail["bootstrap"] = bootstrap.map(JSONValue.string)
        await registry.append(entry.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string(approvalID), "tool": .string("apelin_project_build"),
            "detail": .object([AgentExternalBuildRules.detailKey: .object(detail)]),
        ]))
    }
    let debug = BuildStartRequest(projectID: "p-workspace", configuration: .debug)
    let unapproved = await AgentExternalBuildRules.authorize(debug, session: entry.sessionID, registry: registry)
    check(unapproved?.code == .denied, "a Strict session's workspace build needs the user's approval")
    await ask("build-1", configuration: "debug")
    let asked = await AgentExternalBuildRules.authorize(debug, session: entry.sessionID, registry: registry)
    check(asked != nil, "asking is not approving")
    await sessions.record(entry.sessionID, approvalID: "build-1", decision: .approve)
    let release = await AgentExternalBuildRules.authorize(BuildStartRequest(projectID: "p-workspace", configuration: .release), session: entry.sessionID, registry: registry)
    check(release != nil, "an approval covers the configuration it named only")
    let rootless = await AgentExternalBuildRules.authorize(BuildStartRequest(projectID: "p-workspace", bootstrap: .rootless), session: entry.sessionID, registry: registry)
    check(rootless != nil, "and the bootstrap it named only")
    let elsewhere = await AgentExternalBuildRules.authorize(BuildStartRequest(projectID: "p-other"), session: entry.sessionID, registry: registry)
    check(elsewhere != nil, "and its project only")
    let approved = await AgentExternalBuildRules.authorize(debug, session: entry.sessionID, registry: registry)
    check(approved == nil, "the approved build goes through")
    let again = await AgentExternalBuildRules.authorize(debug, session: entry.sessionID, registry: registry)
    check(again != nil, "once: the next build asks again")
    await ask("build-2", configuration: "release", bootstrap: "rootless")
    await sessions.record(entry.sessionID, approvalID: "build-2", decision: .approve)
    let named = await AgentExternalBuildRules.authorize(BuildStartRequest(projectID: "p-workspace", configuration: .release, bootstrap: .rootless), session: entry.sessionID, registry: registry)
    check(named == nil, "a build naming a bootstrap is covered by an approval naming it")
    let noSession = await AgentExternalBuildRules.authorize(debug, session: nil, registry: registry)
    check(noSession != nil, "a worker with no session builds nothing")
}

// MARK: - A project is renamed by its own session, or another as the user approved

do {
    check(CallerPolicy.allows(.worker(.agent, instance: "s"), .projectRename), "the agent may ask for a rename")
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("agent-rename-tasks"))
    await registry.load()
    let home = scratch.appendingPathComponent("rename-home", isDirectory: true)
    let projects = DataFolder(home: home.path).projects
    for (name, id) in [("Mine", "p-rename-mine"), ("Theirs", "p-rename-theirs")] {
        let folder = projects.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(#"{"projectID":"\#(id)"}"#.utf8).write(to: folder.appendingPathComponent("apelin-project.json"))
    }
    let homePath = CanonicalPath.resolve(home.path)!
    let sessions = AgentSessionTable.shared
    func session(_ id: String, mode: ApprovalMode) async -> AgentSessionTable.Entry {
        let entry = await AgentSessionTable.Entry(
            sessionID: id,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: id),
            project: ResolvedProject(id: "p-rename-mine", name: "Mine", path: homePath + "/Documents/wiki.qaq.apelin/Projects/Mine"),
            mode: mode,
            createdAt: Date(),
        )
        await sessions.add(entry)
        return entry
    }
    let strict = await session("rename-strict", mode: .confirm)
    func authorized(_ rename: ProjectRenameRequest, _ entry: AgentSessionTable.Entry?) async -> Bool {
        await AgentProjectRenameRules.authorize(rename, session: entry?.sessionID, home: homePath, registry: registry) == nil
    }
    let own = await authorized(ProjectRenameRequest(projectID: "p-rename-mine", displayName: "Clock"), strict)
    let ownAutomatic = await authorized(ProjectRenameRequest(projectID: "p-rename-mine", displayName: "Clock", onlyIfAutomatic: true), strict)
    check(own && ownAutomatic, "a session renames its own project, automatically too, without an approval")
    let theirs = ProjectRenameRequest(projectID: "p-rename-theirs", displayName: "Weather")
    let unasked = await authorized(theirs, strict)
    check(!unasked, "another project's rename needs the user's approval under Confirm")
    await registry.append(strict.task.taskID, kind: "approvalRequested", payload: .object([
        "approvalID": .string("rename-1"), "tool": .string("apelin_project_rename"),
        "detail": .object([AgentProjectRenameRules.detailKey: .object([
            "projectID": .string("p-rename-theirs"), "folder": .string("Theirs"),
            "currentName": .string("Theirs"), "displayName": .string("Weather"),
        ])]),
    ]))
    let asked = await authorized(theirs, strict)
    check(!asked, "asking is not approving")
    await sessions.record(strict.sessionID, approvalID: "rename-1", decision: .approve)
    let otherName = await authorized(ProjectRenameRequest(projectID: "p-rename-theirs", displayName: "Rain"), strict)
    check(!otherName, "an approval covers the name it showed only")
    let approved = await authorized(theirs, strict)
    check(approved, "the approved rename goes through")
    let again = await authorized(theirs, strict)
    check(!again, "once: the next rename asks again")
    let relaxed = await session("rename-relaxed", mode: .relaxed)
    let relaxedOther = await authorized(theirs, relaxed)
    let relaxedAutomatic = await authorized(ProjectRenameRequest(projectID: "p-rename-theirs", displayName: "Weather", onlyIfAutomatic: true), relaxed)
    check(relaxedOther && !relaxedAutomatic, "Relaxed renames another project, but never automatically")
    let byFolder = await authorized(ProjectRenameRequest(projectID: "Theirs", displayName: "Weather"), relaxed)
    check(!byFolder, "a project is named by its id, never its folder")
    let noSession = await authorized(ProjectRenameRequest(projectID: "p-rename-mine", displayName: "Clock"), nil)
    check(!noSession, "a worker with no session renames nothing")
}

// MARK: - Another project's conversations are reached only as the user approved

do {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("agent-reach-tasks"))
    await registry.load()
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("agent-reach-approvals"))
    let sessions = AgentSessionTable.shared
    let entry = await AgentSessionTable.Entry(
        sessionID: "reach-opener",
        task: registry.create(kind: .agent, owner: .agent, ownerKey: "reach-opener"),
        project: ResolvedProject(id: "p-reach", name: "Reach", path: scratchPath),
        mode: .confirm,
        createdAt: Date(),
    )
    await sessions.add(entry)
    let detail: JSONValue = .object([AgentConversationRules.otherProjectDetail: .object([
        "action": .string("create"), "projectID": .string("p-far"), "projectName": .string("Far"), "text": .string("Build it"),
    ])])
    await registry.append(entry.task.taskID, kind: "approvalRequested", payload: .object([
        "approvalID": .string("reach-1"), "tool": .string("apelin_conversation_create"), "detail": detail,
    ]))
    let before = await sessions.mayReach("p-far", session: entry.sessionID)
    check(!before, "another project is out of reach until the user approves a call naming it")
    // The worker refuses the relay: nothing is left behind.
    _ = try await AgentApprovals.relay(
        AgentApproveRequest(sessionID: entry.sessionID, approvalID: "reach-1", decision: .approve),
        registry: registry,
        ledger: ledger,
        forward: { false },
        accepted: { $0 },
    )
    let afterRefusedRelay = await sessions.mayReach("p-far", session: entry.sessionID)
    check(!afterRefusedRelay, "an approval the worker did not take lets it reach nothing")
    _ = try await AgentApprovals.relay(
        AgentApproveRequest(sessionID: entry.sessionID, approvalID: "reach-1", decision: .approve),
        registry: registry,
        ledger: ledger,
        forward: { true },
        accepted: { $0 },
    )
    let afterRelay = await sessions.mayReach("p-far", session: entry.sessionID)
    check(afterRelay, "once approved, the session may list and read that project's conversations")
    let open = AgentOpenRequest(projectID: "p-far", projectName: "Far", prompt: "Build it")
    let far = ResolvedProject(id: "p-far", name: "Far", path: scratchPath + "/Far")
    let spent = await AgentApprovals.spend(entry: entry, registry: registry) {
        AgentConversationRules.coversOpen(open, target: far, asked: $0)
    }
    check(spent, "the approved open spends its approval")
    let spentAgain = await AgentApprovals.spend(entry: entry, registry: registry) {
        AgentConversationRules.coversOpen(open, target: far, asked: $0)
    }
    check(!spentAgain, "and only once")
    await sessions.forgetGrants(entry.sessionID)
    let afterClose = await sessions.mayReach("p-far", session: entry.sessionID)
    check(!afterClose, "a closed session reaches no other project")
}

// MARK: - An approval the worker never got leaves nothing behind

do {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("relay-tasks"))
    await registry.load()
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("relay-approvals"))
    let sessions = AgentSessionTable.shared
    let entry = await AgentSessionTable.Entry(
        sessionID: "agent-relay",
        task: registry.create(kind: .agent, owner: .agent, ownerKey: "agent-relay"),
        project: ResolvedProject(id: "p-relay", name: "Relay", path: scratchPath),
        mode: .confirm,
        createdAt: Date(),
    )
    await sessions.add(entry)
    let digest = "sha256:" + String(repeating: "e", count: 64)
    let changedBuild: JSONValue = .object(["kind": .string("build"), "digest": .string(digest)])
    let asks: [(String, JSONValue)] = [
        ("relay-build", .object(["descriptionChanged": changedBuild])),
        ("relay-remove", .object(["packageRemoval": .object(["installationID": .string("inst-relay")])])),
    ]
    for (approvalID, detail) in asks {
        await registry.append(entry.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string(approvalID), "tool": .string("apelin_project_build"), "detail": detail,
        ]))
    }
    func relay(_ approvalID: String, workerTakesIt: Bool) async throws {
        let approve = AgentApproveRequest(sessionID: entry.sessionID, approvalID: approvalID, decision: .approve)
        _ = try await AgentApprovals.relay(
            approve,
            registry: registry,
            ledger: ledger,
            forward: { workerTakesIt },
            accepted: { $0 },
        )
    }

    try await relay("relay-build", workerTakesIt: false)
    try await relay("relay-remove", workerTakesIt: false)
    let refusedState = try await ledger.state(of: digest, kind: .build, project: "p-relay")
    check(refusedState.baseline == .changed, "a description approval the worker refused is not in the ledger")
    let refusedRemoval = await ledger.takeRemoval(installationID: "inst-relay", session: entry.sessionID)
    check(!refusedRemoval, "a removal approval the worker refused is not in the ledger")
    let refusedDecision = await sessions.entry(entry.sessionID)?.approvals["relay-build"]
    check(refusedDecision == nil, "a decision the worker refused is not kept for the session")

    try await relay("relay-build", workerTakesIt: true)
    try await relay("relay-remove", workerTakesIt: true)
    let acceptedState = try await ledger.state(of: digest, kind: .build, project: "p-relay")
    check(acceptedState.baseline == .approved, "a description approval the worker took is in the ledger")
    let acceptedRemoval = await ledger.takeRemoval(installationID: "inst-relay", session: entry.sessionID)
    check(acceptedRemoval, "a removal approval the worker took is in the ledger")

    // Refusing the same approval again does not take back the one that held.
    try await relay("relay-build", workerTakesIt: false)
    let keptState = try await ledger.state(of: digest, kind: .build, project: "p-relay")
    check(keptState.baseline == .approved, "a refused repeat leaves an earlier approval of the same digest")

    // Two sessions approve the same digest at once: A's relay records it,
    // B's (inside A's forward) finds it there and its worker takes it, then
    // A's worker refuses. B's approval must still hold.
    let shared = "sha256:" + String(repeating: "f", count: 64)
    let sharedBuild: JSONValue = .object(["descriptionChanged": .object([
        "kind": .string("build"), "digest": .string(shared),
    ])])
    var pair: [AgentSessionTable.Entry] = []
    for name in ["agent-relay-a", "agent-relay-b"] {
        let session = await AgentSessionTable.Entry(
            sessionID: name,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: name),
            project: entry.project,
            mode: .confirm,
            createdAt: Date(),
        )
        await sessions.add(session)
        await registry.append(session.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string("shared-build"), "tool": .string("apelin_project_build"), "detail": sharedBuild,
        ]))
        pair.append(session)
    }
    func approve(_ session: AgentSessionTable.Entry) -> AgentApproveRequest {
        AgentApproveRequest(sessionID: session.sessionID, approvalID: "shared-build", decision: .approve)
    }
    _ = try await AgentApprovals.relay(
        approve(pair[0]),
        registry: registry,
        ledger: ledger,
        forward: { () async -> Bool in
            _ = try? await AgentApprovals.relay(
                approve(pair[1]),
                registry: registry,
                ledger: ledger,
                forward: { true },
                accepted: { $0 },
            )
            return false
        },
        accepted: { $0 },
    )
    let sharedState = try await ledger.state(of: shared, kind: .build, project: "p-relay")
    check(sharedState.baseline == .approved, "one session's refused relay leaves another session's accepted approval")

    // And the other way round: B refuses first, then A's worker refuses
    // too, and nothing is left.
    let unheld = "sha256:" + String(repeating: "c", count: 64)
    let unheldBuild: JSONValue = .object(["descriptionChanged": .object([
        "kind": .string("build"), "digest": .string(unheld),
    ])])
    for session in pair {
        await registry.append(session.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string("unheld-build"), "tool": .string("apelin_project_build"), "detail": unheldBuild,
        ]))
    }
    func approveUnheld(_ session: AgentSessionTable.Entry) -> AgentApproveRequest {
        AgentApproveRequest(sessionID: session.sessionID, approvalID: "unheld-build", decision: .approve)
    }
    _ = try await AgentApprovals.relay(
        approveUnheld(pair[0]),
        registry: registry,
        ledger: ledger,
        forward: { () async -> Bool in
            _ = try? await AgentApprovals.relay(
                approveUnheld(pair[1]),
                registry: registry,
                ledger: ledger,
                forward: { false },
                accepted: { $0 },
            )
            return false
        },
        accepted: { $0 },
    )
    let unheldState = try await ledger.state(of: unheld, kind: .build, project: "p-relay")
    check(unheldState.baseline == .changed, "a digest no session's worker accepted is taken back")
}

// MARK: - A withdrawn approval gives back the one it pushed out

do {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("evict-tasks"))
    await registry.load()
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("evict-approvals"))
    func digest(_ index: Int) -> String {
        "sha256:" + String(repeating: "0", count: 56) + String(format: "%08x", index)
    }
    for index in 0 ..< ApprovalLedger.maximumApprovals {
        if let grant = try await ledger.recordApproval(digest(index), kind: .build, project: "p-evict") {
            await ledger.confirmApproval(grant)
        }
    }
    let full = try await ledger.state(of: digest(0), kind: .build, project: "p-evict")
    check(full.baseline == .approved, "the ledger holds as many approvals as its cap")
    let entry = await AgentSessionTable.Entry(
        sessionID: "agent-evict",
        task: registry.create(kind: .agent, owner: .agent, ownerKey: "agent-evict"),
        project: ResolvedProject(id: "p-evict", name: "Evict", path: scratchPath),
        mode: .confirm,
        createdAt: Date(),
    )
    await AgentSessionTable.shared.add(entry)
    await registry.append(entry.task.taskID, kind: "approvalRequested", payload: .object([
        "approvalID": .string("evict-build"),
        "tool": .string("apelin_project_build"),
        "detail": .object(["descriptionChanged": .object([
            "kind": .string("build"), "digest": .string(digest(1000)),
        ])]),
    ]))
    var pushedOut = false
    _ = try await AgentApprovals.relay(
        AgentApproveRequest(sessionID: entry.sessionID, approvalID: "evict-build", decision: .approve),
        registry: registry,
        ledger: ledger,
        forward: { () async -> Bool in
            pushedOut = await (try? ledger.state(of: digest(0), kind: .build, project: "p-evict"))?.baseline == .changed
            return false
        },
        accepted: { $0 },
    )
    check(pushedOut, "a new approval past the cap pushes the oldest out")
    let restored = try await ledger.state(of: digest(0), kind: .build, project: "p-evict")
    check(restored.baseline == .approved, "withdrawing the new approval brings the pushed-out one back")
    let withdrawn = try await ledger.state(of: digest(1000), kind: .build, project: "p-evict")
    check(withdrawn.baseline == .changed, "the withdrawn approval is gone")
    let reloaded = ApprovalLedger(directory: scratch.appendingPathComponent("evict-approvals"))
    let onDisk = try await reloaded.state(of: digest(0), kind: .build, project: "p-evict")
    check(
        onDisk.baseline == .approved && onDisk.lastApprovedDigest == digest(63),
        "the restored ledger is the one on disk",
    )
}

// MARK: - A shell_run approved for the session runs again for that command only

do {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("grant-tasks"))
    await registry.load()
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("grant-approvals"))
    let sessions = AgentSessionTable.shared
    let entry = await AgentSessionTable.Entry(
        sessionID: "agent-grant",
        task: registry.create(kind: .agent, owner: .agent, ownerKey: "agent-grant"),
        project: ResolvedProject(id: "p-grant", name: "Grant", path: scratchPath),
        mode: .confirm,
        createdAt: Date(),
    )
    await sessions.add(entry)
    func ask(_ approvalID: String, argv: [String], sessionScope: Bool, workingDirectory: String = ".") async {
        await registry.append(entry.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string(approvalID),
            "tool": .string("shell_run"),
            "workingDirectory": .string(workingDirectory),
            "allowsSessionScope": .bool(sessionScope),
            "detail": .object(["command": .object(["argv": .object(["_0": .array(argv.map { .string($0) })])])]),
        ]))
    }
    func approve(_ approvalID: String, scope: ApprovalScope?, workerTakesIt: Bool = true) async throws {
        let approve = AgentApproveRequest(
            sessionID: entry.sessionID,
            approvalID: approvalID,
            decision: .approve,
            scope: scope,
        )
        _ = try await AgentApprovals.relay(
            approve,
            registry: registry,
            ledger: ledger,
            forward: { workerTakesIt },
            accepted: { $0 },
        )
    }
    func authorized(_ argv: [String], _ approval: RunCodeApproval, in directory: String = ".") async -> Bool {
        let run = AgentRunCodeRequest(
            sessionID: entry.sessionID,
            spec: .argv(argv),
            workingDirectory: directory,
            approval: approval,
        )
        do {
            try await AgentApprovals.authorize(run, entry: entry, registry: registry, ledger: ledger, installRoot: "/")
            return true
        } catch {
            return false
        }
    }

    let before = await authorized(["make"], .session)
    check(!before, "a session-scoped shell_run with no grant behind it is refused")

    await ask("make-session", argv: ["make"], sessionScope: true)
    try await approve("make-session", scope: .session)
    let first = await authorized(["make"], .user(approvalID: "make-session"))
    check(first, "the call the app approved for the session runs on its own approval")
    let second = await authorized(["make"], .session)
    let third = await authorized(["make"], .session)
    check(second && third, "the same command in the same directory runs again for the session")
    let otherCommand = await authorized(["make", "install"], .session)
    check(!otherCommand, "a session grant does not cover another command")
    let otherDirectory = await authorized(["make"], .session, in: "preset-project")
    check(!otherDirectory, "a session grant does not cover another working directory")

    // Once stays once, and a request that did not offer the session scope
    // grants nothing beyond its own call.
    await ask("ls-once", argv: ["ls", "-R"], sessionScope: true)
    try await approve("ls-once", scope: .once)
    _ = await authorized(["ls", "-R"], .user(approvalID: "ls-once"))
    let onceAgain = await authorized(["ls", "-R"], .session)
    check(!onceAgain, "an approval given once grants nothing for the session")
    await ask("rm-unoffered", argv: ["rm", "x"], sessionScope: false)
    try await approve("rm-unoffered", scope: .session)
    let unoffered = await authorized(["rm", "x"], .session)
    check(!unoffered, "a request that did not offer the session scope grants nothing for the session")

    // The worker refusing the decision takes the grant back.
    await ask("cc-refused", argv: ["cc", "main.c"], sessionScope: true)
    try await approve("cc-refused", scope: .session, workerTakesIt: false)
    let refusedGrant = await authorized(["cc", "main.c"], .session)
    check(!refusedGrant, "a session grant the worker refused is not kept")

    // Closing the session forgets its grants.
    await sessions.forgetGrants(entry.sessionID)
    let afterClose = await authorized(["make"], .session)
    check(!afterClose, "a closed session's grants are gone")
}

// MARK: - shell_run presets are read-only and stay in the project

do {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("preset-tasks"))
    await registry.load()
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("preset-approvals"))
    let project = scratchPath + "/preset-project"
    write(project + "/Sources/main.m", "int main(void) { return 0; }\n")
    write(project + "/Info.plist", "<plist version=\"1.0\"><dict/></plist>\n")
    write(scratchPath + "/preset-outside.txt", "outside\n")
    symlink("/etc/hosts", project + "/hosts-link")
    run("/usr/bin/git", ["init", "-q", "."], in: project)
    let entry = await AgentSessionTable.Entry(
        sessionID: "agent-presets",
        task: registry.create(kind: .agent, owner: .agent, ownerKey: "agent-presets"),
        project: ResolvedProject(id: "p-presets", name: "Presets", path: project),
        mode: .confirm,
        createdAt: Date(),
    )
    await AgentSessionTable.shared.add(entry)
    func preset(_ argv: [String], in directory: String = ".") async -> Bool {
        let request = AgentRunCodeRequest(
            sessionID: entry.sessionID,
            spec: .argv(argv),
            workingDirectory: directory,
            approval: .preset(argv[0]),
        )
        do {
            try await AgentApprovals.authorize(request, entry: entry, registry: registry, ledger: ledger, installRoot: "/")
            return true
        } catch {
            return false
        }
    }

    let passes: [([String], String)] = [
        (["ls", "-la"], "."),
        (["cat", "Sources/main.m"], "."),
        (["head", "-n", "5", "Sources/main.m"], "."),
        (["cat", "../Info.plist"], "Sources"),
        (["wc", "-l", "--", "Sources/main.m"], "."),
        (["plutil", "-p", "Info.plist"], "."),
        (["git", "status"], "."),
        (["git", "diff", "--stat"], "."),
        (["git", "log", "--oneline", "-n", "5"], "."),
    ]
    for (argv, directory) in passes {
        let passed = await preset(argv, in: directory)
        check(passed, "\(argv.joined(separator: " ")) in \(directory) is a preset")
    }
    let refused: [([String], String)] = [
        (["cat", "/etc/passwd"], "."),
        (["cat", "../preset-outside.txt"], "."),
        (["cat", "../../preset-outside.txt"], "Sources"),
        (["cat", "hosts-link"], "."),
        (["head", "--", "/etc/hosts"], "."),
        (["stat", "-f", "%z", "/etc/hosts"], "."),
        (["file", "-C", "-m", "magic"], "."),
        (["plutil", "-p", "Info.plist", "-o", "copy.plist"], "."),
        (["git", "diff", "--output=/tmp/apelin-preset-escape"], "."),
        (["git", "log", "--output", "log.txt"], "."),
        (["git", "diff", "-o", "diff.txt"], "."),
        (["git", "diff", "--ext-diff"], "."),
        (["git", "log", "-p", "--textconv"], "."),
        (["git", "status", "-c", "core.fsmonitor=x"], "."),
        (["git", "diff", "--no-index", "/etc/hosts", "Info.plist"], "."),
        (["git", "log", "--git-dir=/var"], "."),
        (["git", "status", "--work-tree", "/"], "."),
        (["git", "diff", "-C", "/"], "."),
        (["git", "log", "--exec-path=/tmp"], "."),
        // A list of names read from a file names files outside the project.
        (["file", "-f", "Info.plist"], "."),
        (["file", "-bf", "Info.plist"], "."),
        (["file", "--files-from", "Info.plist"], "."),
        (["file", "--files=Info.plist"], "."),
        (["file", "--comp", "-m", "magic"], "."),
        (["wc", "--files0-from=Info.plist"], "."),
        (["wc", "--files0-from", "Info.plist"], "."),
        (["wc", "--files0=Info.plist"], "."),
        (["cat", "--files-from=Info.plist"], "."),
        // Nothing reaches a submodule, abbreviated or not.
        (["git", "status", "--ignore-sub=none"], "."),
        (["git", "diff", "--submodule=diff"], "."),
        (["git", "log", "--recurse-submodules"], "."),
        // file prints how it reads, with no magic file or decompressor; ls
        // follows no link and walks no tree; git reads no order file and
        // verifies no signature.
        (["file", "-m/etc/passwd", "Info.plist"], "."),
        (["file", "-z", "Info.plist"], "."),
        (["ls", "-lL", "hosts-link"], "."),
        (["ls", "-R"], "."),
        (["git", "diff", "-O/etc/passwd"], "."),
        (["git", "log", "--show-signature"], "."),
        (["git", "log", "--format=%G?"], "."),
    ]
    for (argv, directory) in refused {
        let passed = await preset(argv, in: directory)
        check(!passed, "\(argv.joined(separator: " ")) in \(directory) is not a preset")
    }

    // A repository whose own config names a command is not read without
    // asking: git would run it (filters, textconv, fsmonitor, pager).
    let gitConfig = project + "/.git/config"
    let plainConfig = try String(contentsOfFile: gitConfig, encoding: .utf8)
    for extra in [
        "[filter \"evil\"]\n\tclean = touch /tmp/apelin-preset-escape\n",
        "[core]\n\tfsmonitor = /tmp/apelin-preset-escape\n",
        "[core]\n\tpager = sh -c 'touch /tmp/apelin-preset-escape'\n",
        "[include]\n\tpath = /tmp/apelin-preset-escape\n",
        "[diff \"evil\"]\n\ttextconv = touch\n",
        // git reads a section header and a key on one line, and a second
        // header behind the first.
        "[user \"a\"][filter \"x\"]clean = touch /tmp/apelin-preset-escape #]\n",
        "[user]name = a\n[filter \"x\"] clean = touch /tmp/apelin-preset-escape\n",
        "[includeIf \"gitdir:/\"]\n\tpath = /tmp/apelin-preset-escape\n",
        "[core \"x\"]\n\tbare = false\n",
        "[core]\n\tbare = \"unterminated\n",
    ] {
        try (plainConfig + extra).write(toFile: gitConfig, atomically: true, encoding: .utf8)
        let passed = await preset(["git", "status"])
        check(!passed, "git status in a repository configured with \(extra.split(separator: "\n")[0]) is not a preset")
    }
    // What a task clone writes is inert: its remote, its branch and the
    // task that made it.
    let cloned = plainConfig + """
    [remote "origin"]
    \turl = https://example.com/tweak.git
    \tfetch = +refs/heads/*:refs/remotes/origin/*
    [branch "main"]
    \tremote = origin
    \tmerge = refs/heads/main
    [apelin]
    \tcloneTask = 0f1e2d3c-task

    """
    try cloned.write(toFile: gitConfig, atomically: true, encoding: .utf8)
    let clonedPassed = await preset(["git", "status"])
    check(clonedPassed, "git status in a repository a task cloned is a preset")
    try plainConfig.write(toFile: gitConfig, atomically: true, encoding: .utf8)

    // A submodule has a config of its own the check never read: a
    // repository with one asks.
    write(project + "/.gitmodules", "[submodule \"evil\"]\n\tpath = evil\n\turl = https://example.com/e.git\n")
    let withGitmodules = await preset(["git", "status"])
    check(!withGitmodules, "git status in a repository with .gitmodules is not a preset")
    unlink(project + "/.gitmodules")
    mkdir(project + "/.git/modules", 0o755)
    let withModules = await preset(["git", "diff"])
    check(!withModules, "git diff in a repository with .git/modules is not a preset")
    rmdir(project + "/.git/modules")
    let plainAgain = await preset(["git", "status"])
    check(plainAgain, "git status in the plain repository is a preset again")

    // A folder laid out as a bare repository is the repository git uses
    // there, ahead of the project's .git; its config was never read.
    let bare = project + "/Sources/bare"
    write(bare + "/HEAD", "ref: refs/heads/main\n")
    mkdir(bare + "/objects", 0o755)
    mkdir(bare + "/refs", 0o755)
    write(bare + "/config", "[core]\n\tbare = true\n[filter \"x\"]\n\tclean = touch /tmp/apelin-preset-escape\n")
    for argv in [["git", "status"], ["git", "diff"], ["git", "log"]] {
        let inBare = await preset(argv, in: "Sources/bare")
        check(!inBare, "\(argv.joined(separator: " ")) in a bare layout inside the project is not a preset")
    }
    write(bare + "/objects/.keep", "")
    let belowBare = project + "/Sources/bare/objects"
    let fromBelow = await preset(["git", "status"], in: "Sources/bare/objects")
    check(!fromBelow && FileManager.default.fileExists(atPath: belowBare), "nor in a folder below one")
    try FileManager.default.removeItem(atPath: bare)

    // git skips a .git that is not a repository and walks on: from a folder
    // with an empty .git it uses the project's, whose config names a filter.
    let skipped = project + "/Sources/skipped"
    mkdir(skipped, 0o755)
    mkdir(skipped + "/.git", 0o755)
    try (plainConfig + "[filter \"x\"]\n\tclean = touch /tmp/apelin-preset-escape\n")
        .write(toFile: gitConfig, atomically: true, encoding: .utf8)
    let throughEmpty = await preset(["git", "status"], in: "Sources/skipped")
    check(!throughEmpty, "git status below an empty .git, in a repository with a filter, is not a preset")
    try plainConfig.write(toFile: gitConfig, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(atPath: skipped)

    // HEAD beside a commondir is a repository to git, sharing the project's
    // objects and config; it is not the project's .git, so it asks. Asked
    // without safe.bareRepository (which a git older than 2.38 ignores), git
    // still names a git directory other than its common one and no work
    // tree, so the host's check does not lean on that setting.
    let linked = project + "/linked"
    write(linked + "/HEAD", "ref: refs/heads/main\n")
    write(linked + "/commondir", "../.git\n")
    for argv in [["git", "status"], ["git", "log"]] {
        let inLinked = await preset(argv, in: "linked")
        check(!inLinked, "\(argv.joined(separator: " ")) in a folder with HEAD and commondir is not a preset")
    }
    let unguarded = Pipe()
    let revParse = Process()
    revParse.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    revParse.arguments = ["rev-parse", "--absolute-git-dir", "--git-common-dir"]
    revParse.environment = ["PATH": "/usr/bin:/bin", "HOME": scratchPath, "GIT_CONFIG_NOSYSTEM": "1"]
    revParse.currentDirectoryURL = URL(fileURLWithPath: linked)
    revParse.standardOutput = unguarded
    revParse.standardError = FileHandle.nullDevice
    try revParse.run()
    revParse.waitUntilExit()
    let named = String(decoding: unguarded.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map(String.init)
    check(
        named.count == 2 && named[0] == linked && named[1] != named[0],
        "without safe.bareRepository git takes the folder as a repository whose common directory is another",
    )
    try FileManager.default.removeItem(atPath: linked)

    // With no .git between the working directory and the project, git finds
    // no repository the check read: not a preset.
    let unversioned = scratchPath + "/preset-unversioned"
    write(unversioned + "/Info.plist", "<plist version=\"1.0\"><dict/></plist>\n")
    let noRepository = await AgentRunCode.preset(
        .argv(["git", "status"]),
        directory: unversioned,
        project: unversioned,
        installRoot: "/",
    )
    check(noRepository == nil, "git status in a project with no .git is not a preset")

    // git runs with configured commands overridden and only the
    // repository's own config read.
    let diff = await AgentRunCode.preset(
        .argv(["git", "diff", "--stat"]),
        directory: project,
        project: project,
        installRoot: "/",
    )
    check(
        diff?.argv == ["git"] + AgentRunCode.gitOverrides
            + ["diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all", "--stat"],
        "git diff runs with the overrides and without external diff, textconv or submodules",
    )
    let status = await AgentRunCode.preset(
        .argv(["git", "status"]),
        directory: project,
        project: project,
        installRoot: "/",
    )
    check(
        status?.argv == ["git"] + AgentRunCode.gitOverrides + ["status", "--ignore-submodules=all"],
        "git status runs with the overrides and without submodules",
    )
    check(AgentRunCode.gitOverrides.contains("submodule.recurse=false"), "no git preset recurses into a submodule")
    let environment = status?.environment ?? []
    check(
        environment.contains("GIT_CONFIG_NOSYSTEM=1") && environment.contains("GIT_CONFIG_GLOBAL=/dev/null")
            && environment.contains("GIT_CEILING_DIRECTORIES=\(scratchPath)"),
        "git reads no system or global config and finds no repository above the project",
    )
    let gitOutput = Pipe()
    let hardened = Process()
    hardened.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    hardened.arguments = Array((status?.argv ?? []).dropFirst())
    var gitEnvironment = ["PATH": "/usr/bin:/bin", "HOME": scratchPath]
    for pair in environment {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        gitEnvironment[String(parts[0])] = String(parts[1])
    }
    hardened.environment = gitEnvironment
    hardened.currentDirectoryURL = URL(fileURLWithPath: project)
    hardened.standardOutput = gitOutput
    hardened.standardError = gitOutput
    try hardened.run()
    hardened.waitUntilExit()
    check(hardened.terminationStatus == 0, "this git accepts the preset's overrides")
    // And with them it does not take a bare layout it was not pointed at.
    let bareAgain = project + "/Sources/bare"
    mkdir(bareAgain, 0o755)
    run("/usr/bin/git", ["init", "-q", "--bare", "."], in: bareAgain)
    func gitStatus(in directory: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.environment = gitEnvironment
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
    // status needs a work tree anyway; rev-parse shows what git discovered.
    let overridden = try gitStatus(in: bareAgain, AgentRunCode.gitOverrides + ["rev-parse", "--is-bare-repository"])
    let discovered = try gitStatus(in: bareAgain, ["rev-parse", "--is-bare-repository"])
    check(
        overridden != 0 && discovered == 0,
        "the overrides keep git from using a bare repository found by discovery, which it uses otherwise",
    )
    try FileManager.default.removeItem(atPath: bareAgain)

    // A signed commit in history never starts gpg: with the overrides, a
    // log that would verify it finds no program where gpg.program points,
    // not the gpg first on PATH.
    let signed = scratchPath + "/preset-signed"
    let fakeTools = scratchPath + "/preset-fake-tools"
    let started = scratchPath + "/preset-gpg-started"
    write(fakeTools + "/gpg", "#!/bin/sh\ntouch '\(started)'\nexit 1\n", mode: 0o755)
    write(fakeTools + "/gpgsm", "#!/bin/sh\ntouch '\(started)'\nexit 1\n", mode: 0o755)
    mkdir(signed, 0o755)
    run("/usr/bin/git", ["init", "-q", "."], in: signed)
    write(signed + "/commit.txt", """
    tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904
    author A <a@example.com> 0 +0000
    committer A <a@example.com> 0 +0000
    gpgsig -----BEGIN PGP SIGNATURE-----
     \n iQEzBAABCAAdFiEE
     -----END PGP SIGNATURE-----

    signed

    """)
    let hashed = Pipe()
    let hash = Process()
    hash.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    hash.arguments = ["hash-object", "-t", "commit", "-w", "commit.txt"]
    hash.currentDirectoryURL = URL(fileURLWithPath: signed)
    hash.standardOutput = hashed
    try hash.run()
    hash.waitUntilExit()
    let commit = String(decoding: hashed.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    run("/usr/bin/git", ["update-ref", "HEAD", commit], in: signed)
    var fakeEnvironment = gitEnvironment
    fakeEnvironment["PATH"] = fakeTools + ":/usr/bin:/bin"
    func signatureLog(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.environment = fakeEnvironment
        process.currentDirectoryURL = URL(fileURLWithPath: signed)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }
    try signatureLog(["log", "--format=%G?"])
    let startsUnguarded = FileManager.default.fileExists(atPath: started)
    unlink(started)
    for verify in [["log", "--format=%G?"], ["log", "--show-signature"], ["-c", "log.showSignature=true", "log"]] {
        try signatureLog(AgentRunCode.gitOverrides + verify)
    }
    check(
        startsUnguarded && !FileManager.default.fileExists(atPath: started),
        "the overrides keep a signed commit from starting gpg, which a plain log starts",
    )
    let cat = await AgentRunCode.preset(
        .argv(["cat", "Info.plist"]),
        directory: project,
        project: project,
        installRoot: "/",
    )
    check(cat == AgentRunCode.Preset(argv: ["cat", "Info.plist"], environment: []), "a file tool runs as asked")
}

// MARK: - A git config read holds no thread of the cooperative pool

do {
    // As many reads as the pool has threads, each a second long: while they
    // run, a task started after them still runs at once.
    final class Started: @unchecked Sendable {
        let lock = NSLock()
        var after: TimeInterval?
    }
    let started = Started()
    let width = ProcessInfo.processInfo.activeProcessorCount
    let begin = Date()
    await withTaskGroup(of: Void.self) { group in
        for _ in 0 ..< width {
            group.addTask {
                _ = await AgentRunCode.capture(["/bin/sleep", "1"], environment: [], timeoutSeconds: 5)
            }
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: 50_000_000)
            started.lock.withLock { started.after = Date().timeIntervalSince(begin) }
        }
    }
    let after = started.lock.withLock { started.after } ?? .infinity
    check(after < 0.5, "a task runs while \(width) config reads wait on git (it waited \(after) s)")
}

// MARK: - shell_run returns although a process that left its group holds the pipes

do {
    /// The script prints, forks a child that calls setsid — out of the group
    /// the host kills — and keeps stdout and stderr open, writing its pid
    /// down so the test can kill it afterwards. With `then` sleeping too,
    /// the script itself runs into the timeout.
    func escaping(_ name: String, then: String, timeout: Int) -> (AgentRunCodeResponse?, TimeInterval)? {
        let pidFile = scratchPath + "/escaped-\(name).pid"
        let script = """
        use POSIX (); $| = 1; print "hi\\n";
        if (fork() == 0) {
            POSIX::setsid();
            open(my $f, '>', '\(pidFile)'); print $f $$; close($f);
            sleep 1000; exit 0;
        }
        # Go on only once the child has left the group, or the host's
        # group kill could reach it first and the pipes would just close.
        select(undef, undef, undef, 0.05) until -e '\(pidFile)';
        \(then)
        """
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var response: AgentRunCodeResponse?
        }
        let box = Box()
        let returned = DispatchSemaphore(value: 0)
        let begin = Date()
        Task.detached {
            let response = await AgentRunCode.capture(
                ["/usr/bin/perl", "-e", script],
                environment: ["PATH=/usr/bin:/bin"],
                timeoutSeconds: timeout,
            )
            box.lock.withLock { box.response = response }
            returned.signal()
        }
        // The test's own deadline: a call that never returns fails here
        // instead of hanging the harness.
        let finished = returned.wait(timeout: .now() + .seconds(timeout + 10)) == .success
        let elapsed = Date().timeIntervalSince(begin)
        if let text = try? String(contentsOfFile: pidFile, encoding: .utf8), let pid = pid_t(text) {
            kill(pid, SIGKILL)
        }
        guard finished else { return nil }
        return (box.lock.withLock { box.response }, elapsed)
    }

    func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }
    let descriptorsBefore = openDescriptors()
    let exited = escaping("exited", then: "exit 0;", timeout: 30)
    check(exited != nil, "shell_run returns when its script exits and an escaped child keeps the pipes open")
    if let (response, elapsed) = exited {
        check(openDescriptors() == descriptorsBefore, "the cut pipes are closed, none left open")
        check(elapsed < 6, "it returns within the drain after the script exits (it took \(elapsed) s)")
        check(response?.stdout == "hi\n", "what was printed before the cut is kept: \(String(describing: response))")
        check(response?.exitCode == 0 && response?.timedOut == false, "the script's own exit is reported")
        check(response?.truncated == true, "output cut at the drain is marked truncated")
    }

    let timedOut = escaping("timed-out", then: "sleep 1000;", timeout: 2)
    check(timedOut != nil, "shell_run returns at its timeout although an escaped child keeps the pipes open")
    if let (response, elapsed) = timedOut {
        check(elapsed < 2 + 6, "it returns within the timeout and the drain (it took \(elapsed) s)")
        check(response?.stdout == "hi\n" && response?.timedOut == true, "the timeout is reported with the output")
    }
}

// MARK: - A partial last event line does not swallow the events after it

do {
    let directory = scratch.appendingPathComponent("torn-events")
    let first = TaskRegistry(directory: directory)
    await first.load()
    let handle = await first.create(kind: .build, owner: .build, ownerKey: "torn")
    await first.append(handle.taskID, kind: "log", payload: .object(["line": .string("one")]))
    await first.append(handle.taskID, kind: "log", payload: .object(["line": .string("two")]))
    // A crash in the middle of the third line.
    let events = directory.appendingPathComponent("\(handle.taskID.rawValue).events.jsonl")
    let torn = try FileHandle(forWritingTo: events)
    torn.seekToEndOfFile()
    torn.write(Data(#"{"seq":3,"kind":"log","pay"#.utf8))
    try torn.close()

    let second = TaskRegistry(directory: directory)
    await second.load()
    await second.append(handle.taskID, kind: "resumed", payload: .object(["resumes": .number(1)]))
    await second.append(handle.taskID, kind: "log", payload: .object(["line": .string("three")]))
    let third = TaskRegistry(directory: directory)
    await third.load()
    let replay = try await third.attach(handle.taskID, as: .buildAttach, afterSeq: .start, waitMilliseconds: 0)
    check(
        replay.events.map(\.kind) == ["log", "log", "resumed", "log"]
            && replay.events.map(\.seq.rawValue) == [1, 2, 3, 4],
        "events appended after a torn line survive the next load",
    )

    // A last line that lost only its newline is an event all the same.
    let unterminated = try Data(String(contentsOf: events, encoding: .utf8).dropLast().utf8)
    try unterminated.write(to: events)
    let fourth = TaskRegistry(directory: directory)
    await fourth.load()
    await fourth.append(handle.taskID, kind: "log", payload: .object(["line": .string("four")]))
    let fifth = TaskRegistry(directory: directory)
    await fifth.load()
    let kept = try await fifth.attach(handle.taskID, as: .buildAttach, afterSeq: .start, waitMilliseconds: 0)
    check(
        kept.events.map(\.seq.rawValue) == [1, 2, 3, 4, 5],
        "a last event missing only its newline is kept, and the next one follows it",
    )
}

// MARK: - A final state in the log outranks a record written before it

do {
    let directory = scratch.appendingPathComponent("state-ahead-of-record")
    let first = TaskRegistry(directory: directory)
    await first.load()
    let handle = await first.create(kind: .build, owner: .build, ownerKey: "ahead")
    await first.setResume(handle.taskID, .object(["operation": .string("buildStart"), "resumes": .number(0)]))
    await first.append(handle.taskID, kind: "log", payload: .object(["line": .string("linked")]))
    // `append` writes the line, then the record: a crash between the two.
    let final = TaskEvent(
        seq: EventSeq(2),
        kind: TaskEvent.stateKind,
        payload: .object(["state": .string("succeeded"), "artifactID": .string(handle.taskID.rawValue)]),
    )
    var line = try JSONCoding.encode(final)
    line.append(0x0A)
    let events = directory.appendingPathComponent("\(handle.taskID.rawValue).events.jsonl")
    let log = try FileHandle(forWritingTo: events)
    log.seekToEndOfFile()
    log.write(line)
    try log.close()

    let second = TaskRegistry(directory: directory)
    let unfinished = await second.load()
    check(unfinished.isEmpty, "a task whose log ends in a final state is not handed to a resumer")
    let corrected = await second.record(handle.taskID)
    check(corrected?.state == .succeeded, "its state is the one the log ended with")
    let replay = try await second.attach(handle.taskID, as: .buildAttach, afterSeq: .start, waitMilliseconds: 0)
    check(
        replay.finished && replay.events.last?.payload?["artifactID"]?.stringValue == handle.taskID.rawValue,
        "it reads as finished, with the final event's result",
    )
    let stored = try JSONCoding.decoder().decode(
        TaskRegistry.Record.self,
        from: Data(contentsOf: directory.appendingPathComponent("\(handle.taskID.rawValue).json")),
    )
    check(stored.state == .succeeded, "the corrected record is written back")
}

// MARK: - A bad line in the middle of the log loses nothing after it

do {
    let directory = scratch.appendingPathComponent("bad-middle-line")
    let first = TaskRegistry(directory: directory)
    await first.load()
    let handle = await first.create(kind: .build, owner: .build, ownerKey: "middle")
    await first.append(handle.taskID, kind: "log", payload: .object(["line": .string("one")]))
    await first.append(handle.taskID, kind: "log", payload: .object(["line": .string("two")]))
    await first.append(handle.taskID, kind: "log", payload: .object(["line": .string("three")]))
    await first.finish(handle.taskID, .succeeded)
    // The third line rewritten in a shape this build cannot read (a
    // corrupted line, or one a newer build wrote before a downgrade).
    let events = directory.appendingPathComponent("\(handle.taskID.rawValue).events.jsonl")
    var lines = try String(contentsOf: events, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
    lines[2] = #"{"seq":3,"kind":"log","time":"a shape from elsewhere"}"#
    let rewritten = lines.joined(separator: "\n")
    try Data(rewritten.utf8).write(to: events)

    let second = TaskRegistry(directory: directory)
    let unfinished = await second.load()
    check(unfinished.isEmpty, "a final state after a bad line still ends the task")
    let replay = try await second.attach(handle.taskID, as: .buildAttach, afterSeq: .start, waitMilliseconds: 0)
    check(
        replay.events.map(\.seq.rawValue) == [1, 2, 3, 4] && replay.finished && replay.state == .succeeded,
        "the events after a bad line are read, numbered with no gap: \(replay.events.map(\.seq.rawValue))",
    )
    check(
        replay.events.count == 4 && replay.events[2].kind == TaskRegistry.unreadableKind,
        "the bad line reads as an unreadable event",
    )
    let after = try String(contentsOf: events, encoding: .utf8)
    check(after == rewritten, "the log keeps every line, the bad one included")

    // A bad last line that has its newline is skipped, not cut, and what is
    // appended after it is read back.
    let open = await second.create(kind: .build, owner: .build, ownerKey: "middle-open")
    await second.append(open.taskID, kind: "log", payload: .object(["line": .string("one")]))
    let openEvents = directory.appendingPathComponent("\(open.taskID.rawValue).events.jsonl")
    let tail = try FileHandle(forWritingTo: openEvents)
    tail.seekToEndOfFile()
    tail.write(Data(#"{"seq":2,"kind":"log","time":"a shape from elsewhere"}"#.utf8 + [0x0A]))
    try tail.close()
    let third = TaskRegistry(directory: directory)
    await third.load()
    await third.append(open.taskID, kind: "log", payload: .object(["line": .string("two")]))
    let fourth = TaskRegistry(directory: directory)
    await fourth.load()
    let reread = try await fourth.attach(open.taskID, as: .buildAttach, afterSeq: .start, waitMilliseconds: 0)
    check(
        reread.events.map(\.seq.rawValue) == [1, 2] && reread.events.last?.payload?["line"]?.stringValue == "two",
        "an event appended after a bad last line is read back",
    )
    let openLog = try String(contentsOf: openEvents, encoding: .utf8)
    check(openLog.contains("a shape from elsewhere"), "and the bad line is still in the log")
}

// MARK: - A finished record is not pulled back to running by an unreadable final line

do {
    let directory = scratch.appendingPathComponent("unreadable-final-state")
    let first = TaskRegistry(directory: directory)
    await first.load()
    let handle = await first.create(kind: .build, owner: .build, ownerKey: "unreadable-final")
    await first.setResume(handle.taskID, .object(["operation": .string("buildStart"), "resumes": .number(0)]))
    await first.append(handle.taskID, kind: TaskEvent.stateKind, payload: .object(["state": .string("running")]))
    await first.append(handle.taskID, kind: "log", payload: .object(["line": .string("linked")]))
    await first.finish(handle.taskID, .succeeded)
    // The final line is whole, newline and all, but no longer decodes.
    let events = directory.appendingPathComponent("\(handle.taskID.rawValue).events.jsonl")
    var lines = try String(contentsOf: events, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
    lines[2] = #"{"seq":3,"kind":"state","time":"a shape from elsewhere"}"#
    try Data(lines.joined(separator: "\n").utf8).write(to: events)

    let second = TaskRegistry(directory: directory)
    let unfinished = await second.load()
    check(unfinished.isEmpty, "a finished record is not resumed when its final state line cannot be read")
    let kept = await second.record(handle.taskID)
    check(kept?.state == .succeeded, "it keeps the finished state the record holds: \(String(describing: kept?.state))")
}

// MARK: - A finished task whose final lines cannot be read still ends with a state

do {
    let directory = scratch.appendingPathComponent("unreadable-final-lines")
    let first = TaskRegistry(directory: directory)
    await first.load()
    let handle = await first.create(kind: .confirmLoaded, owner: .diagnostics, ownerKey: "unreadable-tail")
    await first.append(handle.taskID, kind: "stage", payload: .object(["stage": .string("listening")]))
    await first.append(handle.taskID, kind: "stage", payload: .object(["stage": .string("trigger")]))
    await first.append(
        handle.taskID,
        kind: TaskEvent.stateKind,
        payload: .object(["state": .string("succeeded"), "result": .object(["loaded": .bool(true)])]),
    )
    // The last two lines are whole, newline and all, but no longer decode.
    let events = directory.appendingPathComponent("\(handle.taskID.rawValue).events.jsonl")
    var lines = try String(contentsOf: events, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
    lines[1] = #"{"seq":2,"kind":"stage","time":"a shape from elsewhere"}"#
    lines[2] = #"{"seq":3,"kind":"state","time":"a shape from elsewhere"}"#
    try Data(lines.joined(separator: "\n").utf8).write(to: events)

    let second = TaskRegistry(directory: directory)
    await second.load()
    let replay = try await second.attach(
        handle.taskID,
        as: .confirmLoadedAttach,
        afterSeq: .start,
        waitMilliseconds: 0,
    )
    let final = replay.events.last
    check(
        replay.finished && final?.kind == TaskEvent.stateKind
            && final?.payload?["state"]?.stringValue == "succeeded",
        "a finished task whose final state line cannot be read ends with a state event: \(replay.events.map(\.kind))",
    )
    check(
        replay.events.map(\.seq.rawValue) == [1, 2, 3, 4]
            && replay.events[1].kind == TaskRegistry.unreadableKind
            && replay.events[2].kind == TaskRegistry.unreadableKind,
        "the trailing lines that cannot be read keep their numbers: \(replay.events.map(\.seq.rawValue))",
    )
    let record = await second.record(handle.taskID)
    check(record?.lastSeq == final?.seq, "the record's last number is the closing state's")
    let stored = try JSONCoding.decoder().decode(
        TaskRegistry.Record.self,
        from: Data(contentsOf: directory.appendingPathComponent("\(handle.taskID.rawValue).json")),
    )
    check(stored.lastSeq == EventSeq(4), "and the record on disk says so too")
    if let final {
        expectError("the load check's answer says its final line could not be read", code: .internal) {
            _ = try ConfirmLoadedResponse.from(finalState: final)
        }
    }

    // The closing state is written down, so the next load reads it as is.
    let third = TaskRegistry(directory: directory)
    await third.load()
    let reread = try await third.attach(handle.taskID, as: .confirmLoadedAttach, afterSeq: .start, waitMilliseconds: 0)
    check(
        reread.events.map(\.seq.rawValue) == [1, 2, 3, 4] && reread.events.last?.kind == TaskEvent.stateKind,
        "the closing state survives the next load with the same numbers",
    )
}

// MARK: - A digest pushed out while still pending is not brought back

do {
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("pending-evict-approvals"))
    func digest(_ index: Int) -> String {
        "sha256:" + String(repeating: "1", count: 56) + String(format: "%08x", index)
    }
    for index in 0 ..< ApprovalLedger.maximumApprovals {
        if let grant = try await ledger.recordApproval(digest(index), kind: .build, project: "p-pending-evict") {
            await ledger.confirmApproval(grant)
        }
    }
    // A is recorded and stays pending while the rest of the list turns over
    // under it, until A is the oldest entry.
    let grantA = try await ledger.recordApproval(digest(1000), kind: .build, project: "p-pending-evict")
    for index in 2000 ..< 2000 + ApprovalLedger.maximumApprovals - 1 {
        if let grant = try await ledger.recordApproval(digest(index), kind: .build, project: "p-pending-evict") {
            await ledger.confirmApproval(grant)
        }
    }
    // B pushes A out; then both workers refuse.
    let grantB = try await ledger.recordApproval(digest(3000), kind: .build, project: "p-pending-evict")
    let pushedOut = try await ledger.state(of: digest(1000), kind: .build, project: "p-pending-evict")
    check(pushedOut.baseline == .changed, "B past the cap pushes out A, the oldest")
    if let grantA {
        try await ledger.withdrawApproval(grantA)
    }
    if let grantB {
        try await ledger.withdrawApproval(grantB)
    }
    let afterB = try await ledger.state(of: digest(1000), kind: .build, project: "p-pending-evict")
    check(afterB.baseline == .changed, "withdrawing B does not bring back A, which no worker accepted")
}

// MARK: - Approving an approved description again moves it to the newest end

do {
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("reapprove-approvals"))
    func digest(_ index: Int) -> String {
        "sha256:" + String(repeating: "2", count: 56) + String(format: "%08x", index)
    }
    for index in 0 ..< ApprovalLedger.maximumApprovals {
        if let grant = try await ledger.recordApproval(digest(index), kind: .build, project: "p-reapprove") {
            await ledger.confirmApproval(grant)
        }
    }
    let again = try await ledger.recordApproval(digest(0), kind: .build, project: "p-reapprove")
    check(again == nil, "approving an accepted digest again has nothing to take back")
    let moved = try await ledger.state(of: digest(0), kind: .build, project: "p-reapprove")
    check(moved.lastApprovedDigest == digest(0), "it is now the newest approval")
    _ = try await ledger.recordApproval(digest(1000), kind: .build, project: "p-reapprove")
    let kept = try await ledger.state(of: digest(0), kind: .build, project: "p-reapprove")
    check(kept.baseline == .approved, "the next approval past the cap pushes out another, not the re-approved one")
    let dropped = try await ledger.state(of: digest(1), kind: .build, project: "p-reapprove")
    check(dropped.baseline == .changed, "the oldest left is the one pushed out")
}

// MARK: - Approvals brought back by withdrawn grants keep their age order

do {
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("restore-order-approvals"))
    func digest(_ index: Int) -> String {
        "sha256:" + String(repeating: "3", count: 56) + String(format: "%08x", index)
    }
    for index in 0 ..< ApprovalLedger.maximumApprovals {
        if let grant = try await ledger.recordApproval(digest(index), kind: .build, project: "p-restore-order") {
            await ledger.confirmApproval(grant)
        }
    }
    // E pushes out 0, then F pushes out 1; both are withdrawn in the order
    // they were made.
    let grantE = try await ledger.recordApproval(digest(1000), kind: .build, project: "p-restore-order")
    let grantF = try await ledger.recordApproval(digest(1001), kind: .build, project: "p-restore-order")
    check(grantE?.evicted == digest(0) && grantF?.evicted == digest(1), "E and F each push out the oldest")
    if let grantE {
        try await ledger.withdrawApproval(grantE)
    }
    if let grantF {
        try await ledger.withdrawApproval(grantF)
    }
    // The next approval past the cap must push out 0 again, the oldest.
    if let grant = try await ledger.recordApproval(digest(2000), kind: .build, project: "p-restore-order") {
        await ledger.confirmApproval(grant)
    }
    let oldest = try await ledger.state(of: digest(0), kind: .build, project: "p-restore-order")
    let next = try await ledger.state(of: digest(1), kind: .build, project: "p-restore-order")
    check(
        oldest.baseline == .changed && next.baseline == .approved,
        "approvals put back in the order their grants were made keep their age order",
    )

    // Withdrawn the other way round, the same order comes back.
    let reverse = ApprovalLedger(directory: scratch.appendingPathComponent("restore-reverse-approvals"))
    for index in 0 ..< ApprovalLedger.maximumApprovals {
        if let grant = try await reverse.recordApproval(digest(index), kind: .build, project: "p-restore-reverse") {
            await reverse.confirmApproval(grant)
        }
    }
    let grantG = try await reverse.recordApproval(digest(1000), kind: .build, project: "p-restore-reverse")
    let grantH = try await reverse.recordApproval(digest(1001), kind: .build, project: "p-restore-reverse")
    if let grantH {
        try await reverse.withdrawApproval(grantH)
    }
    if let grantG {
        try await reverse.withdrawApproval(grantG)
    }
    if let grant = try await reverse.recordApproval(digest(2000), kind: .build, project: "p-restore-reverse") {
        await reverse.confirmApproval(grant)
    }
    let reverseOldest = try await reverse.state(of: digest(0), kind: .build, project: "p-restore-reverse")
    let reverseNext = try await reverse.state(of: digest(1), kind: .build, project: "p-restore-reverse")
    check(
        reverseOldest.baseline == .changed && reverseNext.baseline == .approved,
        "approvals put back in the reverse order keep their age order too",
    )
}

// MARK: - An agent-opened session keeps its opener across a restart

do {
    let state = scratch.appendingPathComponent("lineage-state")
    let session = UUID().uuidString
    let parent = UUID().uuidString
    let record = AgentSessionLineage.Record(parentSessionID: parent, depth: 2)
    AgentSessionLineage.save(record, session: session, state: state)
    check(AgentSessionLineage.load(session: session, state: state) == record, "a saved opener and depth read back")
    let folder = state.appendingPathComponent("agent-sessions")
    check(
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(session).json").path),
        "the record is the session's own file in agent-sessions",
    )
    var folderMetadata = stat()
    check(
        stat(folder.path, &folderMetadata) == 0 && folderMetadata.st_mode & 0o777 == 0o700,
        "the records' folder is its owner's alone",
    )
    check(AgentSessionLineage.load(session: UUID().uuidString, state: state) == nil, "another session has no opener")
    let escaped = state.appendingPathComponent("x.json")
    AgentSessionLineage.save(record, session: "../x", state: state)
    check(!FileManager.default.fileExists(atPath: escaped.path), "a session ID that is not a UUID writes nothing")
    try JSONCoding.encode(record).write(to: escaped)
    check(AgentSessionLineage.load(session: "../x", state: state) == nil, "and reads nothing, even with a file there")
}

// MARK: - A shell_run call its session stopped before it spawned does not run on

do {
    let session = UUID().uuidString
    // The call took its count, then a Stop came while it was being checked.
    let seen = AgentRunCode.stopCount(session: session)
    AgentRunCode.stop(session: session)
    var begin = Date()
    let stopped = await AgentRunCode.capture(
        ["/bin/sleep", "30"],
        environment: [],
        timeoutSeconds: 30,
        session: session,
        stopsSeen: seen,
    )
    var elapsed = Date().timeIntervalSince(begin)
    check(elapsed < 3, "a call stopped before it spawned ends as it spawns (it took \(elapsed) s)")
    check(
        stopped?.exitCode == 137 && stopped?.timedOut == false,
        "it is killed, not timed out: \(String(describing: stopped))",
    )
    check(AgentRunCode.stopCount(session: session) == seen + 1, "the stop is counted once")

    // A call that took its count after the stop runs to its own end.
    let later = AgentRunCode.stopCount(session: session)
    let finished = await AgentRunCode.capture(
        ["/bin/sleep", "1"],
        environment: [],
        timeoutSeconds: 30,
        session: session,
        stopsSeen: later,
    )
    check(
        finished?.exitCode == 0 && finished?.timedOut == false,
        "a call after the stop runs: \(String(describing: finished))",
    )

    // A stop while a call runs ends it.
    begin = Date()
    let running = Task.detached {
        await AgentRunCode.capture(
            ["/bin/sleep", "30"],
            environment: [],
            timeoutSeconds: 30,
            session: session,
            stopsSeen: later,
        )
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    AgentRunCode.stop(session: session)
    let killed = await running.value
    elapsed = Date().timeIntervalSince(begin)
    check(elapsed < 3 && killed?.exitCode == 137, "a stop ends a running call (\(elapsed) s, \(String(describing: killed)))")
}

// MARK: - A negative ustar size neither loops nor traps

do {
    /// One header and one zero block: `name`, a regular file, its size
    /// field spelled `size`.
    func tar(name: String, size: String) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 1024)
        bytes.replaceSubrange(0 ..< name.utf8.count, with: name.utf8)
        bytes.replaceSubrange(124 ..< 124 + size.utf8.count, with: size.utf8)
        bytes[156] = UInt8(ascii: "0")
        return bytes
    }
    // `body` on a thread of its own: a walk that never ends fails here
    // instead of hanging the harness.
    func returns(_ body: @escaping @Sendable () -> String?) -> (returned: Bool, value: String?) {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var value: String?
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Thread {
            let value = body()
            box.lock.withLock { box.value = value }
            done.signal()
        }.start()
        guard done.wait(timeout: .now() + 5) == .success else { return (false, nil) }
        return (true, box.lock.withLock { box.value })
    }

    let backwards = tar(name: "./x", size: "-2000")
    let walked = returns { DebControlPeek.controlFile(inTar: backwards) }
    check(walked.returned && walked.value == nil, "a negative size before ./control ends the walk")
    let inverted = tar(name: "./control", size: "-1")
    let read = returns { DebControlPeek.controlFile(inTar: inverted) }
    check(read.returned && read.value == nil, "a negative size on ./control is refused")

    let deb = scratchPath + "/negative-size.deb"
    FileManager.default.createFile(
        atPath: deb,
        contents: arArchive([("debian-binary", Data("2.0\n".utf8)), ("control.tar", Data(backwards))]),
    )
    let descriptor = open(deb, O_RDONLY)
    defer { close(descriptor) }
    let outcome = returns {
        do {
            _ = try DebControlPeek.read(descriptor: descriptor)
            return "read"
        } catch DebControlPeek.Failure.unreadable {
            return "unreadable"
        } catch {
            return "\(error)"
        }
    }
    check(outcome.returned && outcome.value == "unreadable", "a deb with that control member is unreadable: \(outcome)")
}

// MARK: - One file's backups are never another's

do {
    let root = scratchPath + "/backup-root"
    let home = root + "/var/mobile"
    try FileManager.default.createDirectory(
        atPath: home + "/Documents/wiki.qaq.apelin",
        withIntermediateDirectories: true,
    )
    write(root + "/etc/a_b", "underscore\n")
    write(root + "/etc/a/b", "nested\n")
    let store = BackupStore(home: home)
    let underscore = try store.save(path: root + "/etc/a_b")
    // Names are stamped to the millisecond and made with O_EXCL.
    for _ in 0 ..< 11 {
        usleep(2000)
        _ = try store.save(path: root + "/etc/a/b")
    }
    check(store.list(for: root + "/etc/a_b") == [underscore], "a/b's backups do not prune a_b's")
    let nested = store.list(for: root + "/etc/a/b")
    check(nested.count == 10 && !nested.contains(underscore), "a/b keeps its own newest ten, none of a_b's")

    check(
        BackupStore.key(for: "/x-var/jb/etc/hosts") != BackupStore.key(for: "/var/jb/etc/hosts"),
        "a path ending in another's has another key",
    )
    // A backup of /x-var/jb/etc/hosts: its name ends in /var/jb/etc/hosts's
    // flattened path, and is still not that file's.
    let other = "20261022-000000-000-" + BackupStore.key(for: "/x-var/jb/etc/hosts")
    FileManager.default.createFile(atPath: store.folder + "/" + other, contents: Data())
    check(!store.list(for: "/var/jb/etc/hosts").contains(other), "a backup is listed for its own file only")
}

print("\(checks - failures)/\(checks) session host checks passed")
exit(failures == 0 ? 0 : 1)

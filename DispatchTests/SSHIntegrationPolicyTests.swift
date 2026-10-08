import XCTest
@testable import DispatchApp

final class SSHIntegrationPolicyTests: XCTestCase {
    @MainActor
    func testAgentSetupChoicesPersistBothAnswersWithoutTreatingAbsenceAsRefusal() async throws {
        let name = "SSHAgentSetupTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SSHIntegrationPermissions(defaults: defaults), target = scope()
        let grant = SSHIntegrationGrant(profile: .full, hooks: true)
        store.save(grant, for: target)
        XCTAssertEqual(SSHHookAgent.allCases.map { store.hooks(target, agent: $0) }, [nil, nil, nil])
        for (agent, answer) in [(SSHHookAgent.codex, true), (.claude, false)] {
            let result = await store.chooseHooks(target, agent: agent) { answer }
            XCTAssertEqual(result, answer)
        }
        let canceled = await store.chooseHooks(target, agent: .pi) { nil }
        XCTAssertNil(canceled)
        store.save(grant, for: target)
        let restored = SSHIntegrationPermissions(defaults: defaults)
        XCTAssertEqual(SSHHookAgent.allCases.map { restored.hooks(target, agent: $0) }, [true, false, nil])
        for agent in [SSHHookAgent.codex, .claude] {
            let result = await restored.chooseHooks(target, agent: agent) { XCTFail("A saved decision must not prompt again"); return nil }
            XCTAssertEqual(result, agent == .codex)
        }
        XCTAssertEqual(SSHHookAgent.allCases.map { restored.hooks(scope(user: "bob"), agent: $0) }, [nil, nil, nil])
        let installedLater = await restored.chooseHooks(target, agent: .pi) { true }
        XCTAssertEqual(installedLater, true)
        restored.reset(target)
        XCTAssertEqual(SSHHookAgent.allCases.map { restored.hooks(target, agent: $0) }, [nil, nil, nil])
    }

    @MainActor
    func testCanceledAgentSetupWaitersCannotSaveLateAnswers() async {
        for remaining in [false, true] {
            let store = SSHIntegrationPermissions(defaults: nil), target = scope()
            store.save(.init(profile: .full, hooks: true), for: target)
            var finish: CheckedContinuation<Bool?, Never>?
            var prompts = 0
            let present: @MainActor () async -> Bool? = {
                prompts += 1
                return await withCheckedContinuation { finish = $0 }
            }
            let first = Task { await store.chooseHooks(target, agent: .pi, present: present) }
            while finish == nil { await Task.yield() }
            var started = false
            let second = remaining ? Task { started = true; return await store.chooseHooks(target, agent: .pi, present: present) } : nil
            while remaining && !started { await Task.yield() }
            first.cancel()
            finish?.resume(returning: true)
            let canceled = await first.value
            let answer = await second?.value
            XCTAssertNil(canceled)
            XCTAssertEqual(answer, remaining ? true : nil)
            XCTAssertEqual(store.hooks(target, agent: .pi), remaining ? true : nil)
            XCTAssertEqual(prompts, 1)
        }
    }

    @MainActor
    func testConcurrentAgentSetupChoicesCannotUndoRevocationOrReset() async {
        for reset in [false, true] {
            let store = SSHIntegrationPermissions(defaults: nil), target = scope()
            store.save(.init(profile: .full, hooks: true), for: target)
            var finish: CheckedContinuation<Bool?, Never>?
            var prompts = 0
            let present: @MainActor () async -> Bool? = {
                prompts += 1
                return await withCheckedContinuation { finish = $0 }
            }
            let first = Task { await store.chooseHooks(target, agent: .pi, present: present) }
            while finish == nil { await Task.yield() }
            var started = false
            let second = Task { started = true; return await store.chooseHooks(target, agent: .pi, present: present) }
            while !started { await Task.yield() }
            if reset { store.resetAll() }
            else { store.save(.init(profile: .full, hooks: false), for: target) }
            finish?.resume(returning: true)
            let answers = await [first.value, second.value]
            XCTAssertEqual(answers, [nil, nil])
            XCTAssertEqual(prompts, 1)
            XCTAssertNil(store.hooks(target, agent: .pi))
        }
    }

    func testStatsPermissionDisclosesProcessEnumeration() {
        XCTAssertTrue(SSHIntegrationFeature.statistics.detail.contains("processes"))
        XCTAssertTrue(SSHIntegrationFeature.statistics.capabilities.contains("stats.processes"))
    }

    func testIndividualFeaturesRoundTripAndNeverEnableUnselectedOperations() throws {
        for mask in 0..<(1 << SSHIntegrationFeature.allCases.count) {
            let selected = Set(SSHIntegrationFeature.allCases.enumerated().compactMap { index, feature in
                mask & (1 << index) == 0 ? nil : feature
            })
            let grant = SSHIntegrationGrant(helperEnabled: true, features: selected)
            XCTAssertTrue(grant.isCurrent)
            XCTAssertEqual(try JSONDecoder().decode(SSHIntegrationGrant.self, from: JSONEncoder().encode(grant)), grant)
            XCTAssertEqual(grant.capabilities.contains("stats.sample"), selected.contains(.statistics))
            XCTAssertEqual(grant.capabilities.contains("tmux.pane"), selected.contains(.tmux))
            XCTAssertEqual(grant.capabilities.contains("herdr.start"), selected.contains(.herdr))
            XCTAssertEqual(grant.capabilities.contains("agent.inspect"), selected.contains(.chat))
            XCTAssertEqual(grant.capabilities.contains("agent.side"), selected.contains(.chat))
            XCTAssertEqual(grant.hooks, selected.contains(.hooks))
            let reduced = SSHIntegrationGrant(profile: .full, hooks: true).reduced(to: grant)
            XCTAssertEqual(reduced, grant)
            XCTAssertTrue(grant.reduced(to: .init(profile: .full, hooks: true)).capabilities.isSubset(of: grant.capabilities))
        }
        let plain = SSHIntegrationGrant(helperEnabled: false, features: Set(SSHIntegrationFeature.allCases))
        XCTAssertTrue(plain.capabilities.isEmpty)
        XCTAssertEqual(plain.profile, .ordinary)
    }

    private func scope(user: String = "alice", destination: String = "build", executable: String = "/usr/bin/ssh", suffix: String = "") -> SSHIntegrationScope {
        SSHIntegrationScope(executable: executable, destination: destination, configuration: "hostname machine\nuser \(user)\n" + suffix)!
    }

    func testGrantsDoNotTransferBetweenAccountsAliasesExecutablesOrConfigurations() {
        let base = scope()
        for other in [scope(user: "bob"), scope(destination: "alias"), scope(executable: "/opt/bin/ssh"), scope(suffix: "identityfile /new/key\n")] {
            XCTAssertNotEqual(base.key, other.key)
        }
        XCTAssertEqual(base.key, scope().key)
        XCTAssertNil(SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "host", configuration: "hostname host"))
        XCTAssertNil(SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "host", configuration: "user a\nuser b"))
    }

    @MainActor
    func testNativeSSHClonesReusePersistedConsentWithoutDuplicatingForwarding() async throws {
        let suite = "SSHCloneConsentTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for forwarding in [[], ["-L", "19001:localhost:22", "-R", "19002:localhost:22", "-D", "19003"]] {
            let original = try XCTUnwrap(SSHInvocation.parse(
                ["-F", "/dev/null", "-l", "dispatch-test"] + forwarding + ["example.invalid"], isTerminal: true))
            // Use real OpenSSH -G to represent a choice saved before this fix.
            // It resolves locally and never connects to example.invalid.
            let previous = try await SSHCommand.run(executable: "/usr/bin/ssh", arguments:
                ["-G"] + original.options + ["--", original.destination])
            XCTAssertEqual(previous.status, 0)
            let originalScope = try XCTUnwrap(SSHIntegrationScope(executable: "/usr/bin/ssh", destination: original.destination,
                configuration: String(decoding: previous.output, as: UTF8.self)))
            for profile in SSHIntegrationProfile.allCases {
                let grant = SSHIntegrationGrant(profile: profile, hooks: profile == .full)
                SSHIntegrationPermissions(defaults: defaults).save(grant, for: originalScope)
                let store = SSHIntegrationPermissions(defaults: defaults)
                var invocation = original
                var prompts = 0
                for _ in 0..<3 {
                    // SSHLaunchRequest retains these original options; Command-N
                    // turns its SSHShell into a fresh native terminal command.
                    let shell = SSHShell(destination: invocation.destination, options: invocation.options)
                    invocation = try XCTUnwrap(SSHInvocation.parse(shell.arguments, isTerminal: true))
                    let config = try XCTUnwrap(SSHLauncherCommand.resolvedConfiguration(invocation, executable: shell.executable))
                    let cloneScope = try XCTUnwrap(SSHIntegrationScope(executable: shell.executable, destination: shell.destination, configuration: config))
                    XCTAssertEqual(cloneScope, originalScope)
                    let remembered = await store.choose(cloneScope) { _ in prompts += 1; return nil }
                    XCTAssertEqual(remembered, grant)
                    // Verify the actual connection still suppresses forwarded
                    // listeners, independently of consent normalization.
                    let actual = try await SSHCommand.run(executable: shell.executable,
                        arguments: ["-G"] + invocation.options + ["--", invocation.destination])
                    let effective = String(decoding: actual.output, as: UTF8.self)
                    XCTAssertTrue(effective.contains("clearallforwardings yes\n"))
                    XCTAssertFalse(effective.contains("localforward "))
                    XCTAssertFalse(effective.contains("remoteforward "))
                }
                XCTAssertEqual(prompts, 0, "Command-N must reuse the persisted choice for this account and configuration")
            }
        }
    }

    func testConfigurationReplayDoesNotLaunchSSH() throws {
        let configuration = "hostname example.invalid\nuser dispatch-test\n"
        let bytes = try AppReplay.query(kind: "fixture.ssh.configuration", input: Data()) {
            let directory = Home.url.appendingPathComponent("ssh-configuration-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let executable = directory.appendingPathComponent("ssh")
            try Data(("#!/bin/sh\nprintf '%s\\n' 'hostname example.invalid' 'user dispatch-test'\n").utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            return try JSONEncoder().encode(directory.path)
        }
        let directory = URL(fileURLWithPath: try JSONDecoder().decode(String.self, from: bytes))
        defer { if !AppReplay.replaying { try? FileManager.default.removeItem(at: directory) } }
        let executable = directory.appendingPathComponent("ssh")
        if AppReplay.replaying { XCTAssertFalse(FileManager.default.fileExists(atPath: executable.path)) }
        let invocation = try XCTUnwrap(SSHInvocation.parse(["example.invalid"], isTerminal: true))
        XCTAssertEqual(SSHLauncherCommand.resolvedConfiguration(invocation, executable: executable.path), configuration)
    }

    func testCloneConsentStillDistinguishesResolvedAccountRouteAndIdentity() throws {
        func resolved(_ options: [String]) throws -> SSHIntegrationScope {
            let invocation = try XCTUnwrap(SSHInvocation.parse(
                ["-F", "/dev/null", "-o", "ClearAllForwardings=yes"] + options + ["example.invalid"], isTerminal: true))
            let config = try XCTUnwrap(SSHLauncherCommand.resolvedConfiguration(invocation, executable: "/usr/bin/ssh"))
            return try XCTUnwrap(SSHIntegrationScope(executable: "/usr/bin/ssh", destination: invocation.destination, configuration: config))
        }
        let base = try resolved(["-l", "alice"])
        for options in [["-l", "bob"], ["-l", "alice", "-p", "2222"],
                        ["-l", "alice", "-o", "IdentityFile=/tmp/different-key"],
                        ["-l", "alice", "-o", "HostName=other.invalid"],
                        ["-l", "alice", "-o", "ProxyCommand=/usr/bin/false"]] {
            XCTAssertNotEqual(try resolved(options), base)
        }
    }

    func testCapabilitiesAndLiveReductions() {
        let full = SSHIntegrationGrant(profile: .full, hooks: true)
        for profile in SSHIntegrationProfile.allCases {
            let grant = SSHIntegrationGrant(profile: profile)
            XCTAssertTrue(grant.isCurrent)
            XCTAssertFalse(grant.hooks)
            XCTAssertEqual(grant.capabilities.contains("stats.ping"), profile != .ordinary)
            XCTAssertTrue(grant.capabilities.isDisjoint(with: ["exec", "socket", "file.replace"]))
        }
        XCTAssertEqual(full.reduced(to: .init(profile: .statistics)).profile, .statistics)
        XCTAssertFalse(full.reduced(to: .init(profile: .full)).hooks)
        XCTAssertTrue(full.capabilities.isSuperset(of: ["agent.inspect", "agent.pi", "agent.pi.configure"]))
        XCTAssertTrue(SSHIntegrationGrant(profile: .full).capabilities.isDisjoint(with: ["agent.pi", "agent.pi.configure"]))
        XCTAssertEqual(SSHIntegrationGrant(profile: .statistics).reduced(to: full).profile, .statistics)
        XCTAssertEqual(SSHIntegrationGrant(profile: .ordinary).reduced(to: full).profile, .ordinary)
    }

    func testRememberedStatisticsChoiceIncludesLatencyWithoutChangingItsProfile() throws {
        for profile in SSHIntegrationProfile.allCases {
            let grant = SSHIntegrationGrant(profile: profile)
            var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(grant)) as? [String: Any])
            stored["capabilities"] = grant.capabilities.subtracting(["stats.ping"]).sorted()
            let restored = try JSONDecoder().decode(SSHIntegrationGrant.self, from: JSONSerialization.data(withJSONObject: stored))
            XCTAssertEqual(restored, grant)
            XCTAssertTrue(restored.isCurrent)
            XCTAssertFalse(restored.reduced(to: .init(profile: .ordinary)).capabilities.contains("stats.ping"))
        }
    }

    func testRemoteSideCapabilityDoesNotSilentlyUpgradeSavedChatGrants() throws {
        for current in [SSHIntegrationGrant(profile: .full), .init(helperEnabled: true, features: [.chat])] {
            var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
            stored["capabilities"] = current.capabilities.subtracting(["agent.side"]).sorted()
            let previous = try JSONDecoder().decode(SSHIntegrationGrant.self, from: JSONSerialization.data(withJSONObject: stored))
            XCTAssertFalse(previous.isCurrent)
            XCTAssertFalse(previous.capabilities.contains("agent.side"))
            XCTAssertFalse(previous.reduced(to: current).capabilities.contains("agent.side"))
        }
    }

    func testNewCapabilitiesRequireConsentAndNeverEnterLiveReductions() throws {
        let current = SSHIntegrationGrant(profile: .full)
        var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        stored["capabilities"] = current.capabilities.subtracting(["tmux.pane"]).sorted()
        let previous = try JSONDecoder().decode(SSHIntegrationGrant.self, from: JSONSerialization.data(withJSONObject: stored))
        XCTAssertFalse(previous.isCurrent)
        XCTAssertFalse(previous.reduced(to: current).capabilities.contains("tmux.pane"))
        XCTAssertFalse(current.reduced(to: previous).capabilities.contains("tmux.pane"))
        XCTAssertFalse(previous.reduced(to: current).isCurrent)
        XCTAssertTrue(previous.reduced(to: .init(profile: .statistics)).isCurrent)
        stored["revision"] = 0
        let oldRevision = try JSONDecoder().decode(SSHIntegrationGrant.self, from: JSONSerialization.data(withJSONObject: stored))
        XCTAssertFalse(oldRevision.reduced(to: current).isCurrent)
    }

    @MainActor
    func testRememberingCancellationAndConcurrentPromptDeduplication() async {
        let store = SSHIntegrationPermissions(defaults: nil), target = scope()
        var prompts = 0
        let present: @MainActor (SSHIntegrationScope) async -> SSHIntegrationSelection? = { _ in
            prompts += 1
            try? await Task.sleep(for: .milliseconds(20))
            return nil
        }
        async let first = store.choose(target, present: present)
        async let second = store.choose(target, present: present)
        let results = await [first, second]
        XCTAssertEqual(prompts, 1)
        XCTAssertTrue(results.allSatisfy { $0 == nil })
        XCTAssertNil(store.remembered(target))
        store.save(.init(profile: .statistics), for: target)
        let remembered = await store.choose(target, present: present)
        XCTAssertEqual(remembered?.profile, .statistics)
        XCTAssertEqual(prompts, 1)
        XCTAssertNil(store.remembered(scope(user: "bob")))
    }

    @MainActor
    func testSettingsChoiceSupersedesAnOpenConsentPromptForEveryWaiter() async {
        let store = SSHIntegrationPermissions(defaults: nil), target = scope()
        var finish: CheckedContinuation<SSHIntegrationSelection?, Never>?
        var prompts = 0
        var changes: [SSHIntegrationProfile] = []
        store.onChange = { _, grant in changes.append(grant.profile) }
        let present: @MainActor (SSHIntegrationScope) async -> SSHIntegrationSelection? = { _ in
            prompts += 1
            return await withCheckedContinuation { finish = $0 }
        }
        let first = Task { await store.choose(target, present: present) }
        while finish == nil { await Task.yield() }
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return await store.choose(target, present: present)
        }
        while !secondStarted { await Task.yield() }
        store.save(.init(profile: .ordinary), for: target)
        // A presenter may complete despite cancellation (for example a native
        // sheet callback already queued). Its obsolete Full result must lose.
        finish?.resume(returning: .init(grant: .init(profile: .full, hooks: true)))
        let results = await [first.value, second.value]
        XCTAssertEqual(prompts, 1)
        XCTAssertTrue(results.allSatisfy { $0?.profile == .ordinary && $0?.hooks == false })
        XCTAssertEqual(store.remembered(target)?.profile, .ordinary)
        XCTAssertEqual(changes, [.ordinary])
        let next = await store.choose(target, present: present)
        XCTAssertEqual(next?.profile, .ordinary)
        XCTAssertEqual(prompts, 1)
    }

    @MainActor
    func testConcurrentConsentWaitersShareOnePersistedGrant() async {
        let store = SSHIntegrationPermissions(defaults: nil), target = scope()
        var finish: CheckedContinuation<SSHIntegrationSelection?, Never>?
        var prompts = 0, changes = 0
        store.onChange = { _, _ in changes += 1 }
        let present: @MainActor (SSHIntegrationScope) async -> SSHIntegrationSelection? = { _ in
            prompts += 1
            return await withCheckedContinuation { finish = $0 }
        }
        let first = Task { await store.choose(target, present: present) }
        while finish == nil { await Task.yield() }
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return await store.choose(target, present: present)
        }
        while !secondStarted { await Task.yield() }
        let grant = SSHIntegrationGrant(profile: .full, hooks: true)
        finish?.resume(returning: .init(grant: grant))
        let results = await [first.value, second.value]
        XCTAssertEqual(results, [grant, grant])
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(store.remembered(target), grant)
    }

    @MainActor
    func testPersistenceIsSeparateFromHostRegistry() {
        let name = "SSHIntegrationPolicyTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SSHIntegrationPermissions(defaults: defaults)
        store.save(.init(profile: .full), for: scope())
        XCTAssertEqual(SSHIntegrationPermissions(defaults: defaults).remembered(scope())?.profile, .full)
        XCTAssertNil(defaults.data(forKey: "HostRegistry.v1"))
    }

    @MainActor
    func testResetForgetsOnlyTheSelectedScopeAndPublishesRevocation() throws {
        let name = "SSHResetTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SSHIntegrationPermissions(defaults: defaults), target = scope(), other = scope(user: "bob")
        store.save(.init(profile: .full, hooks: true), for: target)
        store.save(.init(profile: .statistics), for: other)
        var revoked: SSHIntegrationGrant?
        store.onChange = { changed, grant in XCTAssertEqual(changed, target); revoked = grant }
        store.reset(target)
        XCTAssertNil(store.remembered(target))
        XCTAssertNil(SSHIntegrationPermissions(defaults: defaults).remembered(target))
        XCTAssertEqual(store.remembered(other)?.profile, .statistics)
        XCTAssertEqual(revoked?.profile, .ordinary)
        XCTAssertEqual(revoked?.hooks, false)
    }

    @MainActor
    func testResetInvalidatesAnOpenPromptAndNextLoginPromptsAgain() async {
        let store = SSHIntegrationPermissions(defaults: nil), target = scope()
        var finish: CheckedContinuation<SSHIntegrationSelection?, Never>?
        let choice = Task { await store.choose(target, present: { _ in
            await withCheckedContinuation { finish = $0 }
        }) }
        while finish == nil { await Task.yield() }
        store.reset(target)
        finish?.resume(returning: .init(grant: .init(profile: .full, hooks: true)))
        let obsolete = await choice.value
        XCTAssertNil(obsolete)
        XCTAssertNil(store.remembered(target))
        var presented = false
        let next = await store.choose(target, present: { _ in presented = true; return .init(grant: .init(profile: .ordinary)) })
        XCTAssertTrue(presented)
        XCTAssertEqual(next?.profile, .ordinary)
    }

    @MainActor
    func testResetAllClearsEveryHostAndAccountPersistsAndRevokesLiveGrants() throws {
        let name = "SSHResetAllTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SSHIntegrationPermissions(defaults: defaults)
        let scopes = [scope(), scope(user: "bob"), scope(destination: "archive"), scope(suffix: "identityfile /other/key\n")]
        for (index, target) in scopes.enumerated() {
            store.save(.init(profile: index == 2 ? .ordinary : (index == 1 ? .statistics : .full), hooks: index == 0), for: target)
        }
        var revoked: Set<String> = []
        store.onChange = { target, grant in
            XCTAssertTrue(store.entries.isEmpty, "Clear the list before publishing revocations")
            XCTAssertTrue(SSHIntegrationPermissions(defaults: defaults).entries.isEmpty)
            XCTAssertEqual(grant.profile, .ordinary)
            XCTAssertTrue(grant.capabilities.isEmpty)
            revoked.insert(target.key)
        }
        store.resetAll()
        XCTAssertEqual(revoked, Set(scopes.map(\.key)))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(SSHIntegrationPermissions(defaults: defaults).entries.isEmpty)
        store.resetAll()
        XCTAssertEqual(revoked.count, scopes.count)
    }

    @MainActor
    func testResetAllCancelsPendingChoicesWithoutRestoringOldPermissions() async {
        let store = SSHIntegrationPermissions(defaults: nil)
        var finishes: [CheckedContinuation<SSHIntegrationSelection?, Never>] = []
        let scopes = [scope(), scope(destination: "archive")]
        let choices = scopes.map { target in Task { await store.choose(target, present: { _ in
            await withCheckedContinuation { finishes.append($0) }
        }) } }
        while finishes.count < 2 { await Task.yield() }
        store.resetAll()
        for finish in finishes { finish.resume(returning: .init(grant: .init(profile: .full, hooks: true))) }
        for choice in choices { let result = await choice.value; XCTAssertNil(result) }
        XCTAssertTrue(store.entries.isEmpty)
        var prompts = 0
        _ = await store.choose(scopes[0], present: { _ in prompts += 1; return .init(grant: .init(profile: .statistics)) })
        XCTAssertEqual(prompts, 1)
    }

}

extension SSHIntegrationPolicyTests {
    func testProcessCapabilityRenewsBothEnhancedGrantsWithoutUpgradingLiveConnections() throws {
        for profile in [SSHIntegrationProfile.statistics, .full] {
            let current = SSHIntegrationGrant(profile: profile)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
            json["capabilities"] = current.capabilities.subtracting(["stats.processes"]).sorted()
            let previous = try JSONDecoder().decode(SSHIntegrationGrant.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertFalse(previous.isCurrent)
            XCTAssertFalse(previous.reduced(to: current).capabilities.contains("stats.processes"))
            XCTAssertTrue(current.capabilities.contains("stats.processes"))
        }
        XCTAssertTrue(SSHIntegrationGrant(profile: .ordinary).isCurrent)
        XCTAssertTrue(SSHIntegrationGrant(profile: .ordinary).capabilities.isEmpty)
    }
}

internal import GitKit
import Darwin
import Foundation

/// How far the upload of a push has got.
public struct GitPushProgress: Sendable, Equatable {
    public var current: Int
    public var total: Int
    public var bytes: Int
}

/// One reference a fetch moved: `from` is nil for one it made.
public struct GitRefUpdate: Sendable, Equatable {
    public var ref: String
    public var from: String?
    public var to: String
}

public struct GitFetchResult: Sendable, Equatable {
    public var remote: String
    public var updated: [GitRefUpdate]
}

public struct GitPullResult: Sendable, Equatable {
    public var branch: String
    /// Where the branch was; nil when it had no commit yet.
    public var from: String?
    public var to: String
    public var upToDate: Bool
}

public struct GitPushResult: Sendable, Equatable {
    public var remote: String
    public var branch: String
    public var commit: String
}

/// Talking to a remote: fetch, a fast-forward pull, and push. A remote is
/// named, never a URL, so what is fetched from or pushed to is what the
/// repository's configuration says; the caller checked that URL before.
public extension GitRepository {
    /// Fetches the remote's configured refspecs into its remote-tracking
    /// references, tags following as git's default does. The work tree, the
    /// index and every branch are left alone. `progress` stops the fetch by
    /// answering false; it then throws `cancelled`.
    func fetch(
        remote name: String = "origin",
        credentials: GitCredentialLookup? = nil,
        progress: @escaping (GitCloneProgress) -> Bool = { _ in true },
    ) throws -> GitFetchResult {
        let remote = try lookupRemote(name)
        defer { git_remote_free(remote) }
        let callbacks = RemoteCallbacks(credentials: credentials)
        callbacks.fetchProgress = progress
        var options = git_fetch_options()
        git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION))
        callbacks.install(&options.callbacks)
        let code = withExtendedLifetime(callbacks) { git_remote_fetch(remote, nil, &options, nil) }
        guard code == 0 else { throw callbacks.failure(code, "fetch \(name)") }
        return GitFetchResult(remote: name, updated: callbacks.updates)
    }

    /// Fetches, then moves the checked-out branch forward to its upstream:
    /// `branch.<name>.merge` when `branch.<name>.remote` is the remote
    /// fetched, else `<remote>/<name>`. `remote` nil is the branch's own
    /// remote, else `origin`.
    ///
    /// Only a fast-forward: a branch with commits its upstream does not have
    /// throws `notFastForward`, and a change in the work tree or the index
    /// the new commit would overwrite (an untracked or ignored file in the
    /// way included) `conflict`. Either way nothing is changed but the remote-tracking
    /// references the fetch moved.
    func pull(
        remote: String? = nil,
        credentials: GitCredentialLookup? = nil,
        progress: @escaping (GitCloneProgress) -> Bool = { _ in true },
    ) throws -> GitPullResult {
        guard let branch = head().branch else { throw GitError(.invalid, "HEAD is not on a branch") }
        let local = "refs/heads/" + branch
        let configured = localConfigValue("branch.\(branch).remote")
        let remoteName = remote ?? configured ?? "origin"
        let upstream: String
        if configured == remoteName, localConfigValue("branch.\(branch).merge") != nil {
            var buffer = git_buf()
            defer { git_buf_dispose(&buffer) }
            try GitError.check(git_branch_upstream_name(&buffer, pointer, local), "find \(branch)'s upstream")
            upstream = String(cString: buffer.ptr)
        } else {
            upstream = "refs/remotes/\(remoteName)/\(branch)"
        }

        _ = try fetch(remote: remoteName, credentials: credentials, progress: progress)

        var target = git_oid()
        guard git_reference_name_to_id(&target, pointer, upstream) == 0 else {
            throw GitError(.notFound, "\(remoteName) has no branch for \(branch) (\(upstream))")
        }
        let to = Self.hex(&target)
        let from = head().commit
        if from == to {
            return GitPullResult(branch: branch, from: from, to: to, upToDate: true)
        }

        var annotated: OpaquePointer?
        try GitError.check(git_annotated_commit_lookup(&annotated, pointer, &target), "read \(upstream)")
        defer { git_annotated_commit_free(annotated) }
        var analysis = git_merge_analysis_t(rawValue: 0)
        var preference = git_merge_preference_t(rawValue: 0)
        var heads: [OpaquePointer?] = [annotated]
        try GitError.check(
            git_merge_analysis(&analysis, &preference, pointer, &heads, 1),
            "compare \(branch) with \(upstream)",
        )
        if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 {
            return GitPullResult(branch: branch, from: from, to: from ?? to, upToDate: true)
        }
        let fastForward = GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue | GIT_MERGE_ANALYSIS_UNBORN.rawValue
        guard analysis.rawValue & fastForward != 0 else {
            throw GitError(
                .notFastForward,
                "\(branch) and \(upstream) have diverged: a pull only fast-forwards, so merge or rebase them first",
            )
        }

        var commit: OpaquePointer?
        try GitError.check(git_commit_lookup(&commit, pointer, &target), "read \(upstream)'s commit")
        defer { git_commit_free(commit) }
        let checkout = CheckoutRecord()
        let code = checkout.run { options in git_checkout_tree(pointer, commit, &options) }
        guard code == 0 else { throw checkout.failure(code, "fast-forward \(branch)") }

        var moved: OpaquePointer?
        defer { git_reference_free(moved) }
        let message = "pull: fast-forward to \(upstream)"
        if let from {
            var current = git_oid()
            try GitError.check(git_oid_fromstr(&current, from), "read \(branch)")
            try GitError.check(
                git_reference_create_matching(&moved, pointer, local, &target, 1, &current, message),
                "move \(branch)",
            )
        } else {
            try GitError.check(git_reference_create(&moved, pointer, local, &target, 0, message), "make \(branch)")
        }
        return GitPullResult(branch: branch, from: from, to: to, upToDate: false)
    }

    /// Pushes `branch` (nil: the checked-out one) to the branch of the same
    /// name on `remote`, never forced, then records it as the branch's
    /// upstream (`branch.<name>.remote` and `.merge`). An update the remote
    /// refuses — one that is not a fast-forward, or a hook's no — throws
    /// `rejected` and records nothing.
    func push(
        remote name: String = "origin",
        branch: String? = nil,
        credentials: GitCredentialLookup? = nil,
        progress: @escaping (GitPushProgress) -> Bool = { _ in true },
    ) throws -> GitPushResult {
        guard let branch = branch ?? head().branch else {
            throw GitError(.invalid, "HEAD is not on a branch: name the branch to push")
        }
        try Self.checkBranchName(branch)
        let local = "refs/heads/" + branch
        var commit = git_oid()
        guard git_reference_name_to_id(&commit, pointer, local) == 0 else {
            throw GitError(.notFound, "no branch \(branch) with a commit to push")
        }
        let remote = try lookupRemote(name)
        defer { git_remote_free(remote) }
        let callbacks = RemoteCallbacks(credentials: credentials)
        callbacks.pushProgress = progress
        var options = git_push_options()
        git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION))
        callbacks.install(&options.callbacks)
        let code = withExtendedLifetime(callbacks) {
            Self.withStrings(["\(local):\(local)"]) { refspecs in
                var refspecs = refspecs
                return git_remote_push(remote, &refspecs, &options)
            }
        }
        if code == GIT_ENONFASTFORWARD.rawValue {
            throw GitError(.rejected, "\(name)'s \(branch) has commits this one does not: pull first")
        }
        guard code == 0 else { throw callbacks.failure(code, "push \(branch) to \(name)") }
        if let rejected = callbacks.rejections.first {
            throw GitError(.rejected, "\(name) refused \(rejected.ref): \(rejected.status)")
        }
        try setLocalConfigValue(name, for: "branch.\(branch).remote")
        try setLocalConfigValue(local, for: "branch.\(branch).merge")
        return GitPushResult(remote: name, branch: branch, commit: Self.hex(&commit))
    }

    /// Adds each pattern not already there to `.git/info/exclude`, the
    /// repository's own ignore list, which is never committed or pushed.
    func addExcludes(_ patterns: [String]) throws {
        guard !patterns.contains(where: { $0.isEmpty || $0.contains("\n") || $0.utf8.contains(0) }) else {
            throw GitError(.invalid, "bad exclude pattern")
        }
        guard let path = git_repository_path(pointer) else { throw GitError(.notFound, "no git directory") }
        let info = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            .appendingPathComponent("info", isDirectory: true)
        if mkdir(info.path, 0o755) != 0, errno != EEXIST {
            throw GitError(.failed, "make .git/info: \(String(cString: strerror(errno)))")
        }
        let file = info.appendingPathComponent("exclude")
        var text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let present = Set(text.split(separator: "\n").map(String.init))
        let missing = patterns.filter { !present.contains($0) }
        guard !missing.isEmpty else { return }
        if !text.isEmpty, !text.hasSuffix("\n") {
            text += "\n"
        }
        text += missing.joined(separator: "\n") + "\n"
        do {
            try Data(text.utf8).write(to: file, options: .atomic)
        } catch {
            throw GitError(.failed, "write .git/info/exclude: \(error)")
        }
    }

    // MARK: Helpers

    /// Makes a bare repository at `url`, whose HEAD names `initialBranch`:
    /// the remote the tests fetch from and push to.
    internal static func createBare(at url: URL, initialBranch: String = "main") throws {
        GitLibrary.ensure()
        var options = git_repository_init_options()
        git_repository_init_options_init(&options, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION))
        options.flags = GIT_REPOSITORY_INIT_MKPATH.rawValue | GIT_REPOSITORY_INIT_NO_REINIT.rawValue
            | GIT_REPOSITORY_INIT_BARE.rawValue
        var repository: OpaquePointer?
        let code = initialBranch.withCString { branch -> Int32 in
            options.initial_head = branch
            return git_repository_init_ext(&repository, url.path, &options)
        }
        try GitError.check(code, "create a bare repository at \(url.lastPathComponent)")
        git_repository_free(repository)
    }

    /// Adds the remote `name` fetching from `url` with git's default refspec.
    func addRemote(_ name: String, url: String) throws {
        guard !name.utf8.contains(0), !url.utf8.contains(0) else { throw GitError(.invalid, "bad remote") }
        var remote: OpaquePointer?
        try GitError.check(git_remote_create(&remote, pointer, name, url), "add the remote \(name)")
        git_remote_free(remote)
    }

    /// Removes the remote `name`, with its remote-tracking references.
    func removeRemote(_ name: String) throws {
        guard !name.utf8.contains(0) else { throw GitError(.invalid, "\(name.debugDescription) is not a remote name") }
        try GitError.check(git_remote_delete(pointer, name), "remove the remote \(name)")
    }

    /// The remote `name`. The caller frees it.
    internal func lookupRemote(_ name: String) throws -> OpaquePointer {
        var valid: Int32 = 0
        guard !name.utf8.contains(0), git_remote_name_is_valid(&valid, name) == 0, valid != 0 else {
            throw GitError(.invalid, "\(name.debugDescription) is not a remote name")
        }
        var remote: OpaquePointer?
        let code = git_remote_lookup(&remote, pointer, name)
        guard code == 0, let remote else {
            if code == GIT_ENOTFOUND.rawValue {
                throw GitError(.notFound, "no remote \(name)")
            }
            throw GitError.last(code, "read the remote \(name)")
        }
        return remote
    }

    /// Whether libgit2 takes `name` for a branch, and it cannot be read as
    /// an option.
    static func isValidBranchName(_ name: String) -> Bool {
        GitLibrary.ensure()
        var valid: Int32 = 0
        return !name.utf8.contains(0)
            && !name.hasPrefix("-")
            && git_branch_name_is_valid(&valid, name) == 0
            && valid != 0
    }

    internal static func checkBranchName(_ name: String) throws {
        guard isValidBranchName(name) else { throw GitError(.invalid, "\(name.debugDescription) is not a branch name") }
    }
}

/// One checkout over the work tree that overwrites nothing: `GIT_CHECKOUT_SAFE`
/// and no ignored file replaced either. libgit2 finds every conflict before
/// it writes, so a refused checkout leaves the folder as it was; the
/// conflicting paths are kept for the message, and the paths it wrote for a
/// caller that has to undo a checkout that failed part way.
final class CheckoutRecord {
    private(set) var conflicts: [String] = []
    private(set) var written: [String] = []

    func run(_ body: (inout git_checkout_options) -> Int32) -> Int32 {
        var options = git_checkout_options()
        git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_DONT_OVERWRITE_IGNORED.rawValue
        options.notify_flags = GIT_CHECKOUT_NOTIFY_CONFLICT.rawValue
        let payload = Unmanaged.passUnretained(self).toOpaque()
        options.notify_payload = payload
        options.notify_cb = { _, path, _, _, _, payload in
            if let path, let payload {
                Unmanaged<CheckoutRecord>.fromOpaque(payload).takeUnretainedValue()
                    .conflicts.append(String(cString: path))
            }
            return 0
        }
        options.progress_payload = payload
        options.progress_cb = { path, _, _, payload in
            if let path, let payload {
                Unmanaged<CheckoutRecord>.fromOpaque(payload).takeUnretainedValue()
                    .written.append(String(cString: path))
            }
        }
        return withExtendedLifetime(self) { body(&options) }
    }

    func failure(_ code: Int32, _ what: String) -> GitError {
        guard code == GIT_ECONFLICT.rawValue || !conflicts.isEmpty else { return GitError.last(code, what) }
        let shown = conflicts.prefix(5).joined(separator: ", ")
        let more = conflicts.count > 5 ? " and \(conflicts.count - 5) more" : ""
        let paths = conflicts.isEmpty ? "" : ": \(shown)\(more)"
        return GitError(.conflict, "\(what) would overwrite what is in the folder\(paths)")
    }
}

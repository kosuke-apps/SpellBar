import Foundation

extension CandidateEngine {
    /// Identifiers and API names that are common in programming but missing from English dictionaries.
    /// To add more, put one word per line in ~/.config/spellbar/terms.txt.
    static let seedTerms: [String] = """
    async await asyncio coroutine goroutine mutex semaphore deadlock idempotent
    kwargs argv argc stderr stdout stdin errno printf sprintf snprintf malloc
    struct enum typedef nullptr constexpr namespace virtual override
    boolean integer nullable optional iterator iterable generator closure
    lambda functor currying memoize memoization immutable mutable
    stringify serialize deserialize marshal unmarshal encode decode
    middleware handler dispatcher scheduler throttle debounce
    localhost hostname subnet cidr proxy reverse websocket
    endpoint payload webhook oauth bearer refreshToken accessToken
    request response header cookie session cache invalidate
    repository branch rebase cherrypick stash submodule upstream origin
    commit amend squash conflict merge checkout worktree
    kubernetes kubectl namespace deployment ingress configmap
    docker dockerfile compose volume registry
    postgres postgresql sqlite mysql redis mongodb
    migration schema constraint foreign primary index
    javascript typescript python golang rustlang kotlin swift
    npm yarn pnpm webpack vite babel eslint prettier
    numpy pandas pytorch tensorflow sklearn matplotlib
    pytest unittest mock fixture assert
    regex regexp substring substr charAt indexOf splice
    truthy falsy nullish coalescing destructuring spread
    singleton factory observer decorator middleware
    latency throughput bandwidth concurrency parallelism
    authentication authorization credential permission
    environment configuration parameter argument
    initialize initialization deprecated experimental
    """.split(whereSeparator: \.isWhitespace).map(String.init)
}

import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("GhCliAdapter")
struct GhCliAdapterTests {

    // MARK: - parseRepoSlug

    @Test("ssh scp-style remote")
    func sshScpStyle() {
        let slug = GhCliAdapter.parseRepoSlug("git@github.com:langwatch/langwatch.git")
        #expect(slug?.owner == "langwatch")
        #expect(slug?.name == "langwatch")
        #expect(slug?.host == "github.com")
    }

    @Test("https remote with .git suffix")
    func httpsWithGitSuffix() {
        let slug = GhCliAdapter.parseRepoSlug("https://github.com/langwatch/langwatch.git")
        #expect(slug?.owner == "langwatch")
        #expect(slug?.name == "langwatch")
        #expect(slug?.host == "github.com")
    }

    @Test("https remote without .git suffix")
    func httpsBare() {
        let slug = GhCliAdapter.parseRepoSlug("https://github.com/rogeriochaves/skills")
        #expect(slug?.owner == "rogeriochaves")
        #expect(slug?.name == "skills")
        #expect(slug?.host == "github.com")
    }

    @Test("ssh url-style remote")
    func sshUrlStyle() {
        let slug = GhCliAdapter.parseRepoSlug("ssh://git@github.com/langwatch/langwatch.git")
        #expect(slug?.owner == "langwatch")
        #expect(slug?.name == "langwatch")
        #expect(slug?.host == "github.com")
    }

    @Test("enterprise host is kept in the slug so different hosts never group together")
    func enterpriseHost() {
        let slug = GhCliAdapter.parseRepoSlug("git@github.acme-internal.com:platform/api.git")
        #expect(slug?.owner == "platform")
        #expect(slug?.name == "api")
        #expect(slug?.host == "github.acme-internal.com")
    }

    @Test("trailing newline from git remote get-url is tolerated")
    func trailingNewline() {
        let slug = GhCliAdapter.parseRepoSlug("git@github.com:langwatch/langwatch.git\n")
        #expect(slug?.owner == "langwatch")
        #expect(slug?.name == "langwatch")
    }

    @Test("non-remote strings do not parse")
    func garbage() {
        #expect(GhCliAdapter.parseRepoSlug("/Users/someone/Projects/langwatch") == nil)
        #expect(GhCliAdapter.parseRepoSlug("") == nil)
        #expect(GhCliAdapter.parseRepoSlug("https://github.com/onlyowner") == nil)
    }
}

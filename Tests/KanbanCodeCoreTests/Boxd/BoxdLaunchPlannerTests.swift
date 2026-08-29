import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("BoxdLaunchPlanner")
struct BoxdLaunchPlannerTests {

    // MARK: - Machine name

    @Test("The machine name carries the repository and the first 8 of the card id")
    func machineName() {
        #expect(BoxdLaunchPlanner.machineName(repoName: "langwatch", cardId: "card_01ab2c3d4e5f") == "kc-langwatch-01ab2c3d")
        #expect(BoxdLaunchPlanner.machineName(repoName: "langwatch", cardId: "01ab2c3d4e5f") == "kc-langwatch-01ab2c3d")
    }

    @Test("The name only keeps lowercase letters, digits and dashes")
    func machineNameSanitised() {
        let name = BoxdLaunchPlanner.machineName(repoName: "LangWatch_SaaS.v2", cardId: "card_AB.cd/ef")
        #expect(name == "kc-langwatch-saas-v2-ab-cd-ef")
        #expect(name.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" })
    }

    @Test("A long repository name is cut so the name stays inside the limit")
    func machineNameLength() {
        let name = BoxdLaunchPlanner.machineName(
            repoName: "a-very-long-repository-name-that-never-fits-anywhere",
            cardId: "card_0123456789"
        )
        #expect(name.count <= BoxdLaunchPlanner.maximumMachineNameLength)
        #expect(name.hasPrefix("kc-a-very-long"))
        #expect(name.hasSuffix("-01234567"))
    }

    @Test("An empty repository name still gives a usable machine name")
    func machineNameEmptyRepo() {
        #expect(BoxdLaunchPlanner.machineName(repoName: "", cardId: "card_0123") == "kc-repo-0123")
    }

    // MARK: - Repository name

    @Test("The repository name comes from the origin URL")
    func repoNameFromOrigin() {
        #expect(BoxdLaunchPlanner.repoName(fromOriginURL: "https://github.com/langwatch/kanban.git", fallbackFolder: "/tmp/x") == "kanban")
        #expect(BoxdLaunchPlanner.repoName(fromOriginURL: "git@github.com:langwatch/kanban.git", fallbackFolder: "/tmp/x") == "kanban")
        #expect(BoxdLaunchPlanner.repoName(fromOriginURL: "https://github.com/langwatch/kanban", fallbackFolder: "/tmp/x") == "kanban")
        #expect(BoxdLaunchPlanner.repoName(fromOriginURL: "ssh://git@github.com/langwatch/kanban.git", fallbackFolder: "/tmp/x") == "kanban")
    }

    @Test("Without an origin URL the folder name is used")
    func repoNameFallback() {
        #expect(BoxdLaunchPlanner.repoName(fromOriginURL: nil, fallbackFolder: "/Users/me/Projects/langwatch") == "langwatch")
        #expect(BoxdLaunchPlanner.repoName(fromOriginURL: "", fallbackFolder: "/Users/me/Projects/langwatch/") == "langwatch")
        #expect(BoxdLaunchPlanner.repoName(fromOriginURL: "not a url", fallbackFolder: "/Users/me/Projects/kanban") == "kanban")
    }

    @Test("A local path as origin falls back to the folder name")
    func repoNameLocalOrigin() {
        #expect(BoxdLaunchPlanner.repoName(fromOriginURL: "/srv/git/mirror.git", fallbackFolder: "/Users/me/mirror") == "mirror")
    }

    // MARK: - Templates

    @Test("Placeholders are expanded")
    func expand() {
        let result = BoxdLaunchPlanner.expand(
            template: "clone ${repo_url} into ${repo_dir} for ${repo_name}",
            values: ["repo_url": "u", "repo_dir": "d", "repo_name": "n"]
        )
        #expect(result == "clone u into d for n")
    }

    @Test("An unknown placeholder is left in place")
    func expandUnknown() {
        #expect(BoxdLaunchPlanner.expand(template: "${a}-${b}", values: ["a": "1"]) == "1-${b}")
    }

    @Test("Every occurrence of a placeholder is expanded")
    func expandRepeated() {
        #expect(BoxdLaunchPlanner.expand(template: "${a} ${a}", values: ["a": "x"]) == "x x")
    }

    @Test("The folder template resolves against the home of the machine")
    func remoteProjectPath() {
        #expect(
            BoxdLaunchPlanner.remoteProjectPath(folderTemplate: "~/${repo_name}", repoName: "langwatch", remoteHome: "/home/boxd")
                == "/home/boxd/langwatch"
        )
        #expect(
            BoxdLaunchPlanner.remoteProjectPath(folderTemplate: "~/code/${repo_name}/", repoName: "kanban", remoteHome: "/home/boxd/")
                == "/home/boxd/code/kanban"
        )
        #expect(
            BoxdLaunchPlanner.remoteProjectPath(folderTemplate: "/srv/${repo_name}", repoName: "kanban", remoteHome: "/home/boxd")
                == "/srv/kanban"
        )
        #expect(
            BoxdLaunchPlanner.remoteProjectPath(folderTemplate: "${repo_name}", repoName: "kanban", remoteHome: "/home/boxd")
                == "/home/boxd/kanban"
        )
        #expect(
            BoxdLaunchPlanner.remoteProjectPath(folderTemplate: "~", repoName: "kanban", remoteHome: "/home/boxd")
                == "/home/boxd"
        )
    }

    @Test("An empty folder template falls back to the repository name")
    func remoteProjectPathEmpty() {
        #expect(
            BoxdLaunchPlanner.remoteProjectPath(folderTemplate: "  ", repoName: "kanban", remoteHome: "/home/boxd")
                == "/home/boxd/kanban"
        )
    }

    @Test("The default init command is filled in with the card values")
    func initScript() {
        let script = BoxdLaunchPlanner.initScript(
            template: BoxdSettings.defaultInitCommand,
            repoDir: "/home/boxd/langwatch",
            repoURL: "git@github.com:langwatch/langwatch.git",
            repoName: "langwatch",
            branch: "feat/boxd"
        )
        #expect(script.contains(#"cd "/home/boxd/langwatch" && git pull --ff-only"#))
        #expect(script.contains(#"git clone "git@github.com:langwatch/langwatch.git" "/home/boxd/langwatch""#))
        #expect(!script.contains("${"))
    }

    @Test("The branch is available to a custom init command")
    func initScriptBranch() {
        let script = BoxdLaunchPlanner.initScript(
            template: "git checkout ${branch} # ${repo_name}",
            repoDir: "/d", repoURL: "u", repoName: "kanban", branch: "main"
        )
        #expect(script == "git checkout main # kanban")
    }

    // MARK: - Mappings

    @Test("Mappings come in the project, kanban home, home order")
    func mappings() {
        let mappings = BoxdLaunchPlanner.mappings(
            localProjectPath: "/Users/me/Projects/langwatch",
            remoteProjectPath: "/home/boxd/langwatch",
            localHome: "/Users/me",
            remoteHome: "/home/boxd",
            localKanbanHome: "/Users/me/.kanban-code",
            remoteKanbanHome: "/home/boxd/.kanban-code"
        )
        #expect(mappings.count == 3)
        #expect(mappings[0] == PathMapping(from: "/home/boxd/langwatch", to: "/Users/me/Projects/langwatch"))
        #expect(mappings[1] == PathMapping(from: "/home/boxd/.kanban-code", to: "/Users/me/.kanban-code"))
        #expect(mappings[2] == PathMapping(from: "/home/boxd", to: "/Users/me"))
    }

    @Test("The mappings drive the transcript rewriter")
    func mappingsFeedRewriter() {
        let rewriter = TranscriptPathRewriter(BoxdLaunchPlanner.mappings(
            localProjectPath: "/Users/me/Projects/langwatch",
            remoteProjectPath: "/home/boxd/langwatch",
            localHome: "/Users/me",
            remoteHome: "/home/boxd",
            localKanbanHome: "/Users/me/.kanban-code",
            remoteKanbanHome: "/home/boxd/.kanban-code"
        ))
        #expect(rewriter.mapPath("/home/boxd/langwatch/.claude/worktrees/a") == "/Users/me/Projects/langwatch/.claude/worktrees/a")
        #expect(rewriter.mapPath("/home/boxd/.kanban-code/hook-events.jsonl") == "/Users/me/.kanban-code/hook-events.jsonl")
        #expect(rewriter.mapPath("/home/boxd/other") == "/Users/me/other")
    }

    // MARK: - Glob matching

    @Test("**/ matches zero or more directories")
    func globAnyDepth() {
        #expect(BoxdLaunchPlanner.matches(glob: "**/.env", path: ".env"))
        #expect(BoxdLaunchPlanner.matches(glob: "**/.env", path: "platform/app/.env"))
        #expect(!BoxdLaunchPlanner.matches(glob: "**/.env", path: "platform/app/.env.local"))
        #expect(!BoxdLaunchPlanner.matches(glob: "**/.env", path: "env"))
    }

    @Test("* stays inside one segment")
    func globSingleSegment() {
        #expect(BoxdLaunchPlanner.matches(glob: "*.env", path: "prod.env"))
        #expect(!BoxdLaunchPlanner.matches(glob: "*.env", path: "config/prod.env"))
        #expect(BoxdLaunchPlanner.matches(glob: "config/*.yaml", path: "config/app.yaml"))
        #expect(!BoxdLaunchPlanner.matches(glob: "config/*.yaml", path: "config/nested/app.yaml"))
        #expect(BoxdLaunchPlanner.matches(glob: "**/*.env", path: "a/b/prod.env"))
    }

    @Test("? matches exactly one character")
    func globSingleCharacter() {
        #expect(BoxdLaunchPlanner.matches(glob: ".env.?", path: ".env.a"))
        #expect(!BoxdLaunchPlanner.matches(glob: ".env.?", path: ".env.ab"))
    }

    @Test("An exact path matches itself")
    func globExact() {
        #expect(BoxdLaunchPlanner.matches(glob: "apps/web/.env", path: "apps/web/.env"))
        #expect(BoxdLaunchPlanner.matches(glob: "./apps/web/.env", path: "apps/web/.env"))
        #expect(!BoxdLaunchPlanner.matches(glob: "apps/web/.env", path: "apps/api/.env"))
    }

    // MARK: - Files to copy

    @Test("copyMatches walks the project and skips .git and node_modules")
    func copyMatches() throws {
        let root = NSTemporaryDirectory() + "kanban-copy-\(UUID().uuidString)"
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(atPath: root) }

        for directory in ["", "platform/app", "node_modules/pkg", ".git", "config"] {
            try fileManager.createDirectory(atPath: (root as NSString).appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        for file in [".env", "platform/app/.env", "node_modules/pkg/.env", ".git/.env", "config/app.yaml", "README.md"] {
            try "x".write(toFile: (root as NSString).appendingPathComponent(file), atomically: true, encoding: .utf8)
        }

        let matched = BoxdLaunchPlanner.copyMatches(globs: ["**/.env"], projectRoot: root)
        #expect(matched == [".env", "platform/app/.env"])

        let several = BoxdLaunchPlanner.copyMatches(globs: ["**/.env", "config/*.yaml"], projectRoot: root)
        #expect(several == [".env", "config/app.yaml", "platform/app/.env"])
    }

    @Test("Blank and commented glob lines are ignored")
    func copyMatchesEmptyGlobs() throws {
        let root = NSTemporaryDirectory() + "kanban-copy-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "x".write(toFile: (root as NSString).appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        #expect(BoxdLaunchPlanner.copyMatches(globs: [], projectRoot: root).isEmpty)
        #expect(BoxdLaunchPlanner.copyMatches(globs: ["  ", "# a comment"], projectRoot: root).isEmpty)
    }

    @Test("A project root that does not exist matches nothing")
    func copyMatchesMissingRoot() {
        #expect(BoxdLaunchPlanner.copyMatches(globs: ["**/.env"], projectRoot: "/nowhere/at/all").isEmpty)
    }

    // MARK: - Resume decision

    @Test("A live tmux session is only attached to")
    func resumeAttaches() {
        #expect(BoxdLaunchPlanner.resumeDecision(tmuxAlive: true, localTranscriptBytes: 10, remoteTranscriptBytes: 0) == .attach)
        #expect(BoxdLaunchPlanner.resumeDecision(tmuxAlive: true, localTranscriptBytes: 0, remoteTranscriptBytes: 99) == .attach)
    }

    @Test("A local transcript that is ahead is pushed first")
    func resumePushes() {
        #expect(BoxdLaunchPlanner.resumeDecision(tmuxAlive: false, localTranscriptBytes: 200, remoteTranscriptBytes: 100) == .pushThenResume)
    }

    @Test("A machine that already has the newest transcript resumes as it is")
    func resumePlain() {
        #expect(BoxdLaunchPlanner.resumeDecision(tmuxAlive: false, localTranscriptBytes: 100, remoteTranscriptBytes: 100) == .resume)
        #expect(BoxdLaunchPlanner.resumeDecision(tmuxAlive: false, localTranscriptBytes: 0, remoteTranscriptBytes: 100) == .resume)
    }
}

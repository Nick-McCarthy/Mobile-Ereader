# Agent skills

Third-party agent skills for Swift and iOS work, picked from the [Swift Agent Skills](https://github.com/twostraws/Swift-Agent-Skills) index. Each folder holds the skill's `SKILL.md`, its `references/`, and the author's `LICENSE` (all MIT). The files are unmodified copies, except that one sample key in `swift-security-expert/references/compliance-owasp-mapping.md` is replaced with a placeholder so GitHub secret scanning accepts the push. The only omissions are agent-tool configuration, icons, and install scripts.

**Project docs win.** These skills give general advice. Where one conflicts with `AGENTS.md` or `/docs`, follow the project. Examples: this app targets iOS 17, uses GRDB rather than SwiftData, and adds no third-party dependencies without approval. Some skills assume newer OS versions or a local Mac and simulator, which this project doesn't have (see `docs/CI_AND_BUILD.md`).

| Skill | Author | Source (commit) |
|---|---|---|
| `swiftui-pro` | Paul Hudson | [twostraws/SwiftUI-Agent-Skill](https://github.com/twostraws/SwiftUI-Agent-Skill/tree/f2920b63995263f57b3e198674e89a602efba6d2/swiftui-pro) (`f2920b6`) |
| `swift-concurrency-pro` | Paul Hudson | [twostraws/Swift-Concurrency-Agent-Skill](https://github.com/twostraws/Swift-Concurrency-Agent-Skill/tree/bee3f69ba17142da148d3c5406f148ed62592b69/swift-concurrency-pro) (`bee3f69`) |
| `swift-testing-pro` | Paul Hudson | [twostraws/Swift-Testing-Agent-Skill](https://github.com/twostraws/Swift-Testing-Agent-Skill/tree/2d6bba14a3c8bf3694f218b92fffe617c41ae43e/swift-testing-pro) (`2d6bba1`) |
| `swift-security-expert` | Ivan Magda | [ivan-magda/swift-security-skill](https://github.com/ivan-magda/swift-security-skill/tree/bda2e0ccee6a64d45ec2b93790d0876c90e4eb89/swift-security-expert) (`bda2e0c`) |
| `ios-accessibility` | Daniel Devesa | [dadederk/iOS-Accessibility-Agent-Skill](https://github.com/dadederk/iOS-Accessibility-Agent-Skill/tree/dcc3a36ce1d0099341d545c1af4eb5a8c989bf66/ios-accessibility) (`dcc3a36`) |
| `appstore-review` | 3 Paws AI Studio | [3paws-ai/mobile-ai-skills](https://github.com/3paws-ai/mobile-ai-skills/tree/6d3570eab02b57d8f8269ef11a1ef8ffcb1c8553/skills/appstore-review) (`6d3570e`); `setup-guide.md` omitted |
| `background-execution` | Anton Novoselov | [n0an/Background-Execution-Agent-Skill](https://github.com/n0an/Background-Execution-Agent-Skill/tree/a29ddf879308bc6cb0d5add020533701baa7fe67/background-execution) (`a29ddf8`) |

To update a skill, re-copy its folder from the source repo, review the diff before committing (skills are instructions to agents), and update the commit in this table.

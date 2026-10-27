# Agent skill installation integration

`SkillInstallationView` presents an optional command for installing the
repository's [capture skill](../skills/vishot-capture/SKILL.md). The view is
ready to embed in Setup and Settings after their concurrent CLI-installation
changes arrive. It has no dependency on CLI installation or permission status.

## Command and verified source

Both hosts use the same command from `SkillInstallation.command`:

```sh
npx skills add dartyuhov/vishot --skill vishot-capture
```

On October 21, 2026, read-only verification confirmed the public repository
`https://github.com/dartyuhov/vishot` and the official Vercel installer docs
at upstream commit `a80e4c9d12d607631249d4d7d059f835d4b2f13a`:

- [Installer requirements and invocation](https://github.com/vercel-labs/skills/blob/a80e4c9d12d607631249d4d7d059f835d4b2f13a/README.md).
- [GitHub shorthand and named skill selection](https://github.com/vercel-labs/skills/blob/a80e4c9d12d607631249d4d7d059f835d4b2f13a/docs/commands.md#skills-add).
- [Skill frontmatter and discovery layout](https://github.com/vercel-labs/skills/blob/a80e4c9d12d607631249d4d7d059f835d4b2f13a/docs/creating-skills.md#skill-discovery).

The installer supports `owner/repo`, `--skill <name>`, and discovery under
`skills/<name>/SKILL.md`. It currently requires Node.js 22.20 or newer. The
command leaves agent choice interactive and uses the installer's default
project scope; it does not force global installation or skip confirmation.
The native Vishot CLI has no Node/npm or network requirement.

This is syntax and source verification, not an installation test. The skill
is local until these changes are published; the default-branch source path
returned HTTP 404 during verification. Publish the skill before shipping UI
that advertises its remote installation. No installer was executed, runtime
installed, or agent folder modified during development.

## Host integration patch requirements

Create a separate view for each window. The control has no refresh method,
completion callback, service request, or install action. Its only button
copies the command to the clipboard on an explicit click. Text is selectable
for manual copying as well.

After the optional CLI step from ticket `.4` is present, make these edits in
the integrating branch:

1. In `SetupWindow.swift`, add a stored property:

   ```swift
   private let skillInstallation = SkillInstallationView()
   ```

   In the optional CLI step's content construction, after the native CLI
   installation control, append:

   ```swift
   cliStep.addArrangedSubview(skillInstallation)
   skillInstallation.widthAnchor.constraint(equalTo: cliStep.widthAnchor).isActive = true
   ```

   Replace `cliStep` with `.4`'s existing optional-step `NSStackView`. Include
   this view in the same scrollable layout. Keep **Skip**, **Continue**, and
   setup completion independent of copying or running the command. Copying
   does not advance setup or mark anything installed. No `SetupFlow` change
   is required.

2. In `SettingsWindow.swift`, add its own stored property:

   ```swift
   private let skillInstallation = SkillInstallationView()
   ```

   Append that view to the existing agent/CLI section's `views` array:

   ```swift
   section("Agent CLI", views: [cliInstallation, skillInstallation])
   ```

   Preserve the actual `.3` section title and existing controls in that array.
   The existing section helper pins content widths. Keep the skill control
   available when native CLI installation is skipped, fails, or conflicts.

3. Extend the host presentation tests after integration: find
   `NSUserInterfaceItemIdentifier("skill-installation")` in the optional Setup
   step and Settings, verify the command is visible/selectable, and verify
   **Skip** still completes the optional step. The copy button identifier is
   `copy-skill-install-command`; the field is `skill-install-command`. For copy
   behavior, reuse the component's isolated-pasteboard tests rather than
   launching an installer or altering the user's clipboard in host tests.

`Sources/Vishot/SkillInstallation.swift` and
`Tests/VishotTests/SkillInstallationViewTests.swift` supply the component and
copy/presentation tests. The concurrent host files are intentionally left for
the integrating owner to wire once their new layout exists.

## Skill validation

The CLI-boundary test executes the shell examples from the shipped skill
against the compiled CLI with a controlled service, then decodes the returned
PNG. The [evaluation prompts](../skills/vishot-capture/evals/evals.json) cover
exact-window visual inspection, unavailable/minimized/Space behavior, and
task-scoped cleanup. They are review scenarios, not a claimed independent
model benchmark. Complete the signed-app agent/image-reader walkthrough as
part of the end-to-end validation ticket.

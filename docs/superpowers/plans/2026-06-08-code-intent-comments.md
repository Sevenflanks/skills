# Code Intent Comments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `code-intent-comments` skill to this skills collection.

**Architecture:** This is a documentation skill bundle: one runtime `SKILL.md`, one human `README.md`, one eval file, plus repository catalogs. The skill teaches agents to write plain-language, high-value code comments that explain intent, risk, user requirements, compatibility, and boundaries without adding noisy line-by-line comments.

**Style Requirements:** Skill text and examples must preserve the user's plain zh-TW style: 白話優先, 不可濫用縮寫, technical names remain original, and comments should feel like engineering notes instead of formal academic docs.

**Tech Stack:** Markdown skills, JSON manifests, Node.js validator via `npm run validate`.

---

## Task 1: Update Design Spec

**Files:**
- Modify: `docs/superpowers/specs/2026-06-08-code-intent-comments-design.md`

- [ ] Add the approved rule: 既有註解 may be rewritten only when near touched code and directly related to understanding, risk, requirement, compatibility, or maintenance context.
- [ ] Add the approved delivery requirement: after the skill is complete, provide 成果展示 with several code snippets demonstrating the result after applying the skill.
- [ ] Verify the spec still says comments must stay plain zh-TW, avoid abbreviation overuse, and avoid whole-file style cleanup.

## Task 2: Run RED Baseline

**Files:**
- No file changes during RED baseline.

- [ ] Run pressure scenario for high-risk rounding/allocation comments without the new skill.
- [ ] Run pressure scenario for legacy/CR compatibility comments without the new skill.
- [ ] Run pressure scenario for simple typo/config change without the new skill.
- [ ] Capture at least three failure modes, such as missing business invariant, vague CR note, over-commenting simple changes, or broad unrelated cleanup.

## Task 3: Create Skill Docs

**Files:**
- Create: `skills/code-intent-comments/SKILL.md`
- Create: `skills/code-intent-comments/README.md`

- [ ] Create `SKILL.md` with LF frontmatter and required fields: `name`, `description`, `license`, `metadata.author`, `metadata.version`.
- [ ] Include a trigger-focused description for `code-intent-comments`.
- [ ] Document the comment decision gate: add or rewrite comments only when code alone does not explain intent, risk, or requirement context.
- [ ] Include the personal style profile: plain zh-TW, technical names preserved, no abbreviation overuse, engineering memo tone.
- [ ] Include what to comment: class/module boundaries, core methods, user CRs, compatibility, high-risk logic, legacy/framework quirks.
- [ ] Include what not to comment: obvious flow labels, same-meaning field comments, dead-code preservation, broad style-only cleanup.
- [ ] Include RED baseline failure modes in `Common mistakes`.
- [ ] Create `README.md` with problem, usage timing, main workflow, and file list.

## Task 4: Create Evals

**Files:**
- Create: `skills/code-intent-comments/evals/evals.json`

- [ ] Add eval case for rounding/allocation invariant and do-not-simplify reason.
- [ ] Add eval case for class/service with user CR and legacy compatibility.
- [ ] Add eval case for simple typo/config change where no extra comment should be added.
- [ ] Add eval case for existing comment rewrite near touched code.
- [ ] Add eval case rejecting broad unrelated comment cleanup.
- [ ] Verify JSON is valid and `skill_name` equals `code-intent-comments`.

## Task 5: Update Catalogs And Root README

**Files:**
- Modify: `skills.json`
- Modify: `.claude-plugin/marketplace.json`
- Modify: `README.md`

- [ ] Add `code-intent-comments` to `skills.json` with version `0.1.0`, license `MIT`, author `sevenflankse`, status `stable`, and tags `comments`, `documentation`, `maintainability`, `code-review`, `intent`, `risk`, `cr`.
- [ ] Add matching marketplace entry with source `skills/code-intent-comments`, version `0.1.0`, and matching keywords.
- [ ] Add the root README table row.
- [ ] Add the root README skill section.
- [ ] Add the root README structure/file links for `SKILL.md`, `README.md`, and `evals/evals.json`.

## Task 6: Demonstrate Skill Output

**Files:**
- No required file changes unless examples are added to skill docs.

- [ ] Prepare several short code snippets showing how the skill would improve comments.
- [ ] Include at least one class/module responsibility example.
- [ ] Include at least one high-risk method or business invariant example.
- [ ] Include at least one user CR or legacy compatibility example.
- [ ] Include one simple-change example where no comment should be added.

## Task 7: Validate And Review

**Files:**
- No intended edits unless validation finds an issue caused by this work.

- [ ] Run `npm run validate`.
- [ ] If validation fails due to existing `daily-work-log/SKILL.md` CRLF/frontmatter parsing, report it as pre-existing unless this task changed that file.
- [ ] Inspect `git diff` for only intended files.
- [ ] Do not commit unless user explicitly asks.

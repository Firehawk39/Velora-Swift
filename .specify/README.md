# Spec-Driven Development (Spec Kit) in Velora AI Studio

This directory implements the **Spec-Driven Development (SDD)** framework inspired by [GitHub Spec Kit](https://github.com/github/spec-kit) and tailored to the rigorous engineering standards of Velora AI Studio.

---

## The SDD Lifecycle

```
1. Constitution Check  ──>  2. Feature Spec  ──>  3. Technical Plan  ──>  4. Discrete Tasks  ──>  5. Execution & Verification
    constitution.md           spec.md                 plan.md                tasks.md              Code & CI/CD Push
```

### Directory Structure
```
.specify/
├── constitution.md          # Non-negotiable architectural rules & invariants
├── templates/
│   ├── spec.template.md     # Template for Feature Specifications
│   ├── plan.template.md     # Template for Architectural Technical Plans
│   └── tasks.template.md    # Template for Discrete Implementation Tasks
└── specs/                   # Active and completed specifications
    └── [feature-name]/
        ├── spec.md
        ├── plan.md
        └── tasks.md
```

### When to Use
- **New Features**: Building new audio engine capabilities, UI canvases, sync workers, or integrations.
- **Architectural Refactors**: Major transitions (e.g. AVQueuePlayer, database migrations, caching overhauls).
- **Complex Bug Fixes**: Multi-file state bugs requiring synchronization across background threads and views.

---

## Integration with Antigravity
You can trigger this workflow automatically at any time by asking the agent to:
- *"Create a spec for [Feature Name]"*
- *"Plan [Feature Name] using spec-kit"*
- Or invoke the `spec-driven-development` skill.

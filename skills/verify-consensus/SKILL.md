---
description: >
  Cross-verifies Claude Code answers using Codex (OpenAI) as an independent
  second opinion. Classifies queries, lets Claude work freely, then runs
  Codex review AFTER work is done. The Stop hook blocks until verified.
allowed-tools:
  - mcp__codex__codex
  - mcp__codex__codex-reply
  - mcp__exa__web_search_exa
  - mcp__context7__resolve-library-id
  - mcp__context7__query-docs
  - WebSearch
  - WebFetch
  - Agent
  - Bash
  - Write
  - Read
---

<!-- INSTALL: Copy this entire folder to ~/.claude/skills/verify-consensus/ -->

# Verify-Consensus Skill (v4 — Work First, Review After)

## The Rule

Claude works freely. Codex reviews AFTER. Not during.

```
Query → Classify → Claude works (tools, agents, code, everything)
      → Answer ready → Codex reviews finished output
      → 2 consecutive agreements → Done
```

---

## Step 1: Classify (FIRST action, every query)

Write `.claude/verify-state.json` immediately:

### TRIVIAL (greetings, chat, simple lookups, boilerplate):
```json
{
  "question": "<summary>",
  "complexity": "trivial",
  "trivial": true,
  "status": "verified",
  "ts": "<ISO timestamp>"
}
```
Then work and answer normally. No Codex review needed.

### STANDARD or RESEARCH:
```json
{
  "question": "<summary>",
  "complexity": "standard|research",
  "trivial": false,
  "status": "working",
  "iteration": 0,
  "history": [],
  "ts": "<ISO timestamp>"
}
```

---

## Step 2: Work Freely

Do ALL your work first. Use every tool you need:
- Read files, write code, run tests
- Spawn agents, search the web
- Research with Context7, Exa, WebSearch
- Build, debug, deploy — whatever the task needs

**Do NOT call Codex during this phase.** Focus on producing the best answer.

---

## Step 3: Write Context File + Prepare Answer

When your work is done, write `.claude/verify-context.md` with ALL context
Codex needs. This is the BRIDGE — Codex can't see your files or conversation,
so everything it needs must go in this file.

```markdown
<!-- .claude/verify-context.md -->

## Question
<user's original question, verbatim>

## Classification
<standard or research>

## Context
<any background Codex needs to review properly:
- relevant file contents (paste key sections)
- conversation history summary
- user's constraints or preferences
- project context>

## Answer
<your full answer>

## Key Claims
1. <claim 1>
2. <claim 2>
...

## Citations
- [source](url): "supporting quote"
...
```

**IMPORTANT:** Include enough context that Codex can review WITHOUT access to
your files, conversation, or local state. If you summarized a PDF, include the
key facts. If you made architecture decisions, include the constraints.

---

## Step 4: Run Codex Review

Update status to "reviewing":
```json
{ "status": "reviewing", ... }
```

### For CODE tasks (bug fixes, features, implementations):
Use the Codex plugin commands — they review git diffs automatically:

**STANDARD:**
```
/codex:review --wait
```

**RESEARCH (architecture, security, migrations):**
```
/codex:adversarial-review --wait --effort xhigh "focus: <what to challenge>"
```

These commands see the actual code diff. No context file needed.

### For NON-CODE tasks (research, strategy, decisions, learning):
Use `mcp__codex__codex` and pass the content of `.claude/verify-context.md`
as the prompt input. The context file ensures Codex has everything it needs.

**STANDARD:**
```
mcp__codex__codex(prompt=<contents of .claude/verify-context.md> + STANDARD_REVIEW_INSTRUCTION)
```

Where STANDARD_REVIEW_INSTRUCTION is:
```
TASK: Produce your own independent answer to the same question.
Compare with the AI's answer. List disagreements with severity (low/med/high).
If you substantially agree, say so.
```

**RESEARCH:**
```
mcp__codex__codex(prompt=<contents of .claude/verify-context.md> + RESEARCH_REVIEW_INSTRUCTION)
```

Where RESEARCH_REVIEW_INSTRUCTION is:
```
You are an adversarial second reviewer. Your job is to challenge
assumptions, find blind spots, and pressure-test the strategy.

TASK:
1. Produce your OWN complete competing answer (not just critique)
2. Challenge design choices, assumptions, and tradeoffs
3. Check cited facts against your knowledge
4. List ALL disagreements with severity (low/med/high)
5. If you substantially agree after review, state that clearly
Reasoning effort: high.
```

### Template variables (fill these in, don't type freestyle):
- `{question}` = the user's original question
- `{claude_answer_with_key_claims_and_citations}` = your formatted answer from Step 3

---

## Step 5: Agreement Check

After each Codex response:

1. **Compute proof-of-work hash:**
```bash
CODEX_HASH=$(echo -n "<raw codex response>" | sha256sum | cut -c1-8)
```

2. **Check agreement:**
   - answer_match: substance agrees (not exact string)
   - claims_overlap: Jaccard >= 0.8
   - no high-severity disagreements
   - agreed = all pass

3. **Log iteration:**
```bash
bash ~/.claude/hooks/log-verify-iteration.sh '{
  "event": "iteration",
  "iteration": <k>,
  "agreed": <true|false>,
  "codex_response_hash": "<8-char hash>",
  "question": "<summary>"
}'
```

4. **Update state:** increment iteration, append to history

5. **Check Aegean stability:** if agreed AND previous round agreed → DONE

6. **If disagreed:** refine answer incorporating Codex feedback → re-run review (max 6 rounds)

---

## Step 6: Complete

### On 2 consecutive agreements:
Update state: `"status": "verified"`
Log: `{"event": "complete", "outcome": "agreed"}`
Deliver the verified answer.

### On 6 rounds without consensus:
Update state: `"status": "capped"`
Log: `{"event": "complete", "outcome": "capped"}`
Deliver BOTH answers. Do NOT fabricate consensus.

---

## Classification Validation (enforced by hook)

**Complexity** must be: `trivial | standard | research` (else BLOCK + RETRY)
**Trivial consistency:** complexity=trivial ↔ trivial=true (else BLOCK)
**Status** must be: `working | reviewing | verified | capped` (else BLOCK)

### Retry rule
If hook blocks: read the RETRY instruction, fix the state file, try again.
Never bypass with escape hatches to avoid validation.

---

## Review Pattern Selection (GPT-5.5 Tiers)

| Classification | Codex Mode | When to use |
|---------------|-----------|-------------|
| **Trivial** | *skip* | Greetings, chat, boilerplate |
| **Standard** | Review (Thinking) | Coding, bug fixes, learning |
| **Research** | Adversarial Review (Pro) | Architecture, security, startup decisions |

### The heuristic
"If the answer would change your behavior or be committed to git, run the review. Otherwise don't."

---

## Max Retries
- Up to **6 rounds** for 2 consecutive agreements
- Early exit on Aegean stability
- Round 6 without agreement → return BOTH answers honestly

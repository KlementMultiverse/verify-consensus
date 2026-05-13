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

## Step 3: Prepare Final Answer

When your work is done, prepare your answer for review. Format key claims:
```json
{
  "answer": "<your final answer summary>",
  "key_claims": ["claim 1", "claim 2", ...],
  "citations": [{"url": "...", "quote": "..."}]
}
```

---

## Step 4: Run Codex Review

Update status to "reviewing":
```json
{ "status": "reviewing", ... }
```

Then call Codex based on classification:

### STANDARD → Codex Review (Thinking tier)
```
mcp__codex__codex with prompt:
"Review this answer: <your answer>. The user asked: <question>.
Produce your own competing answer in the same format.
List disagreements with severity (low/med/high)."
```

### RESEARCH → Codex Adversarial Review (Pro tier)
```
mcp__codex__codex with prompt:
"You are an adversarial reviewer. The user asked: <question>.
Another AI produced: <your answer>. Independently produce YOUR
own complete answer. Challenge design choices, assumptions, and
tradeoffs. List all disagreements with severity. Reasoning effort: high."
```

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

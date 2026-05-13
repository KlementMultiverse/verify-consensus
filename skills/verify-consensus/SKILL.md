---
description: >
  MANDATORY for every task. Cross-verifies answers using Codex (OpenAI) as
  an independent second opinion. Classifies every query as trivial/standard/
  research, then runs the appropriate verification depth. The Stop hook will
  block you from finishing without running this. Use for ALL queries — code,
  research, decisions, learning, startup work, everything.
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

# Verify-Consensus Skill

## MANDATORY: Run on EVERY query

The Stop hook at ~/.claude/hooks/stop-verify-gate.sh will BLOCK you from
finishing unless .claude/verify-state.json exists with either:
- `"trivial": true` (you classified and skipped), OR
- 2 consecutive agreements in history, OR
- iteration >= 6

So you MUST always start by writing the state file.

---

## Step 1: Classify (ALWAYS — first thing you do)

Classify the query complexity and write the state file immediately:

### If TRIVIAL (casual chat, "what was that command", simple lookups, boilerplate):
Write this state file and proceed to answer directly:
```json
{
  "question": "<user's question summary>",
  "complexity": "trivial",
  "trivial": true,
  "reason": "<why trivial>",
  "ts": "<ISO timestamp>"
}
```
Then log it:
```bash
bash ~/.claude/hooks/log-verify-iteration.sh '{"event":"classify","complexity":"trivial","question":"<summary>"}'
```

### If STANDARD or RESEARCH:
Write the initial state file with `phase: "classifying"`:
```json
{
  "question": "<user's question summary>",
  "complexity": "standard|research",
  "trivial": false,
  "phase": "classifying",
  "iteration": 0,
  "history": [],
  "ts": "<ISO timestamp>"
}
```

Present the classification to the user. Wait for confirmation before proceeding.

---

## Classification Validation (enforced by hook)

The stop hook validates EVERY state file. Invalid values = BLOCK.

**Complexity** must be exactly one of: `trivial`, `standard`, `research`.
Any other value (empty, typo, made-up) is rejected.

**Trivial consistency:**
- If `complexity: "trivial"` then `trivial` MUST be `true`
- If `complexity: "standard"` or `"research"` then `trivial` MUST be `false`
- Mismatch = BLOCK (prevents marking real queries as trivial)

**Phase** must be exactly one of: `classifying`, `researching`, `iterating`, `complete`.
- Non-trivial tasks with missing or unknown phase = BLOCK
- Trivial tasks ignore phase entirely

Nothing can fall outside these categories. The hook rejects anything unknown.

---

## Phase System (v3)

Non-trivial tasks move through phases. The stop hook allows mid-flow
pauses in temporary phases so Claude can show work and get user approval.

| Phase | When | Hook allows stop? | Can deliver answer? |
|-------|------|-------------------|-------------------|
| `classifying` | After Step 1, waiting for user to confirm classification | Yes | No |
| `researching` | After Step 2, showing citations to user | Yes | No |
| `iterating` | During Step 3, Codex loop in progress | Yes | No |
| `complete` | After Step 4, full proof-of-work verified | Yes | **Yes** |
| *(missing/empty)* | No phase on non-trivial task | **BLOCK** | No |

**Update the phase in the state file as you move between steps.**
The stop hook reads the phase field to decide whether to allow or block.

---

## Step 2: Research (standard/research only)

Update phase to `"researching"` in state file before starting research.

- Start with broad queries (5 words or fewer), then narrow.
- For code/API questions: Context7 FIRST (version-pinned docs).
- For current info: Exa MCP or WebSearch.
- Every factual claim must have a fetched (not just searched) citation.
- Prefer primary sources; deprioritize SEO content farms.
- For research-class: decompose into 2-4 subquestions, spawn parallel Agent subagents.

---

## Step 3: Iterate (max 6 rounds, early-exit on 2 consecutive agreements)

### Each iteration k = 1..6:

**3a. Claude answer.** Synthesize into JSON envelope:
```json
{
  "answer": "<concise final answer>",
  "key_claims": ["claim 1", "claim 2"],
  "citations": [{"url": "...", "quote": "..."}],
  "confidence": 0.0,
  "disagreements": []
}
```

**3b. Codex review.** Use the Codex plugin commands based on classification:

**STANDARD queries -> `/codex:review` (Thinking tier)**
```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-companion.mjs" review --wait
```
Maps to ChatGPT's "Thinking" intelligence tier.

**RESEARCH queries -> `/codex:adversarial-review --effort xhigh` (Pro tier)**
```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-companion.mjs" adversarial-review --wait --effort xhigh "<focus text>"
```
Maps to ChatGPT's "Pro + Extended thinking" intelligence tier.

**Fallback (if plugin commands fail):** Use `mcp__codex__codex` MCP tool with prompt:

> "You are an adversarial second reviewer. The user asked: <Q>. Another
> AI produced this answer: <claude_answer>. Independently produce YOUR
> own answer in the same JSON envelope format. Do NOT merely critique —
> produce a complete competing answer. Cite sources you can verify. Then
> in a 'disagreements' field, list every point where you disagree, with
> severity (low/med/high). Reasoning effort: high."

**3c. Agreement check:**
- answer_match = substance matches (not exact string)
- claims_overlap = Jaccard(key_claims) >= 0.8
- citation_overlap = >= 1 shared URL or equally-authoritative sources
- no disagreements with severity=high
- agreed = all of the above

**3d. Generate proof-of-work hash (MANDATORY):**

After receiving Codex output, compute a sha256 hash of the raw response:
```bash
CODEX_HASH=$(echo -n "<raw codex response text>" | sha256sum | cut -c1-8)
```
This hash is REQUIRED in the iteration log. The stop hook will BLOCK if any
iteration entry is missing `codex_response_hash`. You CANNOT fake this without
actually calling Codex — the hook cross-checks log entries against state claims.

**3e. Log the iteration (with proof-of-work):**
```bash
bash ~/.claude/hooks/log-verify-iteration.sh '{
  "event": "iteration",
  "iteration": <k>,
  "agreed": <true|false>,
  "claude_confidence": <0.0-1.0>,
  "codex_confidence": <0.0-1.0>,
  "codex_response_hash": "<8-char sha256 of codex output>",
  "high_disagreements": <count>,
  "question": "<summary>"
}'
```

The logger will REJECT iteration events missing `codex_response_hash`.

**3f. Update state file:**
Update .claude/verify-state.json — increment iteration, append to history.

**3g. Stability check (Aegean):**
If `agreed` AND previous round also `agreed` -> COMMIT. Return final answer.

**3h. Disagreement handling:**
If not agreed:
- Surface one-line diff: "Claude says X; Codex says Y."
- Generate refined search query targeting the disagreement.
- Re-run search. Continue to k+1.

---

## Structural Enforcement (v2)

The stop hook enforces these checks deterministically. Claude CANNOT bypass them:

| Check | What the hook verifies | Blocks if |
|-------|----------------------|-----------|
| **Log exists** | `.claude/verify-log.jsonl` present | No log file at all |
| **Codex proof** | At least 1 iteration with `codex_response_hash` | No hashes found (Codex never called) |
| **Count match** | Log iteration count >= state iteration count | State claims more iterations than log has |
| **Agreement cross-check** | Last 2 log entries agree = last 2 state entries agree | State says agreed but log disagrees |
| **Aegean stability** | 2 consecutive `agreed: true` in BOTH state AND log | Only 1 or 0 consecutive agreements |

This means Claude cannot:
- Write `trivial: true` for non-trivial tasks (user can audit gate logs)
- Fake iteration history (log entries with hashes are required)
- Skip Codex calls (no hash = hook blocks)
- Inflate iteration count (log count must match)

---

## Step 4: Terminate

### On stable agreement (2 consecutive):
Update state: `"outcome": "agreed"`. Return verified answer with citations.

### On iteration cap (k=6, still disagreeing):
Update state: `"outcome": "capped"`. Return BOTH answers with confidence scores.
DO NOT fabricate consensus.

---

## Review pattern selection (GPT-5.5 Intelligence Tiers)

| Classification | ChatGPT Tier | Codex Plugin Command | When to use |
|---------------|-------------|---------------------|-------------|
| **Trivial** | Instant | *skip — no Codex call* | Greetings, confirmations, simple chat |
| **Standard** | Thinking | `/codex:review --wait` | Daily coding, bug fixes, learning questions |
| **Research** | Pro (Extended) | `/codex:adversarial-review --wait --effort xhigh` | Architecture, startup decisions, security, research |

### Max retries
- Up to **6 iteration rounds** to achieve 2 consecutive agreements (Aegean stability)
- Early exit on 2 consecutive agreements
- Round 6 without agreement -> return BOTH answers, DO NOT fabricate consensus

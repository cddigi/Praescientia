# Dynamic Meta-Agent Roundtable

You are orchestrating a **roundtable deliberation** for the following task:

**Task:** $ARGUMENTS

---

## Phase 1: Agent Discovery & Ranking

Available agent types and their specializations:

| Agent Type | Specialization |
|---|---|
| `general-purpose` | Research, code search, multi-step execution |
| `Explore` | Fast codebase exploration, file/pattern discovery |
| `Plan` | Architecture design, implementation planning, trade-offs |
| `state-guardian` | State validation, divergence detection, error recovery, confidence checks |
| `strategic-timing-oracle` | Timing decisions, adversarial modeling, optionality analysis, patience vs urgency |
| `claude-code-guide` | Claude Code features, API usage, SDK patterns |

**Your job:** Given the task above, rank ALL agents by relevance (1 = most relevant). Select the **top 5** that bring distinct, complementary perspectives. Briefly justify each selection in one sentence.

---

## Phase 2: Roundtable Assembly

Launch the top 5 agents **in parallel** using the Agent tool. Each agent gets:

1. The full task context
2. A unique **deliberation role** that frames how they should approach the problem (e.g., "You are the Risk Assessor at this roundtable..." or "You are the Implementation Strategist...")
3. Instructions to produce a structured response:
   - **Position:** Their recommendation in 1-2 sentences
   - **Key Insight:** The non-obvious thing their specialization reveals
   - **Risks/Concerns:** What could go wrong from their vantage point
   - **Confidence:** Low / Medium / High with brief justification

Use these prompt templates for each seated agent:

```
You are seated at a deliberation roundtable as the [ROLE NAME].

Task under deliberation: [TASK]

Your specialization brings [WHAT PERSPECTIVE] to this discussion. Analyze the task through your lens and provide:

1. **Position:** Your recommendation (1-2 sentences)
2. **Key Insight:** What does your specialization reveal that others might miss?
3. **Risks/Concerns:** What could go wrong?
4. **Confidence:** Low/Medium/High — why?

Be concise. Under 200 words total.
```

---

## Phase 3: Synthesis & Verdict

After all 5 agents return, synthesize their outputs into a **Roundtable Report**:

### Roundtable Report

**Task:** [restate]

**Panel Composition:** List the 5 agents and their assigned roles

**Consensus Points:** Where do agents agree?

**Divergence Points:** Where do agents disagree? Why?

**Key Risks Identified:** Union of all risks raised, deduplicated

**Recommended Action:** Your synthesized recommendation, weighing confidence levels and accounting for divergences

**Dissenting Opinion:** If any agent strongly disagrees with the consensus, surface their view here

---

## Rules

- Always launch agents in parallel (single message, multiple Agent tool calls)
- Never skip Phase 1 — the ranking step ensures the best team for THIS specific task
- If the task is purely about code/codebase: prefer Explore + Plan + general-purpose
- If the task involves decisions with consequences: prefer state-guardian + strategic-timing-oracle
- If fewer than 5 agents are relevant, seat fewer — don't force irrelevant perspectives
- Name each agent descriptively (e.g., "risk-assessor", "architect", "timing-analyst")

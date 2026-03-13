---
name: budget
description: View context budget allocation — code vs conversation vs memory breakdown
---

# Context Budget

Check the budget analysis for the current session:

```bash
SESSION_ID="${CLAUDE_SESSION_ID:-}"
REPORT="/tmp/remembrall-budget/${SESSION_ID}.json"
```

If the report exists, display the budget breakdown:

```bash
cat "$REPORT" | jq -r '"Code:         \(.code_pct)% (budget: \(.budget.code)%)\nConversation: \(.conversation_pct)% (budget: \(.budget.conversation)%)\nMemory:       \(.memory_pct)% (budget: \(.budget.memory)%)"'
```

Show the user:
1. Current allocation per category (code, conversation, memory) as percentages
2. Configured budget limits
3. Any warnings where actual exceeds budget by >10 points

If budget_enabled is false, inform the user:
- Budget tracking is opt-in: `remembrall_config_set "budget_enabled" "true"`
- Default allocations: code 50%, conversation 30%, memory 20%
- Budgets must sum to 100%

If easter_eggs are enabled and there's an imbalance, use the Sorting Hat theme:
"The Sorting Hat detects an imbalance! [House] has claimed N% of the common room."

Where houses map to: code=Ravenclaw, conversation=Gryffindor, memory=Hufflepuff.

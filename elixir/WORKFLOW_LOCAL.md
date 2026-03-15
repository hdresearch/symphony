---
# IMPORTANT: Update project_slug to match YOUR Linear project!
# To find your project slug: Right-click your project in Linear, copy the URL,
# and extract the slug from the path (e.g., https://linear.app/.../project/YOUR-SLUG-HERE)
tracker:
  kind: linear
  project_slug: "testing-symphony-70398d4c8d01"  # <-- REPLACE with your project slug
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/openai/symphony .
agent:
  max_concurrent_agents: 10
  max_turns: 20
server:
  port: 8888
observability:
  dashboard_enabled: false
  host: "::"
codex:
  stall_timeout_ms: 600000
vers:
  enabled: true
  golden_commit: 2efc03df-0b2a-4efe-940b-206d2c1858c6
  max_runtime_ms: 1800000
---

You are working on a Linear ticket.

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}

Description:
{{ issue.description }}

Work on the issue autonomously.

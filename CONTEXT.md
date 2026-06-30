# CONTEXT (glossary) — Zeph plugin push behavior

Glossary only — no implementation detail. Terms for the plugin's notification
behavior, captured during a grill-with-docs session 2026-06-30 (smarter/aggressive
push design).

## Terms

### Stop-hook Push
The automatic completion notification fired by the `Stop` hook after a response
ends. It is reactive (always at end-of-turn) and not initiated by the model.
Distinct from a Proactive Push.

### Proactive Push
A notification the model sends mid-task — before the turn ends — to surface a
blocker, error, or long-running milestone the moment it occurs, rather than
waiting for the end-of-turn Stop-hook Push.

### Meaningful Work
The condition under which a Stop-hook Push is warranted. Today it is approximated
purely by volume (a response that ran enough tool calls). The Push Signal lets the
model correct that approximation per turn.

### Push Signal
A hint the model emits in its own response to steer the Stop-hook Push for that
turn, overriding the volume heuristic. Three intents:
- **Skip** — suppress the push (the work was not Meaningful Work despite its
  volume, e.g. read-only exploration).
- **Push** — force a push even when the volume heuristic would stay silent (a
  small but important action, e.g. a single force-push).
- **High** — force a push and mark it high priority (a blocker or important
  completion the user should see prominently).

When the model emits no Push Signal, the volume heuristic alone decides — so the
plugin behaves exactly as before unless the model speaks up.

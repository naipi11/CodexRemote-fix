# Implementation brief — cross-process retry closure

Read the successor plan, the prior `final-fix-report.md`, and the final scoped review result supplied by the parent agent.

Implement exactly two tasks in order with RED -> GREEN:

1. Same-SID/new-session `TaskRemoved` replacement wrapper recovery before the staged Apps anchor exists. The generic session matcher must remain strict elsewhere. Revalidate under Local uninstall -> Global AccountTransition, persist only `resumeWrapper*`, short-circuit cleanup, and prove `-WrapperResume` waits for the exact new wrapper.
2. A create-only Ready-bound durable legacy migration plan written before current product writes. A second process must recover after each overlap/current-readback failure without accepting a washed live profile when no exact prior plan exists.

Do not perform any real system or external action. Do not run tests concurrently with another implementation agent. After each task, run its focused suites. After both tasks, freeze source and run the complete final gate from the plan. Commit implementation and evidence separately; report exact SHAs, commands, counts, exits, parser/diff/aggregate results, and a clean status. Do not claim release readiness.

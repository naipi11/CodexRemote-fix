# Implementation brief — Runtime V7 ABI closure

Read the micro-plan and the successor whole-plan final review. Use RED -> GREEN.

The RED must preload a self-contained stale V6 marker/runtime in a new `powershell.exe`, import the current module, and prove the module selected stale V6. Then change every production marker/runtime/ABI reference to V7/7 and update exact tests. Do not change file-layer behavior, exports, durable plan schema, or product/lifecycle logic.

After focused GREEN, freeze source and run the full gate in the plan. Commit implementation and evidence separately, leave a clean worktree, and report exact SHAs/counts/exits. No real system or external actions.

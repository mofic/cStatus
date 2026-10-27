# cStatus implementation progress

Plan: `docs/superpowers/plans/2026-10-15-cstatus.md`

- Preflight: tasks 1→2→4 share Session/StatusEvent; tasks 1→3→4 share EventParser. Keep normalization in core and UI on main actor.
- Ruling: execute inline as requested, no additional approval gates; Git/worktree creation unavailable in this managed directory, use files in place.
- Probe: installed CLI supports proxy, but default app-server-control socket is absent. Existing `ipc/ipc.sock` is not assumed to be an App Server socket.
- Probe: local history projection includes completed, interrupted, failed and inProgress turns. History mode can be legacy or paginated; both must be read.
- Probe: official lifecycle hooks require user trust of their exact definition. Configuration is optional in-app; never bypass hook trust.
- Task 1 complete: 7 state/parser/reminder tests passed (2026-10-15); initial RED confirmed missing production types. Module cache redirected into workspace after host cache write denial.
- Tasks 2–4 RED: new reader/hook/geometry tests failed on missing LineTail, SessionReader, HookBridge and PanelGeometry before implementation.
- Tasks 2–4 first verification: 17 tests passed; native application compiled. Corrected CoreGraphics import and public ObservedEvent initializer found by compiler.
- Regression pass: 3 actual failing state tests reproduced missed resolution, delayed historical completion and notLoaded coverage defects; fixes passed 23 tests.
- Regression: newer turn start arriving after a newer runtime snapshot reproduced a rejected turn ID; reducer now uses per-turn start ordering for new turn boundaries.
- Ruling: local hook configuration is an explicit in-app action that preserves other hooks and writes backups; do not silently modify the user's Codex configuration during development.
- Independent review: six Important findings, no Critical findings. Fixed retired-turn resurrection, reconnect/unload coverage invalidation, historical pending-state confirmation, hook approval resolution, projection failure isolation and full loaded-thread pagination with bounded outstanding polls.
- Additional discovery regression: include unresolved latest turns beyond the recent 300-row window so child activity cannot silently crowd out active roots where history projection is available.
- Native smoke: collapsed panel, expanded panel, bubble, nonactivating window style all passed on two-screen host. WindowServer/LaunchServices required a sandbox escalation; initial sandbox-only test process cleaned up.
- Packaging ruling: release debug-symbol generation was denied by sandbox; disable release debug info instead of requesting broad build permissions. Icon renderer corrected to use NSAffineTransform.
- Live integration test: controlled proxy handshake, 150 IDs over two pages, and unloading coverage invalidation passed; timeout accommodates child interpreter startup. No user Codex tasks or configuration modified.
- Final regression suite: 35 tests passed, zero failures (2026-10-15 11:13 Asia/Shanghai). Includes repeated waiting transitions in one turn, fallback hook approvals, async input acknowledgement and fresh activity confirming historical unknown state.
- No deferred code-review minors. Remaining acceptance limits are real-client event coverage, deep links and manual UI scenarios listed in docs/compatibility.md; they are not marked passed.
- Final release: successful optimized arm64 build; `dist/cStatus.app` generated (about 1.2 MB), icon conversion completed via system image service after sandbox-only iconutil returned Invalid Iconset. Ad-hoc signature verified with `codesign --verify --strict`.
- Final packaged native smoke passed: collapsed panel, expanded panel, bubble, nonactivation all true; screenCount=2.
- Final real-data diagnostic: 302 sessions discovered (300 recent plus unresolved latest turns), zero read errors. Recorded statuses included completed/interrupted/inProgress. Default shared control socket absent; no full live-coverage claim.
- Delivered app opened through LaunchServices. User Codex hook configuration remains unchanged; enable and trust optional hooks through the application and Codex when desired.

- 0.1.1 user correction: main tasks only; removed child rows, child counts and all child reminders, including guardians without parent IDs and structured live sources. Menu badge consistently reports active main-task count rather than attention count.
- 0.1.1 recovery: long legacy transcripts recover lifecycle before the 2 MB tail only when needed; new main-task paths get writer ownership confirmation, including discovery after initially unavailable DB. Terminal clears writer evidence; stale history turn IDs cannot suppress newer terminal events.
- 0.1.1 review: resolved structured source classification, retry bootstrap, unnecessary prefix scanning and stale writer coverage findings. Follow-up review confirmed no remaining blockers.
- 0.1.1 verification (2026-10-15): 48 tests passed, zero failures. Optimized release compiled, application ad-hoc signature verified. Packaged native smoke passed collapsed/expanded/bubble/nonactivation on two screens.
- 0.1.1 actual packaged diagnostic: 300 main-task records; 2 active main tasks, each confirmed by Codex writable journal ownership; no read errors; scan 1.90 seconds. Snapshot changes as user tasks finish; counts are not hardcoded.
- 0.1.1 delivery: stopped only previous cStatus PID 37827 and launched dist/cStatus.app via LaunchServices. User Codex processes and hook configuration untouched. Remaining event-coverage boundaries remain documented in compatibility.md.

# CLOUDSWAP contributor instructions

Start by reading docs/CODEX-HANDOVER.md and docs/CHAT-CONTEXT.md. Check the current branch and working tree before editing; the implementation was developed on feat/macos-foundation in PR #1.

Keep progressing through authorised implementation and tests without asking for routine permission. Report concrete access, hardware or credential blockers. Preserve existing user changes.

Distinguish storage tests, simulated transport faults, real Linux kernel paging, physical disconnect tests and native macOS swap integration. Do not call the product complete or claim disk savings until native app paging and net-space acceptance tests pass. Do not change the user's working Mac swap configuration as part of a routine prototype test.

Keep credentials out of code, logs and documentation. Preserve upstream provenance and licences. Use synthetic data for destructive fault trials. Run relevant native tests and build checks for changes; update validation and handover records with exact results and limits.

Use British English and concise explanations. Cairn ordinary-file offloading remains a separate future track.

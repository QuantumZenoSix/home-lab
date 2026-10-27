
UNFINISHED - BRAIN DUMP - WILL REVISE/EDIT


Planned or potential improvements include:

- Offsite backup of the encrypted Restic repository to Backblaze B2.
- Regular automated repository checks and documented restore tests.
- Independent monitoring for full-host outages.
- Additional investigation documentation into occasional service interruptions and host unresponsiveness.
- More comprehensive deployment and recovery documentation.

Offsite backup



Planned or potential improvements include:

Offsite backup of the encrypted Restic repository to Backblaze B2.
Regular automated repository checks and documented restore tests.
Independent monitoring for full-host outages.
Additional investigation documentation into occasional service interruptions and host unresponsiveness.
More comprehensive deployment and recovery documentation.



SSD should not be exFAT

auto_commit_obsidian.sh - should report to kuma


- **No offsite copy.** Losing the whole Pi, or both drives at once (theft, fire, or a power surge), loses everything. Backblaze B2 is planned.
- **The backup drive is writable over Samba.** The `myhdd-backup` share is writable by `ada`, will likely remove it (or at least not make it writable).
- **Prune failures are not reported.** The heartbeat is sent before `forget --prune` runs.

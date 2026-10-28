Places I could improve this project.  

### Concerns or bugs in need of priority fixes include:

- **No offsite copy.** Losing the whole Pi, or both drives at once (theft, fire, or a power surge), loses everything. Backblaze B2 is planned.
- **The backup drive is writable over Samba.** The `myhdd-backup` share is writable by `ada`, will likely remove it (or at least not make it writable).
- **Prune failures are not reported.** The heartbeat is sent before `forget --prune` runs.

<br />

### Planned or potential improvements include:

- Independent monitoring for full-host outages.
- Primary SSD should be ext4 instead of exFAT.
- `auto_commit_obsidian.sh` - should report to kuma
- Additional investigation documentation into occasional service interruptions and host unresponsiveness.
- Regular automated repository checks and documented restore tests.


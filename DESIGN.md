# DMS Jira plugin — design notes

A DankMaterialShell plugin that surfaces your assigned Jira tickets on the
DankBar and lets you act on them quickly (open in browser, transition state,
add a comment).

## Where the code lives

DMS discovers plugins by scanning `~/.config/DankMaterialShell/plugins/`.
Each plugin is one directory.

```
~/.config/DankMaterialShell/plugins/dms-jira/
├── plugin.json          # manifest
├── DmsJira.qml          # bar widget + popout (PluginComponent)
├── DmsJiraSettings.qml  # settings UI (PluginSettings)
├── JiraClient.qml       # HTTP wrapper around Jira REST v3
└── assets/
    └── jira.svg
```

Recommended workflow:

- Develop in a standalone git repo (e.g. `~/code/dms-jira/`) and symlink it
  into the plugins dir: `ln -s ~/code/dms-jira ~/.config/DankMaterialShell/plugins/dms-jira`.
- Hot reload with `dms ipc call plugins reload dmsJira` — no shell restart.
- Once stable, declaratively install via `xdg.configFile."DankMaterialShell/plugins/dms-jira".source = ./dms-jira;`
  in a home-manager module under `home/ivan/`. DMS treats the dir as
  mutable at runtime (state files write back), so use `recursive = true`
  and accept that the state JSON will live alongside as a sibling file in
  `~/.local/state/DankMaterialShell/dmsJira_state.json` (separate path,
  no conflict).

## plugin.json

```json
{
  "id": "dmsJira",
  "name": "Jira tickets",
  "description": "Assigned Jira tickets in DankBar",
  "version": "0.1.0",
  "author": "ivan",
  "type": "widget",
  "component": "./DmsJira.qml",
  "settings": "./DmsJiraSettings.qml",
  "permissions": ["network", "settings_read", "settings_write", "process"]
}
```

`process` is needed to shell out to `xdg-open` for opening tickets in the
browser. `network` is required for REST calls.

## Component shape

`DmsJira.qml` extends `PluginComponent` and provides:

- `horizontalBarPill` — small pill: icon + count of open assigned tickets,
  optionally the top ticket's key. Color shifts when something is overdue
  or has a recent mention.
- `verticalBarPill` — same data, stacked.
- `popoutContent` — `PopoutComponent` with a `DankListView` of tickets.
  Each row: key, summary, status chip, priority icon, age. Click row →
  open in browser. Right-click / long-press → action menu (transition,
  copy key, copy branch name, add comment).
- `popoutWidth: 480`, `popoutHeight: 600`.

A `Timer` polls Jira every N minutes (settings-controlled). Results cached
to plugin state so the bar paints immediately on shell start before the
first poll completes.

## Auth

Jira Cloud uses HTTP Basic with `email:api_token` against
`https://<site>.atlassian.net/rest/api/3/`. The token is created at
<https://id.atlassian.com/manage-profile/security/api-tokens>.

Storing the token: do **not** put it in `pluginData` (settings JSON lives in
`~/.config` and is world-readable in some setups). Options:

1. Read from a file path the user sets in settings (e.g.
   `~/.config/dms-jira/token` with 0600). Plugin reads file on poll.
2. Shell out to `secret-tool lookup` (libsecret / gnome-keyring) — needs
   `process` permission and an active keyring.
3. Read an env var exported into the DMS systemd user unit.

Option 1 is the simplest first cut. Option 2 is the right end state.

## JQL

Default query for "things I should care about":

```
assignee = currentUser()
  AND statusCategory != Done
ORDER BY updated DESC
```

Make it a settings string so you can swap in team-specific JQL, or expose
a few named saved queries (My open / Mentioned me / In review).

## Actions surface

From the popout row:

- **Click** → `xdg-open https://<site>.atlassian.net/browse/<KEY>`
- **Middle-click / "copy"** → copy `<KEY>` and `<KEY>-summary-slug` to clipboard
  (the slug form is what you want for branch names — `git checkout -b ABC-123-fix-thing`)
- **Action menu**:
  - Transition status (fetch available transitions, render submenu)
  - Add comment (small text input → POST /comment)
  - Open in browser
  - Copy branch name
  - Assign to someone else (probably skip for v1)

POST endpoints to know:

- `POST /rest/api/3/issue/{key}/transitions` with `{"transition": {"id": "31"}}`
- `POST /rest/api/3/issue/{key}/comment` with ADF body

## Polling vs webhooks

Polling at 2–5 min is fine for personal use; webhooks need a public
endpoint and aren't worth it for one user. Use ETag/If-None-Match on the
search endpoint to keep cost down.

## State vs settings

- **Settings** (`pluginData`, user-edited in UI): site URL, email, token
  path, JQL, poll interval, display mode (count-only / count+top-key),
  notification toggle.
- **State** (`pluginService.savePluginState`): last successful fetch
  timestamp, cached ticket list, last-seen issue updated timestamps (to
  detect "new since last check" for badge styling).

## Notifications

Optional v2: when polling detects a newly-assigned ticket or a new comment
mentioning you, fire a DMS notification via `dms ipc call notifications send`.

## v1 scope (resolved)

1. **Jira flavor.** Cloud only for v1. Code is structured to make Data
   Center a later swap: a `JiraClient.qml` wraps every endpoint, and the
   one or two DC differences (auth header, `/rest/api/2` vs `/3`, ADF vs
   wiki markup for comments) live behind a `flavor` setting that's
   hidden in v1 and exposed in v1.1.
2. **Sites.** One site. But the settings schema stores it as a list of
   one (`sites: [{ url, email, tokenPath }]`) so multi-site in v2 is an
   additive change, not a migration.
3. **My list.** `assignee = currentUser() AND statusCategory != Done
   ORDER BY updated DESC`. JQL is overridable in settings for power use.
4. **Bar pill.** Count + active key. "Active" resolves as:
   - If a key is pinned (set via popout right-click → "Pin to bar"),
     show that key. Pin survives restarts (stored in plugin state).
   - Otherwise, show the most-recently-updated assigned ticket.
   - Right-click the pill itself → "Unpin" / "Pin top updated".

   This gives you the auto behavior by default, with one click to lock
   the pill to whatever you're actively working on.
5. **Click model.** Click pill → popout. In popout: row click → open in
   browser (`xdg-open`). Row right-click → action menu. Cmd/Ctrl-click
   row → open and close popout.
6. **Write actions in v1.** Transitions and comments are both in.
   Assign-to-someone-else stays out of v1.
7. **Comment composer.** Plain text in v1, with line breaks preserved as
   separate ADF paragraphs (each `\n\n` boundary becomes a new paragraph,
   single `\n` becomes a hard break). This covers ~95% of real-world
   comments ("deploying now", "fixed in PR #123 https://..."). URLs are
   auto-linked. v1.1 adds light markdown (bold/italic/`code`/lists) via
   a small in-tree ADF builder — no external dep.
8. **Branch name.** Default `<KEY>-<slug>`, where slug is the summary
   lowercased, ASCII-folded, non-alphanumerics collapsed to `-`, trimmed
   to 50 chars on a word boundary. Example: `ABC-123-fix-login-redirect-loop`.
   A settings toggle "Prefix with issue type" prepends `feature/` /
   `bug/` / `chore/` derived from `fields.issuetype.name` (lowercased,
   mapped: Bug→bug, Task/Story→feature, anything else→chore).
9. **Notifications.** Off by default. When enabled, two event classes
   only:
   - New ticket assigned to me (detected by diffing the previous poll's
     key set).
   - New comment on one of my open tickets that @mentions me (detected
     by polling each open ticket's comments since last-poll timestamp,
     filtering by `accountId` in mention nodes).

   Both go through `dms ipc call notifications send`. Status changes on
   my own tickets are intentionally excluded — too noisy when you're
   the one moving them.
10. **Distribution.** Target the [DMS plugin registry](https://github.com/AvengeMedia/dms-plugin-registry).
    Registry-readiness adds these constraints to v1:
    - MIT license, README with screenshots, screenshots in `assets/`.
    - No personal info in defaults; site URL / email / token path all
      empty until user configures.
    - Token storage supports both file-path (default) and libsecret
      (`secret-tool lookup service jira account <email>`), selected by
      a `tokenSource` setting. File-path is the documented default in
      the README so new users don't need a keyring set up.
    - `requires_dms` field in `plugin.json` pinning a minimum DMS
      version once we know which APIs we depend on.

## v1 deliverable checklist

- [ ] `plugin.json` with manifest fields above
- [ ] `DmsJira.qml` — `PluginComponent` with `horizontalBarPill`,
      `verticalBarPill`, `popoutContent`, pin/unpin context actions
- [ ] `DmsJiraSettings.qml` — site URL, email, token source (file path
      or libsecret), JQL override, poll interval, pill display mode,
      branch prefix toggle, notifications toggle
- [ ] `JiraClient.qml` — `search`, `getTransitions`, `doTransition`,
      `addComment`, ETag cache, error surfacing
- [ ] `AdfBuilder.qml` (or `.js`) — plain-text → ADF doc
- [ ] State persistence: `cachedIssues`, `pinnedKey`, `lastPollAt`,
      `seenCommentIds` (for mention-notification dedupe)
- [ ] README + 2–3 screenshots
- [ ] LICENSE (MIT)

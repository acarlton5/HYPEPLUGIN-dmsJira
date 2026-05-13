# Jira Tickets

A DankMaterialShell plugin that shows your assigned Jira Cloud tickets on the
DankBar, with quick actions for opening, transitioning, and commenting on them.

![Screenshot](assets/screenshot.png)

## Features

- A bar pill with the count of assigned tickets and the key of the "active"
  ticket. The active ticket is the most recently updated one, unless you pin a
  ticket (right-click the pill); pins survive restarts.
- A popout list of your tickets showing priority, issue type, status, and
  summary. Can be grouped by project.
- Click a ticket to open it in the browser. Right-click a row for actions:
  open, pin/unpin, copy key, copy a branch name (`ABC-123-short-summary`,
  optionally prefixed `feature/`, `bug/`, or `chore/`), change status (lists
  the issue's available transitions), or add a comment.
- Comments are written as plain text and converted to Jira's ADF format: blank
  lines become paragraphs, single newlines become line breaks, URLs are linked.
- Optional notifications (off by default) for tickets newly assigned to you and
  for new comments that @mention you on your open tickets.
- The last poll is cached, so the bar is populated immediately on startup.
- The ticket query is plain JQL and can be changed in settings.
- A demo mode that swaps in fake tickets and skips the Jira API, for screenshots
  or trying the UI without credentials.

## Requirements

- DankMaterialShell.
- A Jira Cloud site and an Atlassian API token.
- `wl-clipboard`, for the copy actions.
- `libnotify` (`notify-send`), if you enable notifications.
- `libsecret` (`secret-tool`), if you keep the token in a keyring rather than a
  file.

The plugin uses the `network`, `process`, `settings_read`, and `settings_write`
permissions.

## Installing

DMS loads plugins from `~/.config/DankMaterialShell/plugins/`, one directory
each. Clone this repo there and enable it under Settings -> Plugins:

```sh
git clone https://github.com/Klievan/dms-jira \
    ~/.config/DankMaterialShell/plugins/dms-jira
```

If it doesn't appear, reload: `dms ipc call plugins reload dmsJira`.

For development, symlink the repo instead and run the same reload command after
edits:

```sh
ln -s ~/code/dms-jira ~/.config/DankMaterialShell/plugins/dms-jira
```

With Nix / home-manager:

```nix
xdg.configFile."DankMaterialShell/plugins/dms-jira".source = ./dms-jira;
```

## API token

Create a token at
<https://id.atlassian.com/manage-profile/security/api-tokens>. Jira Cloud
authenticates with your account email plus the token (HTTP Basic), not your
password. The plugin reads the token from a file or from libsecret; it is never
written to the plugin's settings.

File:

```sh
mkdir -p ~/.config/dms-jira
( umask 077; printf '%s\n' 'YOUR_TOKEN' > ~/.config/dms-jira/token )
```

Then set the token file path in settings (must be absolute).

libsecret:

```sh
secret-tool store --label 'dms-jira API token' \
    service dms-jira account you@example.com
```

Then set the token source to libsecret. The plugin looks it up with
`secret-tool lookup service dms-jira account <your email>`. After changing
either store, reload the plugin so it re-reads the token.

## Configuration

Settings -> Plugins -> Jira Tickets:

- `Site URL`: `https://your-org.atlassian.net`. Must be HTTPS.
- `Email`: your Atlassian account email.
- `Token source`: file or libsecret.
- `Token file path`: absolute path to the token file (file source only).
- `JQL`: the ticket query. Default
  `assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC`.
  Up to 50 issues are shown.
- `Poll interval`: 1 to 60 minutes (default 5). Editing the connection or query
  settings also triggers an immediate refresh.
- `Show active ticket key on bar`: if off, the pill shows only the count.
- `Prefix branch name with issue type`: adds `feature/`, `bug/`, or `chore/`.
- `Group by project`: groups the popout list by project.
- `New assignment` / `@mentions` notifications: off by default. The first poll
  after enabling only records current state; notifications start from the next
  poll. The `@mentions` check costs one extra API request per open ticket.
- `Demo mode`: use fake data and skip the Jira API.

## Notes

- HTTPS is required. The plugin will not send credentials to a non-HTTPS site
  URL or open a non-HTTPS link.
- Cached ticket summaries are written unencrypted to DMS plugin state
  (`~/.local/state/DankMaterialShell/dmsJira_state.json`) so the bar can render
  before the first poll. Use demo mode or delete that file if ticket titles are
  sensitive on disk.
- The plugin uses Jira Cloud's `/rest/api/3/search/jql` endpoint.
- Jira Data Center / Server is not supported.

## Troubleshooting

- Popout says "Not configured": set the site URL and email.
- HTTP 401: wrong email or token. Use the API token, not your password, and the
  email shown on the Atlassian token page.
- HTTP 400 after editing the JQL: the query is invalid; check it in Jira's
  issue search.
- Empty list, no error: the JQL matched nothing. Demo mode confirms the UI
  works.
- Copy actions do nothing: install `wl-clipboard`.
- No notifications: install `libnotify`, make sure a notification daemon is
  running, and remember the first poll after enabling is silent.

## License

MIT. See [LICENSE](LICENSE).

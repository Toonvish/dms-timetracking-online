# TimeTracking Online for DMS

A [DMS](https://duxlabs.dev) (dux-shell) bar widget for
[TimeTracking Online](https://www.timetracking-online.com): see today's
working time in your bar and clock in, take a break or leave without opening
the web app.

Unofficial; not affiliated with the makers of TimeTracking Online.

## Features

- **Bar:** today's net working time, with an icon and colour for your current
  state (office, homeoffice, business trip, on break, not tracking) and a cake
  when a colleague has a birthday.
- **Panel:**
  - **Today:** a ring showing progress toward your daily target, time left
    and when you'll be done, first clock-in, break time, and the week so far
  - **Overtime:** today (live), this month, and your overtime balance
  - **This week:** Monday to Sunday bars with a tick at each day's target
  - **Vacation:** days used and left this year, plus your next absences
  - **Bookings:** buttons for exactly the bookings your account allows right
    now (as configured by your company): e.g. *Break* and *Leave* while
    working, *Start homeoffice* or *Start (office)* when you're out

Everything runs inside the shell: QML and JavaScript talking to the
TimeTracking Online REST API directly. No extra binaries, no curl or jq.

## Requirements

- DMS (dux-shell) 1.7 or newer
- `secret-tool` from libsecret (Arch: `libsecret`, Debian/Ubuntu:
  `libsecret-tools`, Fedora: `libsecret`) and a running keyring such as
  GNOME Keyring or KeePassXC's Secret Service
- A TimeTracking Online account with API access (the same login as the web
  app)

## Installation

Clone the repository into your DMS plugins directory:

```bash
git clone https://github.com/Toonvish/dms-timetracking-online \
  ~/.config/dms/plugins/TimeTrackingOnline
```

Then in DMS Settings (`Mod + ,`):

1. **Plugins** → rescan if needed, enable **TimeTracking Online**
2. Open its settings and fill in:
   - **API URL:** your company's API, usually
     `https://<company>.timetracking-online.com/api`
   - **Username:** the name you sign in to the web app with
   - **Password:** type it and press **Save to keyring**
3. **Bar widgets** → add **TimeTracking Online** to a bar section

To update: `git -C ~/.config/dms/plugins/TimeTrackingOnline pull`, then
reload the plugin or restart DMS.

## Settings

| Setting | Default | |
|---|---|---|
| API URL | – | Base URL of your TimeTracking Online API |
| Username | – | Your login name |
| Password | – | Stored in the system keyring, see below |
| Refresh interval | 60 s | How often the bar updates; the panel also refreshes when opened, and its extra data every 10 minutes |
| Show week total in bar | off | Adds the week's total next to today's time |

## Privacy and security

- The **password** is stored in your system keyring with `secret-tool`
  (attributes `service=dms-timetracking-online`, `account=<username>`). It is
  never written to DMS's settings files. To remove it:
  `secret-tool clear service dms-timetracking-online account <username>`.
- The **login token** the API returns is cached in DMS's plugin state
  (`~/.local/state/dms/plugins/timeTrackingOnline_state.json`) so the shell
  doesn't log in on every refresh. It's refreshed automatically; the password
  is only read from the keyring when a fresh login is needed.
- The plugin only talks to the API URL you configure.

## How it works

The plugin uses the documented
[TimeTracking HTTP API](https://demo.timetracking-online.com/api/docs/index.html):

| What | Endpoint |
|---|---|
| Login | `POST auth/authorize` (password, then refresh-token grant) |
| Today's live minutes | `GET working_time/days/user/live` |
| Current entry | `GET working_time/entries/current` |
| Allowed bookings | `GET working_time/booking_types/currently_allowed/my` |
| Week | `GET working_time/days/user?from&to` |
| Month | `GET working_time/months/my?yearMonth` |
| Overtime account | `GET time_balances/current/my` |
| Vacation | `GET absence_balances/my/all?periodYear` |
| Upcoming absences | `GET working_time_exceptions/slimmed/my` |
| Today's entries (first clock-in, breaks) | `GET working_time/entries?fromBalanceDate&toBalanceDate` |
| Birthdays | `GET users/attendance` |
| Start (e.g. homeoffice) | `POST working_time/entries/my` |
| Break / leave | `PUT working_time/entries/complete/{id}/my` |

Notes:

- Month and overtime account values cover days up to the last assessed day,
  like the web app ("values until …"). The balance in the panel adds today's
  live overtime on top.
- The API only returns days up to today, so the week assumes today's target
  for the remaining weekdays.
- Break time is the sum of the gaps between today's entries, plus a running
  break. The API's own day summary lags behind until the day is assessed.
- While an entry is open the panel only offers ending bookings (break, leave),
  otherwise only starting ones, from the list the API allows.

## Development

The pure logic (formatting, state, week, absences, bookings) lives in
`TimeTracking.js` and is unit-tested with Node:

```bash
node --test
```

`TimeTrackingClient.qml` is the API client, `TimeTrackingWidget.qml` the bar
widget and panel, `TimeTrackingSettings.qml` the settings page.

## License

MIT

# Changelog

## 1.1.0 — 2026-11-19

- **Price alerts (optional, off by default)**: set an *above* and/or *below*
  limit per asset in the right-click settings. When a price crosses a limit
  you get one local notification with the asset, the price, the quote time
  and the day's change, plus a short, soft chime (can be turned off).
- Each limit fires once per crossing and re-arms only after the price is
  clearly back inside it (0.25% margin), so a price hovering on the line
  does not notify on every refresh. Restarting the shell or saving settings
  never re-notifies for a limit that is already crossed.
- Limits accept `5,95`, `5.95`, `1.234,56` or `1,234.56`; invalid entries are
  highlighted and ignored.
- Details panel lists each asset's active limits.
- New IPC call `testAlert` sends a sample notification and chime.
- Bundled chime (`sounds/chime.oga`), played with `pw-play`, falling back to
  `paplay`.

## 1.0.0 — 2026-11-19

- First release.
- Shows up to 3 assets in the bar as `NAME ▲ price`: B3 stocks (`PETR4`,
  `VALE3`, `TAEE11`, …), BRL currency pairs (`USDBRL`, `EURBRL`, …) and the
  Ibovespa (`IBOV`). Defaults to `USDBRL` and `EURBRL`.
- Trend arrow versus the previous close, colored with the theme's green/red.
- Right-click settings form: pick assets by typing a company name or ticker,
  with live suggestions; refresh interval; arrow coloring.
- Left-click details panel with change, day range and previous close.
- English and Portuguese translations; numbers follow the Omarchy language.

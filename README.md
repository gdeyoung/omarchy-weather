# WeatherX (gdeyoung.weather)

Extended weather for the Omarchy bar: current temperature in the bar, a large
tabbed dropdown panel, and a live radar map — all keyless.

## Features

- **Bar widget** — weather glyph + current temperature for this device's
  location (from Omarchy's configured location). Right-click cycles the bar
  label mode.
- **Tabbed panel** (left-click):
  - **[Here]** follows this device; pinned places get their own tabs.
  - **[+] tab** adds any city by name via Open-Meteo geocoding. Click a pinned
    tab twice to remove it.
  - Current conditions with feels-like, high/low, and an "updated N ago" stamp.
  - Details grid with level bars: wind, gusts, humidity, pressure, UV, dew
    point, AQI, chance of rain now.
  - Remaining-hours strip starting at NOW.
  - 7-day forecast.
  - Sunrise / sunset.
- **Live radar map** beside the 7-day — Esri dark basemap and labels with a
  RainViewer precipitation overlay, centered on the active tab's location,
  refreshed from the latest public radar frame. ⟳ refetches; the radar button
  opens the full interactive view on windy.com.

## Data sources (no API keys)

- Forecast + air quality: [Open-Meteo](https://open-meteo.com/)
- Geocoding: Open-Meteo geocoding API
- Radar frames: [RainViewer](https://www.rainviewer.com/) public weather maps
- Basemap + labels: Esri World Dark Gray (Canvas tiles)

Fetches run through a per-location file bus (`~/.local/state/gdeyoung.weather/`)
— the bar label and panel can never disagree.

## Settings

Configured via the plugin's gear/settings entry (or `~/.config/omarchy/shell.json`):

| Key | Default | Meaning |
|---|---|---|
| `barExtra` | `temp` | Bar label mode: temp / icon+temp / icon |
| `refreshMin` | `15` | Forecast refresh interval (min 5) |
| `units` | `imperial` | `imperial` or `metric` |
| `pinnedLocations` | St. Anne IL | JSON array of `{name, lat, lon}` |

## Install

    omarchy plugin add https://github.com/gdeyoung/omarchy-weather.git --enable

## License

MIT — see [LICENSE](LICENSE). Radar imagery © RainViewer; basemap © Esri.

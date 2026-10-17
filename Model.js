// gdeyoung.weather v0.2 — pure helpers. No Quickshell imports; every function
// is deterministic given its arguments.
//
// Data: Open-Meteo (forecast + air quality, no key). One file per location in
// ~/.local/state/gdeyoung.weather/<key>.json — "here" is the device location
// (omarchy-weather-location file, else IP autodetect via empty query).

.pragma library

var STATE_DIR = ".local/state/gdeyoung.weather";
var OMARCHY_LOCATION = ".local/state/omarchy/settings/weather.json";

// Default pinned tabs, used when the widget instance predates the setting.
var DEFAULT_PINNED = '[{"name":"St. Anne IL","lat":41.02503,"lon":-87.71392}]';

// ---- locations ----------------------------------------------------------

// Pinned tabs come from plugin settings as a JSON string; "here" is special.
function parsePinned(raw) {
  var out = [];
  try {
    var arr = typeof raw === "string" ? JSON.parse(raw) : raw;
    if (Object.prototype.toString.call(arr) !== "[object Array]")
      return out;
    for (var i = 0; i < arr.length; i++) {
      var p = arr[i];
      if (!p || !p.name)
        continue;
      var lat = Number(p.lat), lon = Number(p.lon);
      if (!isFinite(lat) || !isFinite(lon))
        continue;
      out.push({ key: slugify(p.name), name: String(p.name), lat: lat, lon: lon });
    }
  } catch (e) {}
  return out;
}

function slugify(name) {
  return String(name).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "loc";
}

function locationQuery(omarchyLocation) {
  if (!omarchyLocation)
    return "";
  if (omarchyLocation.latitude !== undefined && omarchyLocation.longitude !== undefined)
    return String(omarchyLocation.latitude) + "," + String(omarchyLocation.longitude);
  var name = typeof omarchyLocation === "string" ? omarchyLocation : omarchyLocation.name;
  return name ? String(name) : "";
}

function locationName(omarchyLocation, fallback) {
  if (omarchyLocation && omarchyLocation.name)
    return String(omarchyLocation.name);
  return fallback || "Here";
}

// ---- fetch URLs ---------------------------------------------------------

function imperial(units) {
  if (units === "metric")
    return false;
  return true; // imperial default; "auto" resolves to US on this machine
}

function buildForecastUrl(lat, lon, units) {
  var us = imperial(units);
  var temp = us ? "fahrenheit" : "celsius";
  var wind = us ? "mph" : "kmh";
  return "https://api.open-meteo.com/v1/forecast"
    + "?latitude=" + encodeURIComponent(lat) + "&longitude=" + encodeURIComponent(lon)
    + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,is_day,"
      + "wind_speed_10m,wind_gusts_10m,wind_direction_10m,surface_pressure,uv_index,dew_point_2m,precipitation"
    + "&hourly=temperature_2m,precipitation_probability,weather_code,visibility"
    + "&daily=weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,uv_index_max,precipitation_probability_max"
    + "&timezone=auto&forecast_days=7&past_hours=1"
    + "&temperature_unit=" + temp + "&wind_speed_unit=" + wind;
}

function buildAirUrl(lat, lon) {
  return "https://air-quality-api.open-meteo.com/v1/air-quality"
    + "?latitude=" + encodeURIComponent(lat) + "&longitude=" + encodeURIComponent(lon)
    + "&current=us_aqi,pm2_5,pm10&timezone=auto";
}

function buildGeocodeUrl(q) {
  return "https://geocoding-api.open-meteo.com/v1/search?count=6&language=en&format=json&name="
    + encodeURIComponent(q);
}

// ---- WMO weather codes ----------------------------------------------------

var WMO = {
  0: ["☀️", "Clear"], 1: ["🌤️", "Mostly clear"], 2: ["⛅", "Partly cloudy"],
  3: ["☁️", "Overcast"], 45: ["🌫️", "Fog"], 48: ["🌫️", "Freezing fog"],
  51: ["🌦️", "Light drizzle"], 53: ["🌦️", "Drizzle"], 55: ["🌧️", "Heavy drizzle"],
  56: ["🌧️", "Freezing drizzle"], 57: ["🌧️", "Freezing drizzle"],
  61: ["🌦️", "Light rain"], 63: ["🌧️", "Rain"], 65: ["🌧️", "Heavy rain"],
  66: ["🌧️", "Freezing rain"], 67: ["🌧️", "Freezing rain"],
  71: ["🌨️", "Light snow"], 73: ["🌨️", "Snow"], 75: ["❄️", "Heavy snow"],
  77: ["🌨️", "Snow grains"],
  80: ["🌦️", "Light showers"], 81: ["🌧️", "Showers"], 82: ["🌧️", "Heavy showers"],
  85: ["🌨️", "Snow showers"], 86: ["❄️", "Heavy snow showers"],
  95: ["⛈️", "Thunderstorm"], 96: ["⛈️", "Hail storm"], 99: ["⛈️", "Hail storm"]
};

function glyph(code, isNight) {
  if (Number(code) === 0)
    return isNight ? "🌙" : "☀️";
  var e = WMO[Number(code)];
  return e ? e[0] : "🌡️";
}

function condText(code) {
  var e = WMO[Number(code)];
  return e ? e[1] : "";
}

// ---- formatting -----------------------------------------------------------

function temp(v) {
  if (v === undefined || v === null || !isFinite(Number(v)))
    return "--°";
  return Math.round(Number(v)) + "°";
}

function windDir(deg) {
  var d = Number(deg);
  if (!isFinite(d))
    return "";
  var pts = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"];
  return pts[Math.round(((d % 360) / 22.5)) % 16];
}

function hourLabel(iso) {
  var m = /T(\d{2}):(\d{2})/.exec(String(iso || ""));
  if (!m)
    return "";
  var h = parseInt(m[1], 10);
  var ampm = h >= 12 ? "PM" : "AM";
  var h12 = h % 12;
  if (h12 === 0)
    h12 = 12;
  return h12 + ampm;
}

function timeToMinutes(hhmm) {
  var m = /^(\d{1,2}):(\d{2})/.exec(String(hhmm || ""));
  if (!m)
    return -1;
  return parseInt(m[1], 10) * 60 + parseInt(m[2], 10);
}

function daylightLength(sunrise, sunset) {
  var a = timeToMinutes(sunrise), b = timeToMinutes(sunset);
  if (a < 0 || b < 0)
    return "";
  var d = b - a;
  var hh = Math.floor(d / 60), mm = d % 60;
  return hh + "h " + (mm < 10 ? "0" : "") + mm + "m";
}

function isNight(sunrise, sunset) {
  var a = timeToMinutes(sunrise), b = timeToMinutes(sunset);
  if (a < 0 || b < 0)
    return false;
  var now = new Date();
  var cur = now.getHours() * 60 + now.getMinutes();
  return cur < a || cur > b;
}

function uvCategory(v) {
  var n = Number(v);
  if (isNaN(n))
    return "";
  if (n < 3) return "Low";
  if (n < 6) return "Moderate";
  if (n < 8) return "High";
  if (n < 11) return "Very High";
  return "Extreme";
}

function aqiCategory(v) {
  var n = Number(v);
  if (isNaN(n))
    return "";
  if (n <= 50) return "Good";
  if (n <= 100) return "Moderate";
  if (n <= 150) return "Unhealthy (sens)";
  if (n <= 200) return "Unhealthy";
  if (n <= 300) return "Very Unhealthy";
  return "Hazardous";
}

function shortDay(dateStr) {
  var d = new Date(String(dateStr) + "T12:00:00");
  if (isNaN(d.getTime()))
    return String(dateStr);
  var names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  return names[d.getDay()];
}

function relativeAge(isoUtc) {
  var then = new Date(isoUtc);
  if (isNaN(then.getTime()))
    return "";
  var mins = Math.max(0, Math.round((Date.now() - then.getTime()) / 60000));
  if (mins < 1)
    return "just now";
  if (mins < 60)
    return mins + " min ago";
  return Math.round(mins / 60) + "h ago";
}

// ---- hourly: remaining hours of today, NOW first --------------------------

// Array of {time, temp, pop, code, isNow} starting at the hour block that
// contains "now" (labeled NOW), spanning forward across midnight when the
// local day runs short so the strip never collapses late at night.
function remainingHours(j, count) {
  var out = [];
  if (!j || !j.hourly || !j.hourly.time)
    return out;
  var times = j.hourly.time;
  var nowMs = Date.now();
  var startIdx = -1;
  for (var i = 0; i < times.length; i++) {
    var t = new Date(times[i]).getTime();
    if (!isNaN(t) && t + 3599999 >= nowMs) {
      startIdx = i;
      break;
    }
  }
  if (startIdx < 0)
    return out;
  var take = count || 12;
  for (var k = 0; k < take && startIdx + k < times.length; k++) {
    var idx = startIdx + k;
    out.push({
      time: times[idx],
      temp: j.hourly.temperature_2m[idx],
      pop: j.hourly.precipitation_probability ? j.hourly.precipitation_probability[idx] : undefined,
      code: j.hourly.weather_code ? j.hourly.weather_code[idx] : undefined,
      isNow: k === 0
    });
  }
  return out;
}

function barLabel(mode, j) {
  if (!j || !j.current)
    return "";
  if (mode === "icon")
    return "";
  if (mode === "tempcondition")
    return temp(j.current.temperature_2m) + " " + condText(j.current.weather_code).split(" ").slice(0, 2).join(" ");
  return temp(j.current.temperature_2m);
}

function nextBarMode(mode) {
  return mode === "temp" ? "tempcondition" : mode === "tempcondition" ? "icon" : "temp";
}

// Radar deep-link for the open tab (Windy radar layer, keyless web view).
function radarUrl(lat, lon) {
  return "https://www.windy.com/?radar," + Number(lat).toFixed(3) + "," + Number(lon).toFixed(3) + ",8";
}

// ---- inline radar tiles (CARTO dark basemap + RainViewer overlay, no key) --

// Fractional slippy-tile coordinates for lat/lon at zoom z.
function tileFraction(lat, lon, z) {
  var la = Number(lat) * Math.PI / 180;
  if (!isFinite(la) || Math.abs(la) > Math.PI / 2 - 1e-9)
    return null;
  var n = Math.pow(2, z);
  return {
    fx: (Number(lon) + 180) / 360 * n,
    fy: (1 - Math.log(Math.tan(la) + 1 / Math.cos(la)) / Math.PI) / 2 * n
  };
}

// Tile window (x0,y0 .. +cols,+rows) that keeps the point centered, plus the
// exact offset of the point inside the window as tile fractions (0..1).
function radarTileWindow(lat, lon, z, cols, rows) {
  var f = tileFraction(lat, lon, z);
  if (!f)
    return null;
  var x0 = Math.round(f.fx - cols / 2);
  var y0 = Math.round(f.fy - rows / 2);
  return { z: z, x0: x0, y0: y0, cols: cols, rows: rows, px: f.fx - x0, py: f.fy - y0 };
}

// Dark basemap tiles: Esri World Dark Gray (keyless; note Esri's z/y/x order).
function radarBaseTileUrl(z, x, y) {
  return "https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Base/MapServer/tile/"
    + z + "/" + y + "/" + x;
}

// Matching label/reference layer (cities, state lines) — stacked above radar.
function radarLabelTileUrl(z, x, y) {
  return "https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Reference/MapServer/tile/"
    + z + "/" + y + "/" + x;
}

// RainViewer radar overlay: color scheme 4 (TWC blue→red), smoothed, snow on.
function radarFrameTileUrl(host, path, z, x, y) {
  return host + path + "/256/" + z + "/" + x + "/" + y + "/4/1_1.png";
}

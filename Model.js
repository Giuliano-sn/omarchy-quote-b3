.pragma library

// Pure helpers for the Quote B3 widget: symbol rules, Yahoo Finance URLs and
// response parsing. No QML here so tests/test_model.js can run it under node.

var MAX_SYMBOLS = 3
var DEFAULT_SYMBOLS = ["USDBRL", "EURBRL"]
var MAX_RESPONSE_CHARS = 512 * 1024
var MAX_QUERY_CHARS = 40
var MAX_NAME_CHARS = 60
var MAX_SUGGESTIONS = 8
var USER_AGENT = "Mozilla/5.0"
var BASE = "https://query1.finance.yahoo.com"

var INDEX_ALIASES = { "IBOV": "^BVSP", "IBOVESPA": "^BVSP", "BVSP": "^BVSP" }

// What the user types or what Yahoo returns -> the short name shown in the
// bar ("PETR4", "USDBRL", "IBOV"), or "" when it is not something we track.
function normalizeSymbol(raw) {
  var s = String(raw === undefined || raw === null ? "" : raw).toUpperCase()
  s = s.replace(/^\s+|\s+$/g, "")
  if (s === "^BVSP") return "IBOV"
  s = s.replace(/\.SA$/, "").replace(/=X$/, "").replace(/[^A-Z0-9]/g, "")
  if (INDEX_ALIASES[s]) return "IBOV"
  if (/^[A-Z]{6}$/.test(s)) return s                 // currency pair
  if (/^[A-Z]{4}[0-9]{1,2}F?$/.test(s)) return s     // B3 ticker
  return ""
}

function isCurrency(symbol) {
  return /^[A-Z]{6}$/.test(String(symbol || ""))
}

// Short name -> Yahoo symbol.
function yahooSymbol(symbol) {
  var s = normalizeSymbol(symbol)
  if (s === "") return ""
  if (s === "IBOV") return "^BVSP"
  if (isCurrency(s)) return s + "=X"
  return s + ".SA"
}

// Settings value -> clean list of at most three distinct short names.
// A missing setting means the defaults; a saved empty list stays empty.
function symbolList(value) {
  if (value === undefined || value === null) return DEFAULT_SYMBOLS.slice()
  var arr = []
  if (typeof value === "string") arr = value.split(/[,\s]+/)
  else if (value && typeof value.length === "number") {
    for (var i = 0; i < value.length; i++) arr.push(value[i])
  }
  var out = []
  for (var j = 0; j < arr.length && out.length < MAX_SYMBOLS; j++) {
    var s = normalizeSymbol(arr[j])
    if (s !== "" && out.indexOf(s) === -1) out.push(s)
  }
  return out
}

function quotesUrl(symbols) {
  var list = []
  for (var i = 0; i < symbols.length; i++) {
    var y = yahooSymbol(symbols[i])
    if (y !== "") list.push(y)
  }
  if (list.length === 0) return ""
  return BASE + "/v7/finance/spark?symbols=" + encodeURIComponent(list.join(",")) + "&range=1d&interval=1d"
}

function cleanQuery(q) {
  return String(q || "").replace(/[\u0000-\u001f]/g, "").replace(/^\s+|\s+$/g, "").slice(0, MAX_QUERY_CHARS)
}

function searchUrl(q) {
  var query = cleanQuery(q)
  if (query.length < 2) return ""
  return BASE + "/v1/finance/search?q=" + encodeURIComponent(query) + "&quotesCount=20&newsCount=0&lang=pt-BR&region=BR"
}

function curlArgs(url) {
  return ["curl", "-fsS", "--max-time", "10", "--max-filesize", String(MAX_RESPONSE_CHARS),
          "-A", USER_AGENT, "-H", "Accept: application/json", url]
}

function cleanName(value) {
  var s = String(value === undefined || value === null ? "" : value)
  s = s.replace(/[\u0000-\u001f<>]/g, "").replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "")
  return s.length > MAX_NAME_CHARS ? s.slice(0, MAX_NAME_CHARS - 1) + "…" : s
}

function num(v) {
  var n = Number(v)
  return (v === null || v === undefined || v === "" || !isFinite(n)) ? NaN : n
}

function parseJson(text) {
  var raw = String(text || "")
  if (raw.length === 0 || raw.length > MAX_RESPONSE_CHARS) return null
  try { return JSON.parse(raw) } catch (e) { return null }
}

function decimalsFor(symbol) {
  if (symbol === "IBOV") return 0
  if (isCurrency(symbol)) return 4
  return 2
}

// Spark response -> { SHORTNAME: quote }. Symbols Yahoo does not know are
// simply missing from the result.
function parseQuotes(text) {
  var data = parseJson(text)
  var out = {}
  var results = data && data.spark && data.spark.result
  if (!results || typeof results.length !== "number") return out
  for (var i = 0; i < results.length && i < 10; i++) {
    var r = results[i]
    var resp = r && r.response && r.response[0]
    var meta = resp && resp.meta
    if (!meta) continue
    var symbol = normalizeSymbol(meta.symbol || r.symbol)
    if (symbol === "") continue
    var price = num(meta.regularMarketPrice)
    if (isNaN(price) || price <= 0) continue
    var prev = num(meta.chartPreviousClose)
    if (isNaN(prev)) prev = num(meta.previousClose)
    var change = num(meta.fulldayChange)
    if (isNaN(change) && !isNaN(prev)) change = price - prev
    if (isNaN(change)) change = 0
    var pct = num(meta.regularMarketChangePercent)
    if (isNaN(pct)) pct = num(meta.fulldayChangePercent)
    if (isNaN(pct)) pct = (!isNaN(prev) && prev > 0) ? (price - prev) / prev * 100 : 0
    var t = num(meta.regularMarketTime)
    out[symbol] = {
      symbol: symbol,
      name: cleanName(meta.longName || meta.shortName || symbol),
      price: price,
      previousClose: isNaN(prev) ? null : prev,
      change: change,
      changePercent: pct,
      trend: trendOf(change),
      dayHigh: isNaN(num(meta.regularMarketDayHigh)) ? null : num(meta.regularMarketDayHigh),
      dayLow: isNaN(num(meta.regularMarketDayLow)) ? null : num(meta.regularMarketDayLow),
      marketTime: (isNaN(t) || t <= 0 || t > 4102444800) ? 0 : t * 1000,
      decimals: decimalsFor(symbol)
    }
  }
  return out
}

function trendOf(change) {
  var c = Number(change)
  if (!isFinite(c) || Math.abs(c) < 1e-9) return 0
  return c > 0 ? 1 : -1
}

function arrow(trend) {
  return trend > 0 ? "▲" : (trend < 0 ? "▼" : "■")
}

// Names Yahoo's search does not map to BRL pairs.
var LOCAL_ALIASES = [
  { symbol: "USDBRL", name: "US Dollar / Brazilian Real", words: ["dolar", "dollar", "usd"] },
  { symbol: "EURBRL", name: "Euro / Brazilian Real", words: ["euro", "eur"] },
  { symbol: "GBPBRL", name: "British Pound / Brazilian Real", words: ["libra", "pound", "gbp"] },
  { symbol: "ARSBRL", name: "Argentine Peso / Brazilian Real", words: ["peso argentino", "argentine peso", "ars"] },
  { symbol: "JPYBRL", name: "Japanese Yen / Brazilian Real", words: ["iene", "yen", "jpy"] },
  { symbol: "CNYBRL", name: "Chinese Yuan / Brazilian Real", words: ["yuan", "cny"] },
  { symbol: "IBOV", name: "Ibovespa index", words: ["ibovespa", "bovespa"] }
]

function fold(s) {
  var out = String(s || "").toLowerCase().replace(/^\s+|\s+$/g, "")
  var from = "áàâãäéèêëíìîïóòôõöúùûüç"
  var to = "aaaaaeeeeiiiiooooouuuuc"
  return out.replace(/[áàâãäéèêëíìîïóòôõöúùûüç]/g, function (c) { return to.charAt(from.indexOf(c)) })
}

// Search response -> [{ symbol, name }], B3 tickers, BRL currency pairs and
// the Ibovespa only. What the user typed, if it already looks like a ticker,
// comes first so a symbol Yahoo's search misses can still be added.
function parseSearch(text, query, exclude) {
  var skip = exclude || []
  var out = []
  var seen = {}
  function add(symbol, name) {
    if (symbol === "" || seen[symbol] || skip.indexOf(symbol) !== -1) return
    if (out.length >= MAX_SUGGESTIONS) return
    seen[symbol] = true
    out.push({ symbol: symbol, name: cleanName(name) })
  }

  var typed = normalizeSymbol(query)
  if (typed !== "") add(typed, "")

  var folded = fold(query)
  if (folded.length >= 2) {
    for (var a = 0; a < LOCAL_ALIASES.length; a++) {
      var al = LOCAL_ALIASES[a]
      for (var w = 0; w < al.words.length; w++) {
        if (al.words[w].indexOf(folded) === 0) { add(al.symbol, al.name); break }
      }
    }
  }

  var data = parseJson(text)
  var quotes = data && data.quotes
  if (quotes && typeof quotes.length === "number") {
    for (var i = 0; i < quotes.length && i < 50; i++) {
      var q = quotes[i]
      if (!q || typeof q.symbol !== "string") continue
      var ys = q.symbol.toUpperCase()
      var ok = (q.exchange === "SAO" && /^[A-Z]{4}[0-9]{1,2}\.SA$/.test(ys))
        || /^[A-Z]{6}=X$/.test(ys)
        || ys === "^BVSP"
      if (!ok) continue
      var name = q.longname || q.shortname || ""
      if (typed !== "" && normalizeSymbol(ys) === typed) {
        // Fill in the name of the typed suggestion instead of duplicating it.
        for (var k = 0; k < out.length; k++) if (out[k].symbol === typed) out[k].name = cleanName(name)
        continue
      }
      add(normalizeSymbol(ys), name)
    }
  }
  return out
}

// colors.toml -> { up, down } from the theme's ANSI green and red.
function trendColors(toml) {
  var text = String(toml || "")
  var green = text.match(/^\s*color2\s*=\s*["'](#[0-9a-fA-F]{6})["']/m)
  var red = text.match(/^\s*color1\s*=\s*["'](#[0-9a-fA-F]{6})["']/m)
  return { up: green ? green[1] : "", down: red ? red[1] : "" }
}

function clampInt(v, lo, hi, fallback) {
  var n = parseInt(v, 10)
  if (!isFinite(n)) return fallback
  return Math.max(lo, Math.min(hi, n))
}

if (typeof module !== "undefined") {
  module.exports = {
    MAX_SYMBOLS: MAX_SYMBOLS, DEFAULT_SYMBOLS: DEFAULT_SYMBOLS,
    normalizeSymbol: normalizeSymbol, yahooSymbol: yahooSymbol, symbolList: symbolList,
    quotesUrl: quotesUrl, searchUrl: searchUrl, curlArgs: curlArgs, cleanName: cleanName,
    parseQuotes: parseQuotes, parseSearch: parseSearch, trendOf: trendOf, arrow: arrow,
    trendColors: trendColors, clampInt: clampInt, decimalsFor: decimalsFor
  }
}

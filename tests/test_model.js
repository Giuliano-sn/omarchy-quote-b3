#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
  .split("\n").filter((l) => !l.trim().startsWith(".pragma")).join("\n");
const M = { console };
vm.createContext(M);
vm.runInContext(src, M, { filename: "Model.js" });

let n = 0;
function t(name, fn) { fn(); n++; }

t("normalizeSymbol", () => {
  assert.strictEqual(M.normalizeSymbol("petr4"), "PETR4");
  assert.strictEqual(M.normalizeSymbol(" PETR4.SA "), "PETR4");
  assert.strictEqual(M.normalizeSymbol("taee11"), "TAEE11");
  assert.strictEqual(M.normalizeSymbol("USDBRL=X"), "USDBRL");
  assert.strictEqual(M.normalizeSymbol("usd/brl"), "USDBRL");
  assert.strictEqual(M.normalizeSymbol("^BVSP"), "IBOV");
  assert.strictEqual(M.normalizeSymbol("ibovespa"), "IBOV");
  assert.strictEqual(M.normalizeSymbol("petrobras"), "");
  assert.strictEqual(M.normalizeSymbol("$(rm -rf ~)"), "");
  assert.strictEqual(M.normalizeSymbol(null), "");
});

t("yahooSymbol", () => {
  assert.strictEqual(M.yahooSymbol("PETR4"), "PETR4.SA");
  assert.strictEqual(M.yahooSymbol("EURBRL"), "EURBRL=X");
  assert.strictEqual(M.yahooSymbol("IBOV"), "^BVSP");
  assert.strictEqual(M.yahooSymbol("x"), "");
});

t("symbolList", () => {
  assert.deepStrictEqual(Array.from(M.symbolList(undefined)), ["USDBRL", "EURBRL"]);
  assert.deepStrictEqual(Array.from(M.symbolList([])), []);
  assert.deepStrictEqual(Array.from(M.symbolList(["petr4", "PETR4.SA", "bad!", "vale3", "itub4", "bbas3"])), ["PETR4", "VALE3", "ITUB4"]);
  assert.deepStrictEqual(Array.from(M.symbolList("usdbrl, petr4")), ["USDBRL", "PETR4"]);
});

t("urls", () => {
  assert.strictEqual(M.quotesUrl(["USDBRL", "PETR4"]),
    "https://query1.finance.yahoo.com/v7/finance/spark?symbols=USDBRL%3DX%2CPETR4.SA&range=1d&interval=1d");
  assert.strictEqual(M.quotesUrl([]), "");
  assert.strictEqual(M.searchUrl("a"), "");
  assert.ok(M.searchUrl("vale & co").indexOf("q=vale%20%26%20co&") > 0);
  const args = M.curlArgs("https://x");
  assert.strictEqual(args[0], "curl");
  assert.strictEqual(args[args.length - 1], "https://x");
});

const spark = JSON.stringify({ spark: { result: [
  { symbol: "USDBRL=X", response: [{ meta: { symbol: "USDBRL=X", regularMarketPrice: 5.9087, chartPreviousClose: 5.8488, regularMarketChangePercent: 1.02, longName: "USD/BRL", regularMarketTime: 1795103271 } }] },
  { symbol: "PETR4.SA", response: [{ meta: { symbol: "PETR4.SA", regularMarketPrice: 43.08, chartPreviousClose: 43.17, longName: "<img src=x>Petrobras" } }] },
  { symbol: "VALE3.SA", response: [{ meta: { symbol: "VALE3.SA", regularMarketPrice: 60, chartPreviousClose: 60 } }] },
  { symbol: "BAD.SA", response: [{ meta: { symbol: "BAD.SA", regularMarketPrice: 1 } }] },
  { symbol: "ITUB4.SA", response: [{ meta: { symbol: "ITUB4.SA", regularMarketPrice: "NaN" } }] },
] } });

t("parseQuotes", () => {
  const q = M.parseQuotes(spark);
  assert.deepStrictEqual(Object.keys(q).sort(), ["PETR4", "USDBRL", "VALE3"]);
  assert.strictEqual(q.USDBRL.trend, 1);
  assert.strictEqual(q.USDBRL.decimals, 4);
  assert.strictEqual(q.USDBRL.marketTime, 1795103271000);
  assert.strictEqual(q.PETR4.trend, -1);
  assert.ok(Math.abs(q.PETR4.changePercent - (-0.2085)) < 0.001);
  assert.strictEqual(q.PETR4.name.indexOf("<"), -1);
  assert.strictEqual(q.VALE3.trend, 0);
  assert.strictEqual(Object.keys(M.parseQuotes("not json")).length, 0);
  assert.strictEqual(Object.keys(M.parseQuotes("x".repeat(600000))).length, 0);
});

t("parseSearch", () => {
  const body = JSON.stringify({ quotes: [
    { symbol: "PBR", exchange: "NYQ", longname: "Petrobras ADR" },
    { symbol: "PETR4.SA", exchange: "SAO", longname: "Petróleo Brasileiro S.A. - Petrobras" },
    { symbol: "PETR3.SA", exchange: "SAO", shortname: "PETROBRAS ON" },
    { symbol: "0P0001T8T6.SA", exchange: "SAO" },
    { symbol: "USDBRL=X", exchange: "CCY", shortname: "USD/BRL" },
  ] });
  const r = M.parseSearch(body, "petro", []);
  assert.deepStrictEqual(Array.from(r, (x) => x.symbol), ["PETR4", "PETR3", "USDBRL"]);
  const typed = M.parseSearch(body, "petr4", ["PETR3"]);
  assert.deepStrictEqual(Array.from(typed, (x) => x.symbol), ["PETR4", "USDBRL"]);
  assert.strictEqual(typed[0].name, "Petróleo Brasileiro S.A. - Petrobras");
  assert.deepStrictEqual(Array.from(M.parseSearch("", "bbas3", []), (x) => x.symbol), ["BBAS3"]);
});

t("aliases and fractional", () => {
  assert.deepStrictEqual(Array.from(M.parseSearch("", "Dólar", []), (x) => x.symbol), ["USDBRL"]);
  assert.deepStrictEqual(Array.from(M.parseSearch("", "eur", ["EURBRL"]), (x) => x.symbol), []);
  assert.deepStrictEqual(Array.from(M.parseSearch("", "ibov", []), (x) => x.symbol), ["IBOV"]);
  const frac = JSON.stringify({ quotes: [{ symbol: "BBAS3F.SA", exchange: "SAO" }, { symbol: "BBAS3.SA", exchange: "SAO" }] });
  assert.deepStrictEqual(Array.from(M.parseSearch(frac, "banco", []), (x) => x.symbol), ["BBAS3"]);
});

t("trendColors / arrow / clamp", () => {
  const c = M.trendColors('color1 = "#c83730"\ncolor2 = "#66cc33"\ncolor10 = "#ffffff"');
  assert.strictEqual(c.up, "#66cc33");
  assert.strictEqual(c.down, "#c83730");
  assert.strictEqual(M.trendColors('color2 = "red"').up, "");
  assert.strictEqual(M.arrow(1), "▲");
  assert.strictEqual(M.arrow(-1), "▼");
  assert.strictEqual(M.clampInt("99", 1, 60, 5), 60);
  assert.strictEqual(M.clampInt("x", 1, 60, 5), 5);
});

console.log(`ok - ${n} test groups passed`);

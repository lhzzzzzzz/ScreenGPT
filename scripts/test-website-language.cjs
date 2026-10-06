const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "../website/language.js"), "utf8");
const storageKey = "screengpt.website.language";

function makeStorage(initial = {}, { blockedRead = false, blockedWrite = false, blockedRemove = false } = {}) {
  const values = new Map(Object.entries(initial));
  return {
    values,
    getItem(key) {
      if (blockedRead) throw new Error("storage read blocked");
      return values.has(key) ? values.get(key) : null;
    },
    setItem(key, value) {
      if (blockedWrite) throw new Error("storage write blocked");
      values.set(key, String(value));
    },
    removeItem(key) {
      if (blockedRemove) throw new Error("storage remove blocked");
      values.delete(key);
    },
  };
}

function runScript({
  entry = false,
  browserLanguages = ["en"],
  browserLanguage,
  saved,
  sessionSaved,
  localOptions,
  sessionOptions,
  page = "https://example.test/ScreenGPT/index.html?from=home#features",
  scriptUrl = "https://example.test/ScreenGPT/language.js",
  links = [],
} = {}) {
  const localStorage = makeStorage(saved, localOptions);
  const sessionStorage = makeStorage(sessionSaved, sessionOptions);
  const location = new URL(page);
  const replacements = [];
  const windowListeners = new Map();
  const documentListeners = new Map();
  const mockLinks = links.map(({ language, href }) => {
    const linkListeners = new Map();
    return {
      dataset: { language },
      href,
      addEventListener(type, listener) {
        linkListeners.set(type, listener);
      },
      click() {
        linkListeners.get("click")?.();
      },
    };
  });
  const window = {
    localStorage,
    sessionStorage,
    location: {
      get search() { return location.search; },
      get hash() { return location.hash; },
      replace(url) { replacements.push(url); },
    },
    addEventListener(type, listener) { windowListeners.set(type, listener); },
  };
  const document = {
    currentScript: {
      src: scriptUrl,
      hasAttribute(name) { return entry && name === "data-auto-language"; },
    },
    addEventListener(type, listener) { documentListeners.set(type, listener); },
    querySelectorAll(selector) {
      assert.equal(selector, "a[data-language]");
      return mockLinks;
    },
  };
  const context = {
    URL,
    document,
    navigator: { languages: browserLanguages, language: browserLanguage },
    window,
  };

  vm.runInNewContext(source, context, { filename: "website/language.js" });
  return {
    localStorage,
    sessionStorage,
    replacements,
    links: mockLinks,
    setHash(hash) { location.hash = hash; },
    fireDOMContentLoaded() { documentListeners.get("DOMContentLoaded")?.(); },
    fireHashchange() { windowListeners.get("hashchange")?.(); },
  };
}

test("entry page chooses a saved language or the first browser language", async (t) => {
  const cases = [
    [["zh-CN"], "zh"],
    [["zh-TW"], "zh"],
    [["zh-Hant"], "zh"],
    [["en", "zh-CN"], "en"],
    [["fr-FR", "zh-CN"], "en"],
    [["de"], "en"],
  ];
  for (const [languages, expected] of cases) {
    await t.test(`${languages.join(", ")} -> ${expected}`, () => {
      const page = "https://example.test/ScreenGPT/?campaign=spring#pricing";
      const run = runScript({ entry: true, browserLanguages: languages, page });
      assert.deepEqual(run.replacements, [`https://example.test/ScreenGPT/${expected}/?campaign=spring#pricing`]);
    });
  }

  for (const savedLanguage of ["zh", "en"]) {
    await t.test(`saved ${savedLanguage} overrides browser preference`, () => {
      const run = runScript({
        entry: true,
        browserLanguages: [savedLanguage === "zh" ? "en" : "zh-CN"],
        saved: { [storageKey]: savedLanguage },
      });
      assert.match(run.replacements[0], new RegExp(`/ScreenGPT/${savedLanguage}/(?:[?#]|$)`));
      assert.equal(run.replacements.length, 1);
    });
  }

  await t.test("malformed saved value is ignored", () => {
    const run = runScript({ entry: true, browserLanguages: ["zh-CN"], saved: { [storageKey]: "fr" } });
    assert.match(run.replacements[0], /\/ScreenGPT\/zh\/(?:[?#]|$)/);
  });

  await t.test("storage read failures fall through to browser preference", () => {
    const run = runScript({
      entry: true,
      browserLanguages: ["zh-TW"],
      localOptions: { blockedRead: true },
      sessionOptions: { blockedRead: true },
    });
    assert.match(run.replacements[0], /\/ScreenGPT\/zh\/(?:[?#]|$)/);
    assert.equal(run.replacements.length, 1);
  });

  await t.test("navigator.language is used when languages is empty", () => {
    const run = runScript({ entry: true, browserLanguages: [], browserLanguage: "zh_Hant" });
    assert.match(run.replacements[0], /\/ScreenGPT\/zh\/(?:[?#]|$)/);
  });
});

test("explicit translation pages do not auto-redirect", () => {
  for (const language of ["zh", "en"]) {
    const run = runScript({ page: `https://example.test/ScreenGPT/${language}/?x=1#section` });
    assert.deepEqual(run.replacements, []);
  }
});

test("manual language links preserve the current query and fragment", () => {
  const run = runScript({
    links: [
      { language: "zh", href: "https://example.test/ScreenGPT/zh/?old=1#old" },
      { language: "en", href: "https://example.test/ScreenGPT/en/" },
    ],
  });
  run.fireDOMContentLoaded();
  assert.deepEqual(run.links.map((link) => link.href), [
    "https://example.test/ScreenGPT/zh/?from=home#features",
    "https://example.test/ScreenGPT/en/?from=home#features",
  ]);

  run.setHash("#contact");
  run.fireHashchange();
  run.links[1].click();
  assert.deepEqual(run.links.map((link) => link.href), [
    "https://example.test/ScreenGPT/zh/?from=home#contact",
    "https://example.test/ScreenGPT/en/?from=home#contact",
  ]);
});

test("manual switches remember the choice and storage failures stay graceful", () => {
  const run = runScript({
    links: [{ language: "zh", href: "https://example.test/ScreenGPT/zh/" }],
  });
  run.fireDOMContentLoaded();
  run.links[0].click();
  assert.equal(run.localStorage.values.get(storageKey), "zh");
  assert.equal(run.sessionStorage.values.has(storageKey), false);

  const sessionFallback = runScript({
    entry: true,
    browserLanguages: ["en"],
    sessionSaved: { [storageKey]: "zh" },
    localOptions: { blockedRead: true, blockedWrite: true },
  });
  assert.equal(new URL(sessionFallback.replacements[0]).pathname, "/ScreenGPT/zh/");
  // Run a manual page separately to exercise the write fallback.
  const manualFallback = runScript({
    localOptions: { blockedWrite: true },
    links: [{ language: "en", href: "https://example.test/ScreenGPT/en/" }],
  });
  manualFallback.fireDOMContentLoaded();
  manualFallback.links[0].click();
  assert.equal(manualFallback.sessionStorage.values.get(storageKey), "en");

  const allBlocked = runScript({
    localOptions: { blockedRead: true, blockedWrite: true },
    sessionOptions: { blockedRead: true, blockedWrite: true },
    links: [{ language: "zh", href: "https://example.test/ScreenGPT/zh/" }],
  });
  allBlocked.fireDOMContentLoaded();
  assert.doesNotThrow(() => allBlocked.links[0].click());
});

test("session preference beats stale local value and clears after a successful save", () => {
  const entry = runScript({
    entry: true,
    browserLanguages: ["zh-CN"],
    saved: { [storageKey]: "zh" },
    sessionSaved: { [storageKey]: "en" },
  });
  assert.equal(new URL(entry.replacements[0]).pathname, "/ScreenGPT/en/");

  const manual = runScript({
    saved: { [storageKey]: "zh" },
    sessionSaved: { [storageKey]: "en" },
    links: [{ language: "en", href: "https://example.test/ScreenGPT/en/" }],
  });
  manual.fireDOMContentLoaded();
  manual.links[0].click();
  assert.equal(manual.localStorage.values.get(storageKey), "en");
  assert.equal(manual.sessionStorage.values.has(storageKey), false);
});

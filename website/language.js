/* Only the shared entry page chooses a language automatically.
   Explicit /zh/ and /en/ links always open the requested translation. */
(() => {
  const script = document.currentScript;
  const storageKey = "screengpt.website.language";
  const isLanguage = (value) => value === "zh" || value === "en";

  function savedLanguage() {
    for (const storage of ["sessionStorage", "localStorage"]) {
      try {
        const value = window[storage].getItem(storageKey);
        if (isLanguage(value)) return value;
      } catch {
        // Private browsing and browser policies may block storage.
      }
    }
    return null;
  }

  function rememberLanguage(language) {
    try {
      window.localStorage.setItem(storageKey, language);
      try {
        window.sessionStorage.removeItem(storageKey);
      } catch {
        // Permanent storage succeeded; no session fallback is needed.
      }
      return;
    } catch {
      // A full or blocked local store may still contain an old preference.
    }
    try {
      window.sessionStorage.setItem(storageKey, language);
    } catch {
      // The language links still work even when saving is unavailable.
    }
  }

  if (script?.hasAttribute("data-auto-language")) {
    const preferred = navigator.languages?.[0] || navigator.language || "en";
    const language = savedLanguage() || (/^zh(?:[-_]|$)/i.test(preferred) ? "zh" : "en");
    const destination = new URL(`${language}/`, script.src);
    destination.search = window.location.search;
    destination.hash = window.location.hash;
    window.location.replace(destination.href);
    return;
  }

  document.addEventListener("DOMContentLoaded", () => {
    const links = document.querySelectorAll("a[data-language]");
    function keepSection() {
      for (const link of links) {
        const destination = new URL(link.href);
        destination.search = window.location.search;
        destination.hash = window.location.hash;
        link.href = destination.href;
      }
    }
    keepSection();
    window.addEventListener("hashchange", keepSection);
    for (const link of links) {
      link.addEventListener("click", () => {
        if (isLanguage(link.dataset.language)) rememberLanguage(link.dataset.language);
      });
    }
  });
})();

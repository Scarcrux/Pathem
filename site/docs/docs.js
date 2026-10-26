/* Local-only progressive search. Reading and navigation never depend on JavaScript. */
(function () {
  "use strict";
  function normalize(text) {
    return text.normalize("NFKD").replace(/\p{M}/gu, "").toLocaleLowerCase();
  }
  function searchGuides(guides, query) {
    const terms = normalize(query.trim()).split(/\s+/).filter(Boolean);
    if (!terms.length) return [];
    return guides.map(function (guide) {
      const text = normalize(guide.text);
      const title = normalize(guide.title);
      const description = normalize(guide.description);
      const score = terms.every(function (term) { return text.includes(term); })
        ? terms.reduce(function (sum, term) { return sum + (title.includes(term) ? 8 : 0) + (description.includes(term) ? 3 : 0) + 1; }, 0) : 0;
      return {guide: guide, score: score};
    }).filter(function (result) { return result.score > 0; })
      .sort(function (a, b) { return b.score - a.score || a.guide.title.localeCompare(b.guide.title); })
      .map(function (result) { return result.guide; });
  }
  if (typeof module !== "undefined" && module.exports) module.exports = {normalize: normalize, searchGuides: searchGuides};
  if (typeof document === "undefined") return;
  const input = document.getElementById("guide-query");
  if (!input) return;
  document.addEventListener("keydown", function (event) {
    const target = event.target;
    if (event.key === "/" && !event.metaKey && !event.ctrlKey && !event.altKey
        && !/^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName) && !target.isContentEditable) {
      event.preventDefault(); input.focus();
    }
  });
  const directory = document.getElementById("guide-directory");
  if (!directory) return; // Article form navigates to the searchable index normally.
  const results = document.getElementById("search-results");
  const status = document.getElementById("search-status");
  const query = new URLSearchParams(location.search).get("q");
  if (query) input.value = query;
  let guides = null;
  function render() {
    if (!guides) return;
    const query = input.value.trim();
    const matches = searchGuides(guides, query);
    results.replaceChildren();
    directory.hidden = Boolean(query);
    results.hidden = !query;
    status.textContent = query ? matches.length + (matches.length === 1 ? " guide found." : " guides found.")
      : guides.length + " guides. Search by task, feature, or setting. Press / to focus search.";
    matches.forEach(function (guide) {
      const link = document.createElement("a");
      link.className = "guide-card"; link.href = guide.url;
      const heading = document.createElement("h2"); heading.textContent = guide.title;
      const text = document.createElement("p"); text.textContent = guide.description;
      const category = document.createElement("span"); category.textContent = guide.category;
      link.append(heading, text, category); results.append(link);
    });
    if (query && !matches.length) {
      const message = document.createElement("p");
      message.textContent = "No matches. Try fewer words, or clear the search to browse all topics.";
      results.append(message);
      const clear = document.createElement("button"); clear.type = "button";
      clear.textContent = "Browse all guides";
      clear.addEventListener("click", function () { input.value = ""; render(); input.focus(); });
      results.append(clear);
    }
    const url = new URL(location.href);
    if (query) url.searchParams.set("q", query); else url.searchParams.delete("q");
    history.replaceState(null, "", url);
  }
  input.form.addEventListener("submit", function (event) { if (guides) { event.preventDefault(); render(); } });
  input.addEventListener("input", render);
  input.addEventListener("keydown", function (event) {
    if (event.key === "Escape") { input.value = ""; render(); }
  });
  fetch("/docs/search-index.json").then(function (response) {
    if (!response.ok) throw new Error("Search index unavailable");
    return response.json();
  }).then(function (data) { guides = data; render(); }).catch(function () {
    status.textContent = "Search is unavailable. Browse the guide links below instead.";
    directory.hidden = false; results.hidden = true;
  });
})();

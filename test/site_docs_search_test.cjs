const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {searchGuides, normalize} = require("../site/docs/docs.js");
const index = JSON.parse(fs.readFileSync(path.join(__dirname, "../site/docs/search-index.json"), "utf8"));

test("finds relative dates from task wording", () => {
  assert.equal(searchGuides(index, "relative dates")[0].url, "/docs/views-dates/");
  assert.ok(searchGuides(index, "Yesterday").some(guide => guide.url === "/docs/views-dates/"));
});
test("finds Android limitation, clipboard and connection guides", () => {
  for (const [query, url] of [["Android", "/docs/cloud-devices/"], ["clipboard", "/docs/copy-move/"], ["SFTP", "/docs/connections/"], ["pathem reveal", "/docs/cli/"]]) {
    assert.ok(searchGuides(index, query).some(guide => guide.url === url), query);
  }
});
test("all query terms must match, with empty and nonmatching controls", () => {
  assert.deepEqual(searchGuides(index, "   "), []);
  assert.deepEqual(searchGuides(index, "qzxv-not-a-guide"), []);
  assert.deepEqual(searchGuides(index, "Android qzxv-not-a-guide"), []);
});
test("normalizes accents and case and ranks title over body", () => {
  assert.equal(normalize("RÉSUMÉ"), "resume");
  const guides = [{title: "Other", description: "", text: "relative dates", url: "/other"}, {title: "Relative dates", description: "", text: "relative dates", url: "/dates"}];
  assert.equal(searchGuides(guides, "RELATIVE DATES")[0].url, "/dates");
});

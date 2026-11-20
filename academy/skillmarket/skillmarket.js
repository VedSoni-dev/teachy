// Skills Library page: reads index.json (built by scripts/build-skillmarket.mjs) and shows
// the skills as a list with a detail pane, the same layout as the library in the app.
(function () {
  const rows = document.getElementById("rows");
  const detail = document.getElementById("detail");
  const empty = document.getElementById("empty");
  const search = document.getElementById("search");
  const chips = document.getElementById("chips");
  const preview = document.getElementById("preview");
  const previewTitle = document.getElementById("preview-title");
  const previewBody = document.getElementById("preview-body");
  // The download counter (skillmarket-worker/ in the repo).
  const COUNTS_URL = "https://teachy-skillmarket.vedantn06soni.workers.dev";
  let skills = [];
  let category = "All";
  let selectedID = null;
  // Downloads per skill id; null until the counter answers, so a failure just hides counts.
  let counts = null;

  const countLabel = (skill) => {
    if (!counts) return null;
    const count = counts[skill.id] || 0;
    if (count === 0) return "No downloads yet";
    return count === 1 ? "1 download" : `${count.toLocaleString("en-US")} downloads`;
  };

  // Downloading the file counts; "Add to Teachy" doesn't, because the app counts the add itself.
  function reportDownload(skill) {
    const body = new Blob([JSON.stringify({ id: skill.id, source: "download" })], { type: "text/plain" });
    if (!navigator.sendBeacon?.(`${COUNTS_URL}/count`, body)) {
      fetch(`${COUNTS_URL}/count`, { method: "POST", body, keepalive: true }).catch(() => {});
    }
    if (counts) {
      counts[skill.id] = (counts[skill.id] || 0) + 1;
      render();
    }
  }

  const element = (tag, attributes = {}, text) => {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, value);
    if (text !== undefined) node.textContent = text;
    return node;
  };

  const plusIcon = '<svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="7" fill="currentColor"/><path d="M8 4.8v6.4M4.8 8h6.4" stroke="#fff" stroke-width="1.6" stroke-linecap="round"/></svg>';

  // The absolute file URL, which is what the teachy://skill link carries to the app.
  const fileURL = (skill) => new URL(skill.file, new URL("index.json", location.href)).href;

  const isNew = (skill) => {
    if (!skill.added) return false;
    const age = Date.now() - Date.parse(skill.added + "T00:00:00Z");
    return age >= 0 && age < 30 * 24 * 60 * 60 * 1000;
  };

  function visibleSkills() {
    const query = search.value.trim().toLowerCase();
    return skills.filter((skill) => {
      if (category !== "All" && skill.category !== category) return false;
      if (!query) return true;
      return [skill.name, skill.summary, skill.headline || "", skill.author, skill.category || "", ...(skill.goodFor || skill.apps || [])]
        .join(" ").toLowerCase().includes(query);
    });
  }

  function render() {
    const shown = visibleSkills();
    if (!shown.some((skill) => skill.id === selectedID)) selectedID = shown[0]?.id ?? null;
    rows.replaceChildren(...shown.map(row));
    empty.hidden = shown.length > 0;
    empty.textContent = search.value.trim() ? `No skills match “${search.value.trim()}”.` : "No skills in this category yet.";
    renderDetail(shown.find((skill) => skill.id === selectedID));
  }

  function tile(skill, large) {
    return element("span", { class: large ? "tile tile-large" : "tile", "aria-hidden": "true" }, skill.icon || skill.name.slice(0, 1).toUpperCase());
  }

  function row(skill) {
    const button = element("button", { type: "button", class: "row", role: "option", "aria-selected": String(skill.id === selectedID) });
    button.append(tile(skill, false));
    const text = element("span");
    text.append(element("span", { class: "row-name" }, skill.name));
    const downloads = counts && counts[skill.id] ? ` · ${countLabel(skill)}` : "";
    text.append(element("span", { class: "row-by" }, `by ${skill.author}${downloads}`));
    button.append(text);
    button.addEventListener("click", () => {
      selectedID = skill.id;
      render();
      // On a phone the detail sits under the list: bring it into view.
      if (window.matchMedia("(max-width: 880px)").matches) detail.scrollIntoView({ behavior: "smooth", block: "start" });
    });
    return button;
  }

  function renderDetail(skill) {
    if (!skill) { detail.replaceChildren(); return; }
    const main = element("div", { class: "detail-main" });
    const top = element("div", { class: "detail-top" });
    const left = element("div");
    const title = element("h3", { class: "detail-title" }, `${skill.name}.md`);
    if (isNew(skill)) {
      const badge = element("span", { class: "badge-new" }, "✦ New");
      title.append(badge);
    }
    left.append(title);
    const tags = skill.goodFor || skill.apps || [];
    if (tags.length) {
      left.append(element("div", { class: "label" }, "GOOD FOR"));
      const tagList = element("div", { class: "tags" });
      for (const tag of tags) tagList.append(element("span", {}, tag));
      left.append(tagList);
    }
    top.append(left, tile(skill, true));
    main.append(top);
    main.append(element("h4", { class: "detail-headline" }, skill.headline || skill.summary));
    if (skill.description) main.append(element("p", { class: "detail-description" }, skill.description));
    if (skill.highlights?.length) {
      const inside = element("div", { class: "inside" });
      inside.append(element("div", { class: "label" }, "INSIDE THIS SKILL"));
      const list = element("ul");
      for (const highlight of skill.highlights) list.append(element("li", {}, highlight));
      inside.append(list);
      main.append(inside);
    }

    const foot = element("div", { class: "detail-foot" });
    const footRow = element("div", { class: "foot-row" });
    const downloads = countLabel(skill);
    const version = element("span", { class: "foot-version" });
    if (downloads) {
      version.innerHTML = '<svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="7" fill="currentColor" opacity=".35"/><path d="M8 4.5v6M5.3 8.2 8 10.9l2.7-2.7" fill="none" stroke="#fff" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>';
      version.append(element("strong", {}, downloads));
      version.append(document.createTextNode(` · v${skill.version}`));
    } else {
      version.textContent = `Version ${skill.version}${skill.category ? " · " + skill.category : ""}`;
    }
    footRow.append(version);
    const creator = element("span", { class: "creator" }, "Created by ");
    const pill = skill.authorURL
      ? element("a", { href: skill.authorURL, target: "_blank", rel: "noopener" })
      : element("span", { class: "creator-pill" });
    pill.append(element("span", { class: "avatar", "aria-hidden": "true" }, skill.author.slice(0, 1).toUpperCase()));
    pill.append(document.createTextNode(skill.author));
    creator.append(pill);
    footRow.append(creator);
    foot.append(footRow);

    const add = element("a", { class: "add", href: `teachy://skill?url=${encodeURIComponent(fileURL(skill))}` });
    add.innerHTML = plusIcon;
    add.append(document.createTextNode("Add to Teachy"));
    foot.append(add);

    const links = element("div", { class: "foot-links" });
    const view = element("button", { type: "button" }, "View file");
    view.addEventListener("click", () => showPreview(skill));
    links.append(view);
    const download = element("a", { href: skill.file, download: `${skill.id}.md` }, "Download");
    download.addEventListener("click", () => reportDownload(skill));
    links.append(download);
    foot.append(links);

    detail.replaceChildren(main, foot);
  }

  async function showPreview(skill) {
    previewTitle.textContent = `${skill.name}.md`;
    previewBody.textContent = "Loading…";
    preview.showModal();
    try {
      const response = await fetch(skill.file);
      previewBody.textContent = response.ok ? await response.text() : "Couldn't load this skill.";
    } catch {
      previewBody.textContent = "Couldn't load this skill.";
    }
  }

  function renderChips() {
    const categories = ["All", ...new Set(skills.map((skill) => skill.category).filter(Boolean).sort())];
    chips.replaceChildren(...categories.map((name) => {
      const chip = element("button", { type: "button", class: "chip", "aria-pressed": String(name === category) }, name === "All" ? "✦ All" : name);
      chip.addEventListener("click", () => {
        category = name;
        for (const other of chips.children) other.setAttribute("aria-pressed", String(other === chip));
        render();
      });
      return chip;
    }));
  }

  document.getElementById("preview-close").addEventListener("click", () => preview.close());
  preview.addEventListener("click", (event) => { if (event.target === preview) preview.close(); });
  search.addEventListener("input", render);

  fetch("index.json", { cache: "no-cache" })
    .then((response) => (response.ok ? response.json() : Promise.reject()))
    .then((index) => {
      skills = index.skills || [];
      // A link like /skillmarket/#zoom opens on that skill.
      const wanted = decodeURIComponent(location.hash.slice(1));
      if (skills.some((skill) => skill.id === wanted)) selectedID = wanted;
      renderChips();
      render();
      fetch(`${COUNTS_URL}/counts`)
        .then((response) => (response.ok ? response.json() : Promise.reject()))
        .then((answer) => { counts = answer.counts || {}; render(); })
        .catch(() => {});
    })
    .catch(() => {
      empty.hidden = false;
      empty.textContent = "The skill list couldn't be loaded. Try again in a moment.";
    });
})();

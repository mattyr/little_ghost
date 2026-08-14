const pickers = [...document.querySelectorAll("[data-docs-version-picker]")];

const destinationFor = (manifestUrl, version, page) => {
  const siteRoot = new URL("./", manifestUrl);
  const versionRoot = new URL(version.base_path ? `${version.base_path}/` : "./", siteRoot);
  const targetPage = version.pages.includes(page)
    ? page
    : page.startsWith("docs/")
      ? "docs/index.html"
      : "index.html";

  return new URL(targetPage, versionRoot);
};

const showVersionNotice = (picker, catalog, versionsById) => {
  const notice = document.querySelector("[data-docs-version-notice]");
  if (!notice) return;

  const current = picker.dataset.currentVersion;
  if (current === "edge" || !catalog.latest_release || current === catalog.latest_release) return;

  const latest = versionsById.get(catalog.latest_release);
  if (!latest) return;

  notice.append("You’re reading v", current, ". ");
  const link = document.createElement("a");
  link.href = destinationFor(new URL(picker.dataset.versionsUrl, window.location.href), latest, picker.dataset.currentPage);
  link.textContent = `Open v${catalog.latest_release}`;
  notice.append(link, ".");
  notice.hidden = false;
};

const initializePicker = async (picker) => {
  const manifestUrl = new URL(picker.dataset.versionsUrl, window.location.href);
  const response = await fetch(manifestUrl, { credentials: "same-origin" });
  if (!response.ok) throw new Error(`Version catalog returned ${response.status}`);

  const catalog = await response.json();
  const versionsById = new Map(catalog.versions.map((version) => [version.id, version]));
  if (!versionsById.has(picker.dataset.currentVersion)) return;

  picker.replaceChildren();
  catalog.versions.forEach((version) => {
    const option = document.createElement("option");
    option.value = version.id;
    option.textContent = version.label;
    option.selected = version.id === picker.dataset.currentVersion;
    picker.append(option);
  });

  picker.addEventListener("change", () => {
    const version = versionsById.get(picker.value);
    if (!version) return;

    window.location.assign(destinationFor(manifestUrl, version, picker.dataset.currentPage));
  });
  showVersionNotice(picker, catalog, versionsById);
};

pickers.forEach((picker) => {
  initializePicker(picker).catch(() => {
    // The current page remains fully usable when the optional catalog is unavailable.
  });
});

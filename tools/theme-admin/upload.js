const form = document.querySelector("#submission-upload");
const file = document.querySelector("#submission-file");
const status = document.querySelector("#upload-status");

form.addEventListener("submit", async event => {
  event.preventDefault();
  if (!file.files.length) return;
  const button = form.querySelector("button");
  button.disabled = true;
  status.textContent = "Validating submission…";
  try {
    const response = await fetch("/submit", {
      method: "POST",
      headers: {"Content-Type": "application/json", "X-CSRF-Token": form.dataset.csrf},
      body: file.files[0],
    });
    status.textContent = await response.text();
    if (response.ok) window.location.assign("/?view=pending");
  } catch {
    status.textContent = "The dashboard could not be reached.";
  } finally {
    button.disabled = false;
  }
});

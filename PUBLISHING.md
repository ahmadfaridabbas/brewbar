# Publish the repository and website

This repository contains the app source, interface renders, website, and a ready-to-download app ZIP.

Repository: https://github.com/ahmadfaridabbas/brewbar

Website: https://ahmadfaridabbas.github.io/brewbar/

## 1. Upload to GitHub

1. Create a new repository on GitHub. `brewbar` is a suggested name; any name works.
2. Upload the **contents** of this folder into the repository root, including `src/` and `docs/`.
3. Commit the files to your default branch, usually `main`.

The `src/build/` output is a local build artifact and does not need to be uploaded. The installable version is already included at `docs/downloads/BrewBar-1.14.zip`, which preserves the macOS bundle and executable permissions. Include `docs/.nojekyll` so GitHub Pages serves the files as-is.

## 2. Enable GitHub Pages

1. Open the repository's **Settings → Pages**.
2. Under **Build and deployment**, choose **Deploy from a branch**.
3. Select the `main` branch and choose **/docs** as the folder.
4. Click **Save** and wait for the Pages deployment to finish.
5. GitHub displays the published URL on that settings page. Open it to verify the gallery and download button.

The typical address is `https://YOUR-USERNAME.github.io/YOUR-REPOSITORY/`. The page and download links work without editing the HTML.

Official instructions: https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site

## 3. Optional GitHub Release

Create a release tagged `v1.14` and attach `docs/downloads/BrewBar-1.14.zip`. The website's download button already points at its bundled ZIP, so a Release is optional.

## Updating

Edit the source in `src/`, run `./build.sh`, and regenerate the interface renders with `swift Design/RenderSite.swift ../../brewbar-site/docs/assets` (or your `docs/assets` path) if the appearance changes. For a version change, update `src/Info.plist`, the ZIP name/link in `docs/index.html` and `README.md`, and the visible version text. GitHub Pages republishes changes to `docs/` automatically once configured.

BrewBar is not affiliated with Homebrew. Third-party status is documented in `THIRD_PARTY_NOTICES.md`.

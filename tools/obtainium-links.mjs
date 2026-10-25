// Prints Obtainium import links (https redirect form) for the apps the README offers.
//   node tools/obtainium-links.mjs [--json | --markdown]
const common = {
  includePrereleases: false,
  includeDrafts: false,
  fallbackToOlderReleases: true,
  filterReleaseTitlesByRegEx: "",
  invertReleaseTitlesFilter: false,
  filterReleaseNotesByRegEx: "",
  invertReleaseNotesFilter: false,
  verifyLatestTag: false,
  sortMethodChoice: "date",
  useLatestAssetDateAsReleaseDate: false,
  releaseTitleAsVersion: false,
  trackOnly: false,
  versionExtractionRegEx: "",
  matchGroupToUse: "",
  // Release tags do not match the apps' own version names.
  versionDetection: false,
  useVersionCodeAsOSVersion: false,
  apkFilterRegEx: "",
  invertAPKFilter: false,
  autoApkFilterByArch: true,
  shizukuPretendToBeGooglePlay: false,
  allowInsecure: false,
  exemptFromBackgroundUpdates: false,
  skipUpdateNotifications: false,
  refreshBeforeDownload: false,
};

const apps = [
  {
    id: "com.t3tools.t3code",
    url: "https://github.com/pingdotgg/t3code",
    author: "pingdotgg",
    name: "T3 Code (nightly)",
    settings: {
      // Every nightly release carries the newest Android build from Google Play's internal track.
      includePrereleases: true,
      filterReleaseTitlesByRegEx: "^T3 Code Nightly",
      apkFilterRegEx: "^t3code-android-internal-.*\\.apk$",
      about: "Nightly Android build of T3 Code from github.com/pingdotgg/t3code releases.",
    },
  },
  { id: "com.termux", url: "https://github.com/termux/termux-app", author: "termux", name: "Termux",
    settings: { apkFilterRegEx: "_(arm64-v8a|x86_64)\\.apk$" } },
  { id: "com.termux.boot", url: "https://github.com/termux/termux-boot", author: "termux", name: "Termux:Boot", settings: {} },
  { id: "com.termux.api", url: "https://github.com/termux/termux-api", author: "termux", name: "Termux:API", settings: {} },
  { id: "com.termux.widget", url: "https://github.com/termux/termux-widget", author: "termux", name: "Termux:Widget", settings: {} },
];

const entries = apps.map(({ settings, ...app }) => ({
  ...app,
  additionalSettings: JSON.stringify({ ...common, appName: app.name, appAuthor: app.author, ...settings }),
}));

const link = (entry) =>
  `https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/${encodeURIComponent(JSON.stringify(entry))}`;

if (process.argv.includes("--json")) {
  console.log(JSON.stringify({ apps: entries }, null, 2));
} else if (process.argv.includes("--markdown")) {
  // Reference-style definitions for README.md, keyed by package id.
  for (const entry of entries) console.log(`[${entry.id}]: ${link(entry)}`);
} else {
  for (const entry of entries) console.log(`${entry.name}\n${link(entry)}\n`);
}

// Writes the map style layers (day and night) used by the app.
// Run by .github/workflows/maps.yml after `npm install @protomaps/basemaps@5`.
import { writeFileSync } from "node:fs";
import { layers, namedFlavor } from "@protomaps/basemaps";

const out = process.argv[2] ?? ".";
for (const flavor of ["light", "dark"]) {
  const l = layers("protomaps", namedFlavor(flavor), { lang: "en" });
  writeFileSync(`${out}/layers-${flavor}.json`, JSON.stringify(l));
  console.log(`layers-${flavor}.json: ${l.length} layers`);
}

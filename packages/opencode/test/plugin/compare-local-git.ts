import {
  resolvePathPluginTarget,
  createPluginEntry,
  isPathPluginSpec,
  pluginSource,
} from "../../src/plugin/shared"

const SPECS = ["/tmp/superpowers", "superpowers@git+https://github.com/obra/superpowers.git"]

console.log("=" .repeat(70))
console.log("Plugin resolution comparison: local file path vs git URL")
console.log("=" .repeat(70))

for (const spec of SPECS) {
  const isFile = isPathPluginSpec(spec)
  const source = pluginSource(spec)
  console.log(`\n>>> spec: "${spec}"`)
  console.log(`    isPathPluginSpec: ${isFile}`)
  console.log(`    pluginSource:    ${source}`)

  if (isFile) {
    const target = await resolvePathPluginTarget(spec)
    console.log(`    resolvePathPluginTarget: ${target}`)

    for (const kind of ["server", "tui"] as const) {
      const entry = await createPluginEntry(spec, target, kind)
      console.log(`    createPluginEntry(kind="${kind}"):`)
      console.log(`      source  = ${entry.source}`)
      console.log(`      target  = ${entry.target}`)
      console.log(`      entry   = ${entry.entry ?? "UNDEFINED"}`)
      console.log(`      pkg     = ${entry.pkg?.json.name ?? "undefined"}`)
      if (entry.pkg) {
        console.log(`      main    = ${entry.pkg.json.main ?? "undefined"}`)
        console.log(`      exports = ${entry.pkg.json.exports ? JSON.stringify(entry.pkg.json.exports) : "undefined"}`)
      }
    }
  } else {
    console.log(`    (npm install required - skipping, same entrypoint logic applies)`)
  }
}

console.log("\n" + "=" .repeat(70))
console.log("Key: resolvePackageEntrypoint() skips `main` for non-server kinds")
console.log("     Superpowers has `main` but no `exports.tui` → tui kind = undefined entry")
console.log("     This affects BOTH file and npm sources equally for V1 plugins")
console.log("=" .repeat(70))

// Also test V2-style resolution (what external.ts does)
console.log("\n" + "=" .repeat(70))
console.log("V2 plugin loader (core/src/config/plugin/external.ts) comparison")
console.log("=" .repeat(70))

import path from "path"
import { fileURLToPath, pathToFileURL } from "url"

const localPackage = "/tmp/superpowers"
const npmEntrypointDir = "/home/peter/.cache/opencode/packages/superpowers/node_modules/superpowers"

console.log(`\n>>> V2 local path: "${localPackage}"`)
const v2localEntry = pathToFileURL(localPackage).href
console.log(`    entrypoint = ${v2localEntry}`)
console.log(`    import() on directory URL → depends on runtime resolving package.json`)

console.log(`\n>>> V2 npm/git path (from npm cache): "${npmEntrypointDir}"`)
// Simulate what import.meta.resolve would return for npm packages
try {
  const v2npmEntry = import.meta.resolve("superpowers", npmEntrypointDir)
  console.log(`    entrypoint = ${v2npmEntry}`)
  console.log(`    import() on resolved file → guaranteed to work`)
} catch {
  console.log(`    (npm cache dir not found in test context)`)

  // Show how it would work from the actual cached location
  const cachedDir = "/home/peter/.cache/opencode/packages/superpowers@git+https:/github.com/obra/superpowers.git/node_modules/superpowers"
  try {
    const resolved = import.meta.resolve("superpowers", cachedDir)
    console.log(`    from cache: entrypoint = ${resolved}`)
  } catch {
    console.log(`    (no access to real cache dir from test)`)
    console.log(`    expected: node_modules/superpowers/.opencode/plugins/superpowers.js (via package.json main)`)
  }
}

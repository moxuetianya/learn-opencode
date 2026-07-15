import { describe, expect, test } from "bun:test"
import {
  resolvePluginTarget,
  createPluginEntry,
  resolvePathPluginTarget,
  isPathPluginSpec,
  pluginSource,
} from "../src/plugin/shared"

const GIT_SPEC = "superpowers@git+https://github.com/obra/superpowers.git"
const LOCAL_SPEC = "/tmp/superpowers"

describe("plugin local vs git resolution", () => {
  test("isPathPluginSpec distinguishes file vs npm", () => {
    expect(isPathPluginSpec(LOCAL_SPEC)).toBe(true)
    expect(isPathPluginSpec(GIT_SPEC)).toBe(false)
    expect(pluginSource(LOCAL_SPEC)).toBe("file")
    expect(pluginSource(GIT_SPEC)).toBe("npm")
  })

  test("resolvePathPluginTarget resolves local directory", async () => {
    const target = await resolvePathPluginTarget(LOCAL_SPEC)
    console.log("local target:", target)
    expect(target.startsWith("file://")).toBe(true)
    expect(target.endsWith("superpowers")).toBe(true)
  })

  test("resolvePluginTarget - git URL installs via npm", async () => {
    const target = await resolvePluginTarget(GIT_SPEC)
    console.log("git target:", target)
    expect(target).toBeTruthy()
  }, 60000)

  test("createPluginEntry for server kind - local path", async () => {
    const target = await resolvePluginTarget(LOCAL_SPEC)
    console.log("--- local server ---")
    console.log("  target:", target)
    const entry = await createPluginEntry(LOCAL_SPEC, target, "server")
    console.log("  source:", entry.source)
    console.log("  pkg name:", entry.pkg?.json.name)
    console.log("  pkg main:", entry.pkg?.json.main)
    console.log("  entry:", entry.entry)
    expect(entry.entry).toBeTruthy()
  })

  test("createPluginEntry for server kind - git URL", async () => {
    const target = await resolvePluginTarget(GIT_SPEC)
    console.log("--- git server ---")
    console.log("  target:", target)
    const entry = await createPluginEntry(GIT_SPEC, target, "server")
    console.log("  source:", entry.source)
    console.log("  pkg name:", entry.pkg?.json.name)
    console.log("  pkg main:", entry.pkg?.json.main)
    console.log("  entry:", entry.entry)
    expect(entry.entry).toBeTruthy()
  }, 60000)

  test("createPluginEntry for tui kind - local path", async () => {
    const target = await resolvePluginTarget(LOCAL_SPEC)
    console.log("--- local tui ---")
    console.log("  target:", target)
    const entry = await createPluginEntry(LOCAL_SPEC, target, "tui")
    console.log("  source:", entry.source)
    console.log("  entry:", entry.entry)
    console.log("  ENTRY IS", entry.entry ? "DEFINED" : "UNDEFINED")
  })

  test("createPluginEntry for tui kind - git URL", async () => {
    const target = await resolvePluginTarget(GIT_SPEC)
    console.log("--- git tui ---")
    console.log("  target:", target)
    const entry = await createPluginEntry(GIT_SPEC, target, "tui")
    console.log("  source:", entry.source)
    console.log("  entry:", entry.entry)
    console.log("  ENTRY IS", entry.entry ? "DEFINED" : "UNDEFINED")
  }, 60000)
})

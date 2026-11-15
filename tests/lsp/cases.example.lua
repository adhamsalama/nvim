-- Shape of the file $LSP_TEST_CASES points at: which files of the project under test the snapshot
-- scripts open, and where they put the cursor. Keep the real one outside this repo (it names files
-- and symbols of whatever project you test against); paths are relative to that project's root.
--
-- A target is `{ line = <plain text on the line>, token = <plain text to put the cursor on>,
-- nth = <which occurrence of token on that line, default 1> }`: the first line containing `line`.
return {
  files = {
    small = "src/some/short-file.js", -- a short JS/TS file with a few functions
    large = "src/some/long-file.js", -- over 2000 lines, so it gets `vim.b.lsp_lite`
  },
  targets = {
    -- in `files.small`: a call to a function defined in the same file, inside another function
    use_in_function = { line = "doThing(", token = "doThing" },
    -- in `files.small`: a member of a Node built-in module (`crypto.createHash(...)` etc.)
    node_builtin = { line = ".createHash(", token = "createHash" },
    -- in `files.large`: an identifier used several times
    large_identifier = { line = "handleError(", token = "handleError" },
    -- in `files.small`: a function with at least one caller, for the call hierarchy UI
    call_hierarchy_root = { line = "const doThing = ", token = "doThing" },
  },
  cases = {
    {
      kind = "ch",
      name = "const arrow function",
      file = "src/some/short-file.js",
      line = "const doThing = ",
      token = "doThing",
      methods = { "incoming", "outgoing" },
    },
    {
      kind = "refs",
      name = "use inside a function",
      file = "src/some/short-file.js",
      line = "doThing(",
      token = "doThing",
    },
    { kind = "ref_count", name = "short file", file = "src/some/short-file.js" },
  },
}

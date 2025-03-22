return {
  "AstroNvim/astrolsp",
  ---@type AstroLSPOpts
  opts = {
    ---@diagnostic disable: missing-fields
    config = {
      vtsls = {
        settings = {
          vtsls = {
            experimental = {
              maxInlayHintLength = 30,
            },
          },
        },
      },
    },
  },
}

-- Single source of truth for the plugin version.
--
-- It lives under the plugin's own `readeck.` namespace on purpose: KOReader
-- puts every plugin root on package.path, so a bare `require("_meta")` from
-- main.lua can resolve to *another* plugin's _meta.lua (exporter.koplugin, for
-- one, is prepended by KOReader's own test bootstrap).
return "0.1.1"

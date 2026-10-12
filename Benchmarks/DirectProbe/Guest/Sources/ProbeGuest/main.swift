// The module is a reactor. The host calls `_initialize` and then the exports, so this entry point
// never runs, and no global may be declared here because top-level globals initialize in it.

# Changelog

## 1.0.0

Initial release.

**Disable**

- Writes enterprise policies that point Windows Update at a non-existent WSUS endpoint
  (`WUServer` / `WUStatusServer` = `http://127.0.0.1:8530`,
  `DoNotConnectToWindowsUpdateInternetLocations` = 1, `NoAutoUpdate` = 1, `UseWUServer` = 1).
  This is a configuration the servicing stack honours, unlike a modified service start type.
- Turns off Microsoft Store app auto-updates (`WindowsStore\AutoDownload` = 2).
- Sets `wuauserv`, `usosvc`, `dosvc`, `WaaSMedicSvc` and `bits` to Disabled and stops them.
- Disables every task under `UpdateOrchestrator`, `WaaSMedic`, `WindowsUpdate` and `InstallService`.
  Protected tasks are edited at the XML level and the Task Scheduler is reloaded afterwards.

**Restore**

- Restores service start types from the recorded baseline.
- Removes all policies written by the tool.
- Restores task XML from the backups taken before the first change.
- Runs `gpupdate /force`.

**Both builds**

- Service state is read from the Service Control Manager, so the status view stays accurate even if
  the service registry keys are locked down.
- Progress bar; the per-step log is collapsed by default and expands automatically on failure.

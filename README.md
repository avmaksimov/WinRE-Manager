# WinRE-Manager

**WinRE-Manager** is an interactive Windows Recovery Environment (WinRE) repair tool for Windows PowerShell 5.1. It supports basic GPT and MBR disks, searches for an existing `Winre.wim`, and can restore WinRE from a matching Windows installation ISO when necessary.

**[Русская документация](README.ru.md)**

> [!WARNING]
> This tool can format or permanently remove a Windows Recovery partition and may extend the system volume C:. **Create a complete disk backup or a verified VM checkpoint before running it.** There is no automatic rollback. Test on a disposable VM before using it on a production computer.

## Usage

Run **`WinRE-Manager.ps1`** (right-click → **Run with PowerShell**, or `& '.\WinRE-Manager.ps1'` from a PowerShell console). No script parameters are required. If administrator privileges are missing, it requests UAC and opens a separate elevated PowerShell window; the original interactive console stays open and is not terminated. Both `.ps1` scripts wait for a keypress after finishing when an interactive console is available. On UAC approval, the non-elevated instance exits without an extra pause.

Workflow: **analyze → show a proposed plan → one `Y/N` confirmation → execute**. Any response other than `Y` cancels. There are no log files.

- When WinRE is already `Enabled`, no changes are performed, even if partition sizes could be optimized.
- When WinRE is disabled, the tool searches for a usable local `Winre.wim` first. If none is found, it asks you to mount a matching Windows ISO and enter **one drive letter without a colon**, e.g. `F`.
- The tool supports `sources\install.wim` and `sources\install.esd` on the ISO. It verifies the edition, architecture, and base OS build, then stages a copy of `Winre.wim` on C: before any destructive work.
- Before the final confirmation, it computes the Recovery minimum as `max(990 MiB, Winre.wim size + 250 MiB + 32 MiB)` and checks whether the disk layout is supported.
- After approval, it first tries `reagentc /enable`; if that succeeds, no partition formatting or resizing is performed.

### Supported layouts and changes

| Disk layout | Behavior if standard `reagentc /enable` fails |
|---|---|
| `C: → Recovery → unallocated` | Delete the identified Recovery, optionally **extend** C: to a whole GiB, and create a correctly typed/formatted Recovery partition. Never shrink C:. |
| `C: → Recovery → D:` (or another later partition) | If the existing Recovery meets the calculated minimum, **format and reuse it in place**; C: and following partitions are not resized or moved. If Recovery is too small, stop without changing the partition layout. |
| `C: → unallocated` | Create Recovery in available space if enough space exists. |
| `C: → D:` with no Recovery | Unsupported by this version; no existing partition is moved or shrunk. |

For rebuilding at the end of the disk, the maximum target Recovery size is the calculated minimum plus 1024 MiB. All sizes and offsets are computed in bytes and aligned to 1 MiB. The created Recovery uses the GPT Windows RE type GUID (`DE94BBA4-06D1-4D40-A16A-BFD50179D6AC`) and required GPT attributes, or MBR type `0x27`.

### Safety limits

- Only Windows installed on **C:**; Windows 10/11 and Windows Server 2016 or later, subject to available built-in Windows utilities. Primary target: Windows 11.
- Basic disk, recognized Recovery partition type, simple adjacent layout, automatic UAC elevation, and a readable existing Recovery partition before destructive operations.
- Never deletes unidentified/OEM partitions or custom recovery content. Never reformats D: or moves it.
- BitLocker-protected or unverifiable system volumes are not modified.
- The `Winre.wim` image and any required ISO extraction are prepared *before* asking for the final `Y/N`. Temporary files can occupy significant space on C:, even if you later cancel.
- If a failure occurs **after** destructive changes, the script stops and preserves the staged `Winre.wim` for manual recovery; it does not automatically undo disk operations.

## Install or update from GitHub

After publishing the files in `avmaksimov/WinRE-Manager` on branch `main`, download the installer with **Invoke-WebRequest**:

```powershell
Invoke-WebRequest -Uri ('https://raw.githubusercontent.com/avmaksimov/WinRE-Manager/main/install.ps1?cacheBust=' + [guid]::NewGuid().ToString('N')) -Headers @{ 'Cache-Control' = 'no-cache'; 'Pragma' = 'no-cache' } -OutFile '.\install.ps1' -UseBasicParsing
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\install.ps1'
```

`install.ps1` uses `Invoke-WebRequest` (not curl) to download the GitHub source ZIP. The installation destination is the **current PowerShell working directory** (`Get-Location`), even when the installer script is stored elsewhere. Set the desired working directory before running it. It displays the full destination, compares SHA-256 hashes, lists the four managed files alphabetically as `INSTALL` (new), `REPLACE` (changed), or `UNCHANGED` (skipped), and requests one `Y/N` before making changes. Unchanged files are skipped. A `WinRE-Manager.cmd` left by older installations is not deleted automatically; it may be removed manually. It stages changed files as `.new` next to their targets, replaces them without preserving old versions, and leaves unrelated files untouched. Temporary download/extraction files are removed; it does not create its own log files. The repository must already be published and publicly accessible for the commands above to work. The installer uses the branch configured in its header.

## TODO

- Optimize C: and/or Recovery even when WinRE is already healthy; currently an enabled WinRE always causes an immediate exit.
- Support resizing an undersized Recovery between C: and D: by safely shrinking C: and rebuilding Recovery **without moving D:**.
- Add other safe shrink/grow/repartition workflows and preserve whole-GiB C: sizes where possible.
- Support more complex partition layouts with explicit safety checks.

## Microsoft documentation

- [GPT partition guidance](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/configure-uefigpt-based-hard-drive-partitions)
- [MBR partition guidance](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/configure-biosmbr-based-hard-drive-partitions)
- [REAgentC command-line options](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/reagentc-command-line-options)

## Repository layout

```text
WinRE-Manager/
├── WinRE-Manager.ps1
├── install.ps1
├── README.md
└── README.ru.md
```

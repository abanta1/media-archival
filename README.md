# Media-Archival

A collection of PowerShell scripts and modules used to rip, encode, and manage a personal media archive.  The repository has grown over several major revisions as new workflows and helper functions were developed.  Scripts range from one‑off utilities for grabbing disc metadata to general purpose modules that drive long‑running encoding pipelines.

---

## 📁 Repository Structure

- `Get-DVDTitle.ps1` – utility for fingerprinting a physical DVD/Blu‑Ray, extracting title information via **MakeMKV**, and searching for a match on **TMDb**, ripping video, and naming based on previous match.
- `Find-Langs.ps1`, `ReorderAudio.ps1` – miscellaneous helpers used in v4 workflows.
- `archive/v1/`, `archive/v2/`, `archive/v3/`, `archive/v4/` – historical versions of earlier scripts have been moved into an `archive` directory for clarity. Each sub‑directory holds one or more past iterations.
- `v5/` – current library modules used by the present workflow:
  - `Claude-Modules.ps1` – central bootstrap module that imports the rest.
  - `Media.IO.psm1`, `Media.Metadata.psm1`, `Media.Normalize.psm1`, `Media.Process.psm1`, `Media.Workflows.psm1` – modular code for I/O, metadata handling, normalization and processing.

Other standalone tools (e.g. `Get-DVDTitle.ps1`) can be run directly without importing the modules.


## ⚙️ Prerequisites

The scripts assume a Windows environment with the following installed:

1. [PowerShell 5.1](https://docs.microsoft.com/powershell/) or later (PowerShell Core should also work).
2. [MakeMKV](https://www.makemkv.com/) – used for disc inspection and ripping (`makemkvcon64.exe` must be on the path or referenced directly).
3. [HandBrakeCLI](https://handbrake.fr/docs/en/latest/cli/cli-options.html) – for encoding (referenced in some workflows).
4. A TMDb API key stored in the `TMDB_API` environment variable or passed as argument to script.
5. Any additional command‑line tools used by custom workflows (ffmpeg, mkvmerge, etc.).


## 🚀 Usage Examples

### Get disc information, match to TMDb, rip and name

```powershell
# prompt will attempt to read TMDB_API from environment or secret vault
Get-DVDTitle.ps1 -Drive "D:" -TmdbKey "<your‑api‑key>"
```

### Import and use library modules (v5)

```powershell
Import-Module .\v5\Claude-Modules.ps1
# then call exported functions such as New-RemuxWithSubtitles, Convert-IsoToLanguage, etc.
```

Most workflows are documented inline in the functions themselves, so feel free to open the `.psm1` files and read the comments.


## 📝 Development Notes

- Major refactor happened between v4 and v5 when the codebase transitioned from scattered scripts to a set of reusable modules.
- `TODO.md` contains outstanding bugs and refactoring tasks (e.g. subtitle language handling in `Media.Process.psm1`).
- Historical versions are kept for reference; feel free to browse earlier iterations if you need to see how a particular feature evolved.


## ✅ Contributing

This is a personal project, but pull requests are welcome if you find bugs or have improvements.  Please

1. Fork the repository.
2. Create a feature branch.
3. Add tests or example usage when appropriate.
4. Submit a pull request with a clear description of the changes.


## 🪪 License

The scripts are released under the MIT License — see [LICENSE](LICENSE) if added, or adapt to your preferred license.


---

> _Maintained by Abanta (2026)._  Feel free to modify for your own media archival needs.
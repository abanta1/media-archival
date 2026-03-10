# Media-Archival

A collection of PowerShell scripts, modules, and a Go automation tool used to rip, encode, and manage a personal media archive.  The repository has grown over several major revisions as new workflows and helper functions were developed.  Scripts range from one‑off utilities for grabbing disc metadata to general purpose modules that drive long‑running encoding pipelines.

---
## 🧭 Guiding Principles
- **Facts over assumptions.** Every decision the pipeline makes is grounded in measurable data — acoustic analysis (LRA, RMS, spectral flatness), element counts, codec metadata, and multi-tool consensus. If the data is ambiguous, the system says so rather than guessing.
- **Multi-tool consensus over single-source trust.** No single tool (HandBrake, ffprobe, mkvmerge, MediaInfo) is treated as authoritative. Each provides a vote, conflicts are resolved by weighted scoring, and confidence levels are tracked and surfaced to the user.
- **Confidence is a first-class value.** Every classification carries a confidence level — High, Medium, or Low. Low confidence doesn't mean failure; it means the decision is escalated to the user rather than made automatically.
- **Type safety at the boundary.** Raw data from external tools is strings. Conversion to numeric types happens once, at ingestion, in normalized form. Downstream code never casts — it compares.
- **Separation of concerns across tiers.** I/O, normalization, metadata merging, workflow decisions, planning, and orchestration are distinct layers. Each layer takes clean input from the layer below and returns clean output to the layer above. No layer reaches across boundaries.
- **Acoustic science over heuristics.** Where possible, signal processing metrics replace guesswork. Loudness range, center channel energy, and spectral flatness are objective measurements — track titles and codec names are not.
- **The encode plan is inspectable and editable.** No file is touched until the user has reviewed and confirmed the full plan. Automation accelerates the workflow; humans remain in control of the outcome.


## 📁 Repository Structure

- `Get-DVDTitle.ps1` – utility for fingerprinting a physical DVD/Blu‑Ray, extracting title information via **MakeMKV**, and searching for a match on **TMDb**, ripping video, and naming based on previous match.
- `Find-Langs.ps1`, `ReorderAudio.ps1` – miscellaneous helpers used in v4 workflows.
- `archive/v1/`, `archive/v2/`, `archive/v3/`, `archive/v4/` – historical versions of earlier scripts have been moved into an `archive` directory for clarity. Each sub‑directory holds one or more past iterations.
- `v5/` – current PowerShell library modules used by the encode workflow:
  - `Claude-Modules.ps1` – central bootstrap module that imports the rest.
  - `Media.IO.psm1` – file discovery, tool resolution, logging, raw external tool output.
  - `Media.Normalize.psm1` – stateless codec, channel, language, and subtitle type conversions.
  - `Media.Metadata.psm1` – merges raw multi-tool output into unified track objects with confidence scoring.
  - `Media.Workflows.psm1` – decision layer: AD detection, audio/subtitle strategy, subtitle classification, user review.
  - `Media.Planning.psm1` – assembles and presents the encode plan, builds HandBrake arguments, executes encodes.
  - `Media.Process.psm1` – thin orchestrators: `Invoke-EncodeMode`, `Invoke-SubReviewMode`, `Invoke-MetadataRemux`.
- `v7-go/` – Go automation tool for unattended disc ripping. See [v7-go](#-v7-go-disc-rip-automation) below.


## 🤖 v7-go: Disc Rip Automation

`v7-go/` is a Go program that monitors a disc drive, identifies the title via TMDb, rips via MakeMKV, and moves the output to a destination folder — all unattended.

### How it works

1. **Disc detection** — polls the drive until a disc is inserted.
2. **Metadata scan** — runs `makemkvcon` in info mode to extract title names, feature runtimes, and resolutions for all titles on the disc.
3. **TMDb matching** — searches TMDb by disc title, then fetches runtime details for candidate matches. Each distinct cut (theatrical, extended, etc.) is matched independently using runtime comparison with a ±2 minute tolerance.
4. **Rip** — invokes `makemkvcon` to rip the matched title to a temp directory named `Title (Year) {imdb-ttXXXXXXX}`.
5. **Move** — moves the completed rip directory from the temp path to the final destination.
6. **Eject** — ejects the disc and waits for removal before looping to the next disc.

### Files

| File | Purpose |
|---|---|
| `main.go` | Entry point, CLI flags, main disc loop |
| `config.go` | Config struct, JSON load/save |
| `models.go` | `DiscInfo`, `TitleMetadata`, `MatchResult` structs |
| `parser.go` | MakeMKV output parser (title names, resolutions, runtimes, filenames) |
| `tmdb.go` | TMDb search and runtime detail fetching |
| `logic.go` | `RunParallelLookups` — concurrent per-cut TMDb matching |
| `mkv.go` | `InvokeMakeMKVRip` — rip invocation and progress display |
| `files.go` | `MoveAndRename` — post-rip file move |
| `progress.go` | Terminal progress bar rendering |

### CLI flags

Quotes not needed unless a filename has a space in it.

```
-c  --config      Path to config JSON (default: config.json)
-T  --drive       Drive letter to monitor (e.g. D:)
-R  --rip         Temp rip path (e.g. G:\ripdir)
-D  --dest        Final destination path (e.g. G:\FinalDir)
-M  --makemkv     Path to makemkvcon64.exe
-k  --api-key     TMDb API key
-V  --debug       Enable debug logging
```

### Config JSON

```json
{
  "drive_letter": "D:",
  "base_path":    "G:\\ripdir",
  "dest_path":    "G:\\FinalDir",
  "makemkv_path": "C:\\Program Files (x86)\\MakeMKV\\makemkvcon64.exe",
  "api_key":      "your_tmdb_api_key"
}
```


## ⚙️ Prerequisites

The scripts assume a Windows environment with the following installed:

1. [PowerShell 5.1](https://docs.microsoft.com/powershell/) or later (PowerShell Core should also work).
2. [Go 1.21+](https://go.dev/) — required to build `v7-go`.
3. [MakeMKV](https://www.makemkv.com/) – used for disc inspection and ripping (`makemkvcon64.exe` must be on the path or referenced directly).
4. [HandBrakeCLI](https://handbrake.fr/docs/en/latest/cli/cli-options.html) – for encoding (referenced in v5 encode workflow).
5. A TMDb API key — passed as `-K` flag or stored in `config.json`.
6. Additional command‑line tools used by the v5 encode workflow: `ffmpeg`, `ffprobe`, `mkvmerge`, `mkvextract`, `mkvpropedit`, `MediaInfo`.


## 🚀 Usage Examples

### Automated disc ripping (v7-go)

```bash
# Build
cd v7-go
go build -o ripper.exe .

# Run
./ripper.exe -T D: -R G:\ripdir -D G:\FinalDir -M "C:\Program Files (x86)\MakeMKV\makemkvcon64.exe" -K YOUR_TMDB_KEY
```

### Get disc information, match to TMDb, rip and name (PowerShell) (v6 and prior)

```powershell
.\Get-DVDTitle.ps1 -Drive "D:" -TmdbKey "<your-api-key>"
```

### Import and use library modules (v5)

```powershell
Import-Module .\v5\Claude-Modules.ps1
# then call exported functions such as New-RemuxWithSubtitles, Convert-IsoToLanguage, etc.
```

Most workflows are documented inline in the functions themselves, so feel free to open the `.psm1` files and read the comments.


## 📝 Development Notes

- Major refactor happened between v4 and v5 when the codebase transitioned from scattered scripts to a set of reusable modules.
- `v7-go` replaces the PowerShell `Get-DVDTitle.ps1` rip loop with a compiled Go binary for lower overhead and better disc polling.
- `TODO.md` contains outstanding bugs and refactoring tasks.
- Historical versions are kept for reference; feel free to browse earlier iterations if you need to see how a particular feature evolved.


## ✅ Contributing

This is a personal project, but pull requests are welcome if you find bugs or have improvements.  Please

1. Fork the repository.
2. Create a feature branch.
3. Add tests or example usage when appropriate.
4. Submit a pull request with a clear description of the changes.


## 🪪 License

The scripts are released under the [MIT License](LICENSE).

---

> _Maintained by Abanta (2026)._  Feel free to modify for your own media archival needs.
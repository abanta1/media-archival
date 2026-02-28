# Media-Archival TODO

## Media.Process.psm1 - Subtitle Language Handling

### Issues Found
1. **Line 105 - Bug**: Variable mismatch in `Convert-IsoToLanguage` call
   - Currently passes: `$track.Language` (wrong)
   - Should pass: `$langIsoCode` (the converted value)
   - Context: Lines 92-110 build `$names` array with ISO code conversion

2. **Code Duplication**: Similar patterns in two locations
   - Lines 92-110: Converts language codes (2-digit → 3-digit → full name)
   - Lines 237-255: Similar logic for `$trackName` but skips conversion
   
### Follow-up Tasks
- [ ] Fix line 105 to use `$langIsoCode` instead of `$track.Language`
- [ ] Standardize subtitle language handling or refactor into shared helper function
- [ ] Consider creating `Get-SubtitleTrackName` utility function to eliminate duplication

### Other Known Issues
- Line 23: `foreach ($vid in $vids[9])` only processes 10th video (should be `foreach ($vid in $vids)`)
- Line 316-317: Empty loop `foreach ($tk in $sub) { }`
- Line 335: `exit` statement prevents HandBrake execution
- Lines 340-343: Empty stub functions `Save-Classification` and `Get-Classification`
- Line 346: Exports `New-RemuxWithSubtitles` but function is never defined

# Efficient search tools on GitHub (e.g. ripgrep)

## What's out there

- **Ripgrep (rg)** — [BurntSushi/ripgrep](https://github.com/BurntSushi/ripgrep) (~60k stars). Recursive, grep-like, written in Rust. Generally faster than GNU grep, git grep, The Silver Searcher (ag), ack, ugrep in published benchmarks. Respects `.gitignore` by default; can search binary files with `--binary` or `-a`/`--text`; supports literal and hex patterns. Windows: `winget install BurntSushi.ripgrep.MSVC`, or Chocolatey / Scoop.
- **Alternatives:** ugrep, The Silver Searcher (ag), git grep, ack — ripgrep is usually the one recommended for speed and features.

## Fit for our deformed-.uasset scanner

- We need to find .uasset files that (1) are ≤ 3KB and (2) contain conflict markers or have a bad header. **Ripgrep has no built-in max file size**; it cannot only search files under 3KB by itself.
- **Ways to use ripgrep (optional, not in current plan):**
  - **Hybrid:** In PowerShell, enumerate .uasset with `Get-ChildItem` and filter by `Length -le 3072`. Write the full paths to a temp file, then run `rg -l -a --path-separator / --files pathlist.txt '<<<<<<<'` so ripgrep only searches those small files. Parse rg output and merge with our magic-header check in PS.
  - **Conflict-only pass:** Run e.g. `rg -l -a -g '*.uasset' '<<<<<<<' $folder` to get all .uasset (any size) containing that string, then in PowerShell filter that list by file size ≤ 3KB and add "invalid header" by reading the first 4 bytes of each.

## Recommendation

- **Current plan stays as-is:** Pure PowerShell with a 3KB filter and per-file read is simple, has no dependency on rg, and is already efficient because we only touch small files. No change required.
- **Optional later enhancement:** If scans are still too slow on huge trees, add an optional "use ripgrep if available" path: detect `rg` in PATH, enumerate small .uasset paths, run rg on those paths for the three conflict strings, then in PS only open files that rg matched for the magic-header validation. Document in README that ripgrep is optional and can speed up the conflict-marker pass.

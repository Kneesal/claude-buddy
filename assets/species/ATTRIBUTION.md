# Species Sprite Attribution

Every PNG in this directory is contributor-authored via the deterministic
pixel-art generator at `scripts/art/source-sprites.py`. The generator is
committed to the repo — anyone cloning can regenerate the PNGs by running
it, which will produce byte-identical output.

## License

All five species PNGs in this directory are released into the **public
domain** under the [Creative Commons CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/)
dedication. No attribution required; use, modify, and redistribute freely.

## Per-file provenance

| File | Source | License | Date | Author |
|---|---|---|---|---|
| `axolotl.png`  | `scripts/art/source-sprites.py::draw_axolotl`  | CC0 | 2026-04-23 | claude-buddy contributors |
| `dragon.png`   | `scripts/art/source-sprites.py::draw_dragon`   | CC0 | 2026-04-23 | claude-buddy contributors |
| `owl.png`      | `scripts/art/source-sprites.py::draw_owl`      | CC0 | 2026-04-23 | claude-buddy contributors |
| `ghost.png`    | `scripts/art/source-sprites.py::draw_ghost`    | CC0 | 2026-04-23 | claude-buddy contributors |
| `capybara.png` | `scripts/art/source-sprites.py::draw_capybara` | CC0 | 2026-04-23 | claude-buddy contributors |

## Workflow

1. Edit `scripts/art/source-sprites.py` to adjust any species portrait.
2. Run `python3 scripts/art/source-sprites.py` — regenerates all 5 PNGs.
3. Run `bash scripts/bake-sprites.sh` — re-bakes the Unicode sextant
   sprites into `scripts/species/*.json:.sprite.base` via chafa.
4. Review `git diff scripts/species/*.json` to eyeball the change.

Both steps are deterministic. Running them twice without changes produces
no diff.

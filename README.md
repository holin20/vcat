# VideoCombiner (macOS)

Local macOS app to merge multiple videos into one output file.

## Features

- Pick multiple source videos.
- Reorder clips before export.
- Merge into one file.
- Write an editable subtitle / voiceover line for each clip.
- Draft subtitle lines from local clip descriptions.
- Burn subtitle lines into the exported video.
- Export a timed `.srt` subtitle sidecar.
- Export a narration-planning `.md` document with timestamps and target word counts.
- Output profiles:
  - H.264 (`.mp4`)
  - HEVC/H.265 (`.mov`)
  - Apple ProRes 422 (`.mov`)
- Local clip description generation (`<100 words`) with:
  - Scene segmentation (`PySceneDetect`)
  - Scene captioning (`Florence-2` via `transformers`)
  - Optional speech transcript (`faster-whisper`)

## Build and run

```bash
swift build
swift run VideoCombinerApp
```

## Local AI setup (optional but recommended)

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-video-understanding.txt
```

### How Local LLM / Clip Understanding Works

When you click **Generate Descriptions**, the app tries to run a bundled Python analyzer to produce a short,
human-readable description for each clip. That description is then used to:

- Display per-clip context in the timeline.
- Draft the initial **Subtitle / voiceover line** (editable).

**Pipeline (local/offline):**

1. Swift calls the analyzer:

   ```bash
   <python> VideoCombiner.app/Contents/Resources/video_understanding.py \
     --input /path/to/clip.mp4 \
     --max-words <N>
   ```

2. The analyzer prints a single JSON object to stdout:

   - `description` (string)
   - `engine` (string)
   - `scene_count` (int)
   - `warnings` (array of strings)

3. The app shows `description` in the timeline and stores `engine/warnings` for debugging.

**What models are used:**

- Scene segmentation: `PySceneDetect` (or a simple time-based fallback).
- Scene captioning: `Florence-2` via `transformers` + `torch` (runs locally; uses the Hugging Face cache).
- Optional audio transcript: `faster-whisper` (only used if installed; otherwise you may see warnings like
  `Transcript unavailable` or `No speech detected`).

If Python dependencies are missing (or a model can't load), the analyzer will fall back to simpler behavior
and emit a warning. If the Python analyzer itself can't run, the app falls back to a built-in on-device
metadata/vision summary.

**Python selection:**

- The sidebar includes **Use Detected .venv** and **Choose Python...**.
- When packaged as a `.app`, the app will try to auto-detect a nearby `.venv/bin/python`.

**Description length:**

The sidebar includes **Description length** which maps to the analyzer `--max-words` argument.

### System Requirements For The Python Analyzer

- `ffmpeg` and `ffprobe` must be available on your `PATH` (the analyzer uses them to extract frames and durations).
- A working Python environment with the packages in `requirements-video-understanding.txt`.

## Package as `.app`

```bash
./scripts/package_app.sh
open dist/VideoCombiner.app
```

The app works locally and does not require cloud services.

import os
# ── Env vars — must be set before any HF imports ──────────────────────────────
os.environ["HF_HUB_OFFLINE"] = "1"  # Skip HF network checks, model is cached locally

import argparse
import time
import cv2
import yaml
import shutil
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from mlx_vlm import load, generate
from mlx_vlm.prompt_utils import apply_chat_template
from mlx_vlm.utils import load_config

# ─────────────────────────────────────────────
#  CONFIG — tweak these to taste
# ─────────────────────────────────────────────
MODEL_ID      = "mlx-community/Qwen2-VL-7B-Instruct-4bit"
MAX_EDGE      = 512    # Resize longest edge to this (pixels). Lower = faster.
JPEG_Q        = 65     # JPEG compression quality 1-100. Lower = smaller/faster.
MAX_TOKENS    = 1024   # Max tokens the model can generate per clip.
FRAME_TMP     = "/tmp/vlm_frames"  # Base temp folder; each clip gets its own subfolder.

DEFAULT_INPUT = "/Users/hchang/Movies/dubai/day2_camel"

# Field values that are too generic to be useful — stripped from model output
FILLER_VALUES = {"none", "n/a", "na", "static", "neutral", "normal", "unknown", "-"}

# Prompt used for each frame — edit this to change what the model focuses on
FRAME_PROMPT = (
    "Describe this video frame using the structure below. "
    "Plain text only, no markdown. "
    "ONLY include a field if it has something specific and notable to say. "
    "OMIT fields that are unremarkable, unknown, or would be filled with 'none', 'n/a', 'static', 'normal', or 'neutral'.\n\n"
    "setting: <indoor/outdoor, location type, environment>\n"
    "people: <who is visible>\n"
    "action: <what people or subjects are physically doing>\n"
    "motion: <subject movement independent of camera>\n"
    "intent: <the likely purpose or narrative meaning of this moment>\n"
    "mood: <emotional atmosphere of the scene>\n"
    "objects: <key objects visible>\n"
    "text_in_frame: <any visible text, signs, labels, location names>\n"
    "camera: <angle, movement, distance>\n"
    "lighting: <quality, direction, time of day if outdoors>\n"
    "sound_context: <inferred ambient sound based on visuals>\n\n"
    "Example of a good minimal output:\n"
    "setting: outdoor, desert, sandy dunes\n"
    "people: male tourist, local handler\n"
    "action: tourist reaching out to pet camel\n"
    "mood: excited\n"
    "objects: camel with red saddle\n"
    "lighting: bright midday sun\n\n"
    "This will be used as input to generate subtitles for a travel vlog."
)# ─────────────────────────────────────────────

# Script start time — used as output filename
RUN_TS = datetime.now().strftime("%Y%m%d_%H%M%S")


def get_now() -> str:
    return datetime.now().strftime("%H:%M:%S")


# ── Stats tracking ────────────────────────────────────────────────────────────

@dataclass
class ClipStats:
    name: str
    duration: float = 0.0
    frames_extracted: int = 0
    frames_described: int = 0
    t_extraction: float = 0.0     # seconds spent extracting frames
    t_understanding: float = 0.0  # seconds spent on model inference
    t_save: float = 0.0           # seconds spent saving JSON
    succeeded: bool = False

@dataclass
class RunStats:
    t_model_load: float = 0.0
    clips: list = field(default_factory=list)

    def print_summary(self):
        print()
        print("─" * 60)
        print(f"[{get_now()}] 📊 PERFORMANCE SUMMARY")
        print(f"             Model load     : {self.t_model_load:.2f}s")
        print()
        total_extraction    = 0.0
        total_understanding = 0.0
        total_save          = 0.0
        for s in self.clips:
            status    = "✅" if s.succeeded else "❌"
            per_frame = (s.t_understanding / s.frames_described) if s.frames_described > 0 else 0.0
            print(f"             {status} {s.name}")
            print(f"                  duration       : {s.duration:.1f}s  |  frames: {s.frames_described}/{s.frames_extracted}")
            print(f"                  extraction     : {s.t_extraction*1000:.0f}ms")
            print(f"                  understanding  : {s.t_understanding:.2f}s  ({per_frame:.2f}s/frame)")
            print(f"                  save           : {s.t_save*1000:.0f}ms")
            total_extraction    += s.t_extraction
            total_understanding += s.t_understanding
            total_save          += s.t_save
        print()
        total = self.t_model_load + total_extraction + total_understanding + total_save
        print(f"             ── Totals ──────────────────────────────")
        print(f"             Extraction     : {total_extraction*1000:.0f}ms")
        print(f"             Understanding  : {total_understanding:.2f}s")
        print(f"             Save           : {total_save*1000:.0f}ms")
        print(f"             Wall time      : {total:.2f}s")
        print("─" * 60)


# ── Frame helpers ─────────────────────────────────────────────────────────────

def resize_frame(frame, max_edge: int):
    h, w = frame.shape[:2]
    scale = max_edge / max(h, w)
    if scale >= 1.0:
        return frame
    return cv2.resize(frame, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)


def extract_frames_at_1fps(
    video_path: Path,
    max_edge: int = MAX_EDGE,
    jpeg_quality: int = JPEG_Q,
) -> tuple[list[str], float]:
    clip_tmp = os.path.join(FRAME_TMP, video_path.stem)
    os.makedirs(clip_tmp, exist_ok=True)

    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        return [], 0.0

    fps         = cap.get(cv2.CAP_PROP_FPS)
    frame_count = cap.get(cv2.CAP_PROP_FRAME_COUNT)
    duration    = frame_count / fps if fps > 0 else 0.0

    frame_paths = []
    for second in range(int(duration)):
        cap.set(cv2.CAP_PROP_POS_FRAMES, int(second * fps))
        ret, frame = cap.read()
        if not ret:
            break
        frame    = resize_frame(frame, max_edge)
        tmp_path = os.path.join(clip_tmp, f"s{second:04d}.jpg")
        cv2.imwrite(tmp_path, frame, [cv2.IMWRITE_JPEG_QUALITY, jpeg_quality])
        frame_paths.append(tmp_path)

    cap.release()
    return frame_paths, duration


def cleanup_frames(frame_paths: list[str]):
    if not frame_paths:
        return
    try:
        shutil.rmtree(os.path.dirname(frame_paths[0]))
    except OSError:
        pass


# ── I/O helpers ───────────────────────────────────────────────────────────────

def collect_clips(inputs: list[str]) -> list[Path]:
    clips = []
    for item in inputs:
        p = Path(item.strip("'\" "))
        if p.is_dir():
            clips.extend(sorted(p.glob("*.mp4")) + sorted(p.glob("*.MP4")) +
                         sorted(p.glob("*.mov")) + sorted(p.glob("*.MOV")))
        elif p.is_file() and p.suffix.lower() in {".mp4", ".mov"}:
            clips.append(p)
    return clips


def save_log(log_file: Path, data: dict) -> float:
    """Save YAML log. Returns time taken in seconds."""

    # Use literal block scalar (|) for multiline strings so descriptions render
    # as clean readable blocks instead of single-quoted escaped strings
    class LiteralStr(str): pass

    def literal_representer(dumper, data):
        if "\n" in data:
            return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")
        return dumper.represent_scalar("tag:yaml.org,2002:str", data)

    yaml.add_representer(LiteralStr, literal_representer)

    def wrap_descriptions(obj):
        if isinstance(obj, dict):
            return {k: LiteralStr(v) if k == "description" and isinstance(v, str) else wrap_descriptions(v)
                    for k, v in obj.items()}
        if isinstance(obj, list):
            return [wrap_descriptions(i) for i in obj]
        return obj

    print(f"[{get_now()}] 💾 Saving log → {log_file} ({len(data.get('clips', data))} clip(s))...")
    t0 = time.time()
    try:
        with open(log_file, "w", encoding="utf-8") as f:
            yaml.dump(wrap_descriptions(data), f, allow_unicode=True, sort_keys=False, default_flow_style=False)
        elapsed = time.time() - t0
        size_kb = log_file.stat().st_size / 1024
        print(f"[{get_now()}] ✅ Log saved ({size_kb:.1f} KB, {elapsed*1000:.0f}ms)")
        return elapsed
    except Exception as e:
        print(f"[{get_now()}] ❌ FAILED to save log: {e}")
        return 0.0


# ── Main ──────────────────────────────────────────────────────────────────────

def prompt_input() -> list[str]:
    """Interactively ask for input paths. Falls back to DEFAULT_INPUT if empty."""
    print("─" * 60)
    print("💡 Drag ONE folder OR MULTIPLE files into this window, then press Enter.")
    raw = input("📂 Input: ").strip()
    if not raw:
        print(f"[{get_now()}] 📂 Using default: {DEFAULT_INPUT}")
        raw = DEFAULT_INPUT
    # eval handles drag-and-drop shell quoting (e.g. paths with spaces)
    import shlex
    paths = shlex.split(raw)
    print(f"[{get_now()}] 📋 Detected {len(paths)} input(s):")
    for p in paths:
        print(f"             → {p}")
    print("─" * 60)
    return paths


def run():
    parser = argparse.ArgumentParser(
        description="Generate per-second visual descriptions of video clips using Qwen2-VL (MLX)."
    )
    parser.add_argument("--input",         nargs="+", required=False, default=None,
                        help="Skip interactive prompt by passing paths directly.")
    parser.add_argument("--max-edge",      type=int,  default=MAX_EDGE)
    parser.add_argument("--jpeg-quality",  type=int,  default=JPEG_Q)
    parser.add_argument("--max-tokens",    type=int,  default=MAX_TOKENS)
    parser.add_argument("--no-cleanup",    action="store_true")
    args = parser.parse_args()

    # ── Input — interactive if not passed as args ─────────────────────────────
    input_paths = args.input if args.input else prompt_input()

    run_stats = RunStats()

    # ── Collect clips ─────────────────────────────────────────────────────────
    print(f"[{get_now()}] 🔍 Scanning inputs: {input_paths}")
    all_clips = collect_clips(input_paths)
    if not all_clips:
        print(f"[{get_now()}] ❌ No valid video files found.")
        return
    print(f"[{get_now()}] 🎬 Found {len(all_clips)} clip(s):")
    for c in all_clips:
        print(f"             → {c}")

    # ── Output location: ./output/<RUN_TS>.json (relative to cwd) ───────────
    output_dir = Path("output")
    output_dir.mkdir(parents=True, exist_ok=True)
    log_file   = output_dir / f"{RUN_TS}.yaml"
    print(f"[{get_now()}] 📁 Output dir : {output_dir} (exists={output_dir.exists()})")
    print(f"[{get_now()}] 📄 Log file   : {log_file}")

    # ── Load model ────────────────────────────────────────────────────────────
    print(f"[{get_now()}] 🚀 Loading {MODEL_ID} ...")
    print(f"[{get_now()}] ⚙️  Settings → max_edge={args.max_edge}px | "
          f"jpeg_quality={args.jpeg_quality}")
    t_load = time.time()
    model, processor = load(MODEL_ID)
    config = load_config(MODEL_ID)
    run_stats.t_model_load = time.time() - t_load
    print(f"[{get_now()}] ✅ Model loaded ({run_stats.t_model_load:.2f}s)")

    # ── Process clips ─────────────────────────────────────────────────────────
    global_offset  = 0.0
    master_results = {}
    print(f"\n[{get_now()}] 📂 Total clips to process: {len(all_clips)}")
    print("─" * 60)

    for vid in all_clips:
        clip_stats = ClipStats(name=vid.name)

        # ── Extract frames ────────────────────────────────────────────────────
        print(f"[{get_now()}] 🖼️  Extracting frames from {vid.name}...")
        t0 = time.time()
        frames, duration = extract_frames_at_1fps(
            vid,
            max_edge=args.max_edge,
            jpeg_quality=args.jpeg_quality,
        )
        clip_stats.t_extraction     = time.time() - t0
        clip_stats.duration         = duration
        clip_stats.frames_extracted = len(frames)
        print(f"[{get_now()}] 🖼️  {len(frames)} frames extracted in {clip_stats.t_extraction*1000:.0f}ms | duration={duration:.2f}s")

        if frames:
            print(f"[{get_now()}] 🖼️  First frame : {frames[0]} (exists={Path(frames[0]).exists()})")
            print(f"[{get_now()}] 🖼️  Last frame  : {frames[-1]}")
        else:
            print(f"[{get_now()}] ❌ Could not extract frames from {vid.name} — skipping.")
            run_stats.clips.append(clip_stats)
            continue

        print(f"[{get_now()}] 🎞️  {vid.name} | {int(duration)}s | {len(frames)} frames | ~{args.max_edge}px edge")

        try:
            visual_logs        = []
            t_understand_start = time.time()

            for i, frame_path in enumerate(frames):
                second        = i
                global_second = global_offset + second
                print(f"[{get_now()}] 🤖 Frame {i+1}/{len(frames)}: clip_t={second}s | global_t={global_second:.2f}s | {frame_path} (exists={Path(frame_path).exists()})")

                formatted_prompt = apply_chat_template(
                    processor, config, FRAME_PROMPT, num_images=1
                )

                # ── Per-frame retry ───────────────────────────────────────────
                MAX_RETRIES = 3
                text = None
                t_frame_elapsed = 0.0
                for attempt in range(1, MAX_RETRIES + 1):
                    try:
                        t_frame   = time.time()
                        print(f"[{get_now()}] 🤖 Calling generate() (attempt {attempt}/{MAX_RETRIES})...")
                        frame_res = generate(
                            model,
                            processor,
                            formatted_prompt,
                            image=frame_path,
                            max_tokens=200,
                            verbose=False,
                        )
                        t_frame_elapsed = time.time() - t_frame

                        print(f"[{get_now()}] 🤖 Raw result type : {type(frame_res)}")
                        print(f"[{get_now()}] 🤖 Raw result attrs: {[a for a in dir(frame_res) if not a.startswith('_')]}")
                        print(f"[{get_now()}] 🤖 Raw result value: {frame_res!r}")

                        # Robustly extract text from whatever generate() returns
                        if hasattr(frame_res, "text"):
                            text = frame_res.text.strip()
                        elif hasattr(frame_res, "generation"):
                            text = frame_res.generation.strip()
                        elif isinstance(frame_res, str):
                            text = frame_res.strip()
                        else:
                            text = str(frame_res).strip()

                        # Post-process: strip fields the model filled with filler values
                        cleaned_lines = []
                        for line in text.splitlines():
                            if ":" in line:
                                val = line.split(":", 1)[1].strip().lower()
                                if val in FILLER_VALUES or not val:
                                    continue
                            cleaned_lines.append(line)
                        text = "\n".join(cleaned_lines).strip()
                        break  # success — exit retry loop

                    except Exception as frame_err:
                        print(f"[{get_now()}] ⚠️  Frame {i+1} attempt {attempt} failed: {frame_err}")
                        if attempt == MAX_RETRIES:
                            print(f"[{get_now()}] ❌ Frame {i+1} giving up after {MAX_RETRIES} attempts — recording as error")
                            text = f"[ERROR after {MAX_RETRIES} attempts: {frame_err}]"
                        else:
                            time.sleep(1.0)  # brief pause before retry

                print(f"[{get_now()}] ✏️  ({t_frame_elapsed:.2f}s) → {text[:100]}{'...' if len(text) > 100 else ''}")
                visual_logs.append({
                    "timestamp":   round(global_second, 2),
                    "description": text,
                })

            clip_stats.t_understanding  = time.time() - t_understand_start
            clip_stats.frames_described = len(visual_logs)

            print(f"\n[{get_now()}] 📝 visual_logs: {len(visual_logs)} entries")
            for entry in visual_logs:
                print(f"             t={entry['timestamp']}s | {entry['description'][:80]}")

            master_results[vid.name] = {
                "global_start_time": round(global_offset, 2),
                "duration":          round(duration, 2),
                "frames_analyzed":   len(frames),
                "frame_resolution":  f"max_edge={args.max_edge}px",
                "jpeg_quality":      args.jpeg_quality,
                "visual_logs":       visual_logs,
            }

            clip_stats.t_save    = save_log(log_file, {"clips": master_results})
            clip_stats.succeeded = all(
                not e["description"].startswith("[ERROR")
                for e in visual_logs
            )

        except Exception as e:
            import traceback
            print(f"\n[{get_now()}] ❌ Clip-level failure on {vid.name}: {e}")
            traceback.print_exc()
            # Record the failed clip in output so it's visible in the YAML
            master_results[vid.name] = {
                "global_start_time": round(global_offset, 2),
                "duration":          round(duration, 2),
                "error":             str(e),
                "visual_logs":       visual_logs if visual_logs else [],
            }
            save_log(log_file, {"clips": master_results})

        finally:
            run_stats.clips.append(clip_stats)
            if not args.no_cleanup:
                cleanup_frames(frames)

        global_offset += duration

    # ── Final summary ─────────────────────────────────────────────────────────
    clips_ok    = sum(1 for s in run_stats.clips if s.succeeded)
    clips_total = len(all_clips)
    all_ok      = clips_ok == clips_total

    print("─" * 60)
    print(f"[{get_now()}] {'🏆' if all_ok else '⚠️ '} STAGE 1 {'COMPLETE' if all_ok else 'FINISHED WITH ERRORS'}")
    print(f"[{get_now()}] 📊 Clips succeeded: {clips_ok} / {clips_total}")
    for name, result in master_results.items():
        if "error" in result:
            print(f"[{get_now()}]   ❌ {name}: clip-level error — {result['error']}")
        else:
            expected = result["frames_analyzed"]
            actual   = len(result["visual_logs"])
            errors   = sum(1 for e in result["visual_logs"] if e["description"].startswith("[ERROR"))
            ok       = actual == expected and errors == 0
            print(f"[{get_now()}] {'  ✅' if ok else '  ⚠️ '} {name}: {actual}/{expected} frames described" +
                  (f", {errors} frame error(s)" if errors else ""))
    print(f"[{get_now()}] 📄 Log file: {log_file}")

    run_stats.print_summary()


if __name__ == "__main__":
    run()
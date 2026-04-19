import os
# ── Env vars — must be set before any HF imports ──────────────────────────────
os.environ["HF_HUB_OFFLINE"] = "1"  # Skip HF network checks, model is cached locally

import argparse
import json
import shutil
import subprocess
import sys
import time
import re
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
import yaml

# ─────────────────────────────────────────────
#  CONFIG — tweak these to taste
# ─────────────────────────────────────────────
MODEL_ID      = "mlx-community/Qwen2-VL-7B-Instruct-4bit"
MAX_EDGE      = 512    # Resize longest edge to this (pixels). Lower = faster.
JPEG_Q        = 65     # JPEG compression quality 1-100. Lower = smaller/faster.
MAX_TOKENS    = 1024   # Max tokens the model can generate per clip.
FRAME_TMP     = "/tmp/vlm_frames"  # Base temp folder; each clip gets its own subfolder.

DEFAULT_INPUT = "/Users/hchang/Movies/dubai/day2_camel_mini"

# Field values that are too generic to be useful — stripped from model output
FILLER_VALUES = {"none", "n/a", "na", "static", "neutral", "normal", "unknown", "-"}

# Prompt used for each frame — edit this to change what the model focuses on
FRAME_PROMPT = (
    "Describe this video frame using the structure below. "
    "Plain text only, no markdown. "
    "Return ONE FIELD PER LINE. "
    "Do NOT use separators like '|' or ';'. "
    "Do NOT merge multiple fields onto one line. "
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
ORIGINAL_STDOUT = sys.stdout
def resolve_output_dir() -> Path:
    override = os.environ.get("VCAT_OUTPUT_DIR")
    if override:
        return Path(override).expanduser()
    return Path(__file__).resolve().parent / "output"


OUTPUT_DIR = resolve_output_dir()


class LiteralStr(str):
    pass


def literal_representer(dumper, data):
    if "\n" in data:
        return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")
    return dumper.represent_scalar("tag:yaml.org,2002:str", data)


yaml.add_representer(LiteralStr, literal_representer)


def wrap_descriptions(obj):
    if isinstance(obj, dict):
        return {
            k: LiteralStr(v) if k == "description" and isinstance(v, str) else wrap_descriptions(v)
            for k, v in obj.items()
        }
    if isinstance(obj, list):
        return [wrap_descriptions(i) for i in obj]
    return obj


def dump_yaml(path: Path, data: dict):
    with open(path, "w", encoding="utf-8") as f:
        yaml.dump(wrap_descriptions(data), f, allow_unicode=True, sort_keys=False, default_flow_style=False)


def get_now() -> str:
    return datetime.now().strftime("%H:%M:%S")


def _cv2():
    import cv2

    return cv2


def _load_vlm():
    from mlx_vlm import load, generate
    from mlx_vlm.prompt_utils import apply_chat_template
    from mlx_vlm.utils import load_config

    return load, generate, apply_chat_template, load_config


def to_srt_timestamp(seconds: float) -> str:
    total_ms = max(0, int(round(seconds * 1000)))
    hh, rem_ms = divmod(total_ms, 3_600_000)
    mm, rem_ms = divmod(rem_ms, 60_000)
    ss, ms = divmod(rem_ms, 1000)
    return f"{hh:02d}:{mm:02d}:{ss:02d},{ms:03d}"


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
    cv2 = _cv2()
    return cv2.resize(frame, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)


def extract_frames_at_1fps(
    video_path: Path,
    max_edge: int = MAX_EDGE,
    jpeg_quality: int = JPEG_Q,
    duration_override: float | None = None,
) -> tuple[list[tuple[str, float]], float]:
    cv2 = _cv2()
    clip_tmp = os.path.join(FRAME_TMP, video_path.stem)
    os.makedirs(clip_tmp, exist_ok=True)

    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        return [], 0.0

    fps         = cap.get(cv2.CAP_PROP_FPS)
    frame_count = cap.get(cv2.CAP_PROP_FRAME_COUNT)
    duration    = frame_count / fps if fps > 0 else 0.0

    frame_entries: list[tuple[str, float]] = []
    extract_seconds = duration_override if duration_override and duration_override > 0 else duration
    for i in range(int(extract_seconds)):
        cap.set(cv2.CAP_PROP_POS_FRAMES, int(round(i * fps)))
        ret, frame = cap.read()
        if not ret:
            break
        frame    = resize_frame(frame, max_edge)
        tmp_path = os.path.join(clip_tmp, f"s{i:04d}.jpg")
        cv2.imwrite(tmp_path, frame, [cv2.IMWRITE_JPEG_QUALITY, jpeg_quality])
        timestamp_sec = cap.get(cv2.CAP_PROP_POS_MSEC) / 1000.0
        frame_entries.append((tmp_path, timestamp_sec))

    cap.release()
    return frame_entries, duration


def cleanup_frames(frame_paths: list[tuple[str, float]]):
    if not frame_paths:
        return
    try:
        shutil.rmtree(os.path.dirname(frame_paths[0][0]))
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
    print(f"[{get_now()}] 💾 Saving log → {log_file} ({len(data.get('clips', data))} clip(s))...")
    t0 = time.time()
    try:
        dump_yaml(log_file, data)
        elapsed = time.time() - t0
        size_kb = log_file.stat().st_size / 1024
        print(f"[{get_now()}] ✅ Log saved ({size_kb:.1f} KB, {elapsed*1000:.0f}ms)")
        return elapsed
    except Exception as e:
        print(f"[{get_now()}] ❌ FAILED to save log: {e}")
        return 0.0


def write_per_clip_yaml(output_dir: Path, clip_name: str, record: dict):
    per_clip_dir = output_dir / "per_clip"
    per_clip_dir.mkdir(parents=True, exist_ok=True)
    sanitized = re.sub(r"[^\w\-\.]+", "_", clip_name)
    filename = per_clip_dir / f"{sanitized}.yaml"
    clip_start = record.get("global_start_time", 0.0)
    filtered_record = remove_global_times(record, clip_start)
    dump_yaml(filename, {"clip": filtered_record})


def remove_global_times(record: dict, clip_start: float) -> dict:
    pruned = {}
    for key, value in record.items():
        if key == "global_start_time":
            continue
        if key == "visual_logs" and isinstance(value, list):
            pruned[key] = [remove_entry_global_times(entry, clip_start) for entry in value]
            continue
        pruned[key] = value
    return pruned


def remove_entry_global_times(entry: dict, clip_start: float) -> dict:
    seconds = entry.get("in_clip_start_time")
    fallback = entry.get("timestamp_seconds")
    if seconds is None and fallback is not None:
        try:
            seconds = float(fallback) - clip_start
        except (TypeError, ValueError):
            seconds = 0.0
    try:
        seconds = float(seconds)
    except (TypeError, ValueError):
        seconds = 0.0
    seconds = max(seconds, 0.0)
    thinned = {k: v for k, v in entry.items() if k not in {"global_start_time"}}
    thinned["timestamp"] = to_srt_timestamp(seconds)
    thinned["timestamp_seconds"] = round(seconds, 3)
    return thinned


def output_log_path() -> Path:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    return OUTPUT_DIR / f"{RUN_TS}.yaml"


def build_clip_record(
    *,
    clip_path: str,
    global_start_time: float,
    duration: float,
    frames_analyzed: int,
    max_edge: int,
    jpeg_quality: int,
    visual_logs: list[dict],
    engine: str = "mlx_vlm_qwen2_vl",
    warnings: list[str] | None = None,
    error: str | None = None,
) -> dict:
    record = {
        "input_path": clip_path,
        "global_start_time": round(global_start_time, 2),
        "duration": round(duration, 2),
        "frames_analyzed": frames_analyzed,
        "frame_resolution": f"max_edge={max_edge}px",
        "jpeg_quality": jpeg_quality,
        "visual_logs": visual_logs,
        "engine": engine,
        "warnings": warnings or [],
    }
    if error:
        record["error"] = error
    return record


def yaml_clips_from_app_results(results: list[dict], max_edge: int, jpeg_quality: int) -> dict:
    clips: dict = {}
    global_offset = 0.0

    for item in results:
        input_path = item.get("input_path")
        if not input_path:
            continue
        clip_path = Path(input_path)
        clip_duration = ffprobe_duration(clip_path)
        scenes = item.get("scenes") or []
        raw_visual_logs = item.get("visual_logs") or []
        duration = 0.0
        visual_logs = []
        if raw_visual_logs:
            for entry in raw_visual_logs:
                local_start = entry.get("in_clip_start_time")
                if local_start is None and entry.get("timestamp_seconds") is not None:
                    try:
                        local_start = float(entry.get("timestamp_seconds"))
                    except (TypeError, ValueError):
                        local_start = 0.0
                try:
                    local_start = float(local_start or 0.0)
                except (TypeError, ValueError):
                    local_start = 0.0
                duration = max(duration, local_start)
                visual_logs.append(entry)
        else:
            for scene in scenes:
                start_sec = float(scene.get("start_sec") or 0.0)
                end_sec = float(scene.get("end_sec") or start_sec)
                duration = max(duration, end_sec)
                visual_logs.append(
                    {
                        "timestamp": to_srt_timestamp(global_offset + start_sec),
                        "timestamp_seconds": round(global_offset + start_sec, 3),
                        "in_clip_start_time": round(start_sec, 3),
                        "description": scene.get("caption", "") or "",
                    }
                )

        effective_duration = max(clip_duration, duration)
        finalized_logs = [finalize_visual_log(entry, global_offset) for entry in visual_logs]

        clips[clip_path.name] = build_clip_record(
            clip_path=str(clip_path),
            global_start_time=global_offset,
            duration=effective_duration,
            frames_analyzed=len(scenes),
            max_edge=max_edge,
            jpeg_quality=jpeg_quality,
            visual_logs=finalized_logs,
            engine=item.get("engine", "mlx_vlm_qwen2_vl") or "mlx_vlm_qwen2_vl",
            warnings=item.get("warnings") or [],
            error=item.get("error"),
        )
        global_offset += effective_duration

    return {"clips": clips}


def finalize_visual_log(entry: dict, global_offset: float) -> dict:
    log = dict(entry)
    local_start = log.get("in_clip_start_time")
    if local_start is None and log.get("timestamp_seconds") is not None:
        try:
            local_start = float(log.get("timestamp_seconds"))
        except (TypeError, ValueError):
            local_start = 0.0
    try:
        local_start = float(local_start or 0.0)
    except (TypeError, ValueError):
        local_start = 0.0
    local_start = max(local_start, 0.0)

    global_start = global_offset + local_start
    log["in_clip_start_time"] = round(local_start, 3)
    log["global_start_time"] = round(global_start, 3)
    log["timestamp_seconds"] = round(global_start, 3)
    log["timestamp"] = to_srt_timestamp(global_start)
    return log


def ffprobe_duration(video_path: Path) -> float:
    try:
        result = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(video_path),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        return max(float(result.stdout.strip()), 0.0)
    except Exception:
        return 0.0


def clip_sentence(description: str) -> str:
    text = " ".join((description or "").split())
    if not text:
        return ""
    if ":" in text:
        parts = []
        normalized = (description or "").replace("\r\n", "\n").replace("\r", "\n")
        source_lines = [line.strip() for line in normalized.splitlines() if line.strip()]
        if not source_lines:
            source_lines = [line.strip() for line in text.split(" | ") if line.strip()]
        for line in source_lines:
            if ":" in line:
                key, value = line.split(":", 1)
                value = value.strip()
                if value:
                    parts.append(f"{key.strip()} {value}")
            elif line.strip():
                parts.append(line.strip())
        if parts:
            text = ", ".join(parts)
    return text.rstrip(".")


def summarize_clip(clip_name: str, duration: float, visual_logs: list[dict], max_words: int) -> str:
    snippets: list[str] = []
    for entry in visual_logs:
        sentence = clip_sentence(entry.get("description", ""))
        if sentence and sentence not in snippets:
            snippets.append(sentence)
        if len(snippets) >= 4:
            break

    if snippets:
        summary = f"{clip_name} runs about {duration:.0f} seconds. Highlights: " + "; ".join(snippets) + "."
    else:
        summary = f"{clip_name} runs about {duration:.0f} seconds with limited visual details detected."

    words = summary.split()
    if len(words) <= max_words:
        return summary
    return " ".join(words[:max_words]).rstrip(".,;:") + "..."


def analyze_clip_for_app(
    video_path: Path,
    max_words: int,
    max_edge: int,
    jpeg_quality: int,
    max_tokens: int,
    model_bundle=None,
) -> dict:
    if model_bundle is None:
        load, _generate, _apply_chat_template, load_config = _load_vlm()
        print(f"[{get_now()}] 🚀 Loading {MODEL_ID} ...")
        t_load = time.time()
        model, processor = load(MODEL_ID)
        config = load_config(MODEL_ID)
        print(f"[{get_now()}] ✅ Model loaded ({time.time() - t_load:.2f}s)")
    else:
        model, processor, config = model_bundle
    _, generate, apply_chat_template, _ = _load_vlm()

    frames, duration = extract_frames_at_1fps(video_path, max_edge=max_edge, jpeg_quality=jpeg_quality)
    if not frames:
        raise RuntimeError(f"Could not extract frames from {video_path.name}")

    visual_logs: list[dict] = []
    try:
        for i, (frame_path, frame_timestamp) in enumerate(frames):
            formatted_prompt = apply_chat_template(processor, config, FRAME_PROMPT, num_images=1)
            print(f"[{get_now()}] 🤖 Frame {i + 1}/{len(frames)}: {frame_path} @ {frame_timestamp:.3f}s")
            frame_res = generate(
                model,
                processor,
                formatted_prompt,
                image=frame_path,
                max_tokens=max_tokens,
                verbose=False,
            )
            if hasattr(frame_res, "text"):
                text = frame_res.text.strip()
            elif hasattr(frame_res, "generation"):
                text = frame_res.generation.strip()
            elif isinstance(frame_res, str):
                text = frame_res.strip()
            else:
                text = str(frame_res).strip()

            cleaned_lines = []
            for line in text.splitlines():
                if ":" in line:
                    val = line.split(":", 1)[1].strip().lower()
                    if val in FILLER_VALUES or not val:
                        continue
                cleaned_lines.append(line.strip())
            cleaned = "\n".join(line for line in cleaned_lines if line).strip()
            visual_logs.append(
                {
                    "timestamp": to_srt_timestamp(frame_timestamp),
                    "timestamp_seconds": frame_timestamp,
                    "in_clip_start_time": round(frame_timestamp, 3),
                    "description": cleaned,
                }
            )
    finally:
        cleanup_frames(frames)

    description = summarize_clip(video_path.name, duration or ffprobe_duration(video_path), visual_logs, max_words)
    scenes = []
    for index, entry in enumerate(visual_logs):
        caption = entry["description"]
        if not caption:
            continue
        start = float(entry.get("timestamp_seconds") or index)
        end = start + 1.0
        scenes.append(
            {
                "index": index,
                "start_sec": start,
                "end_sec": end,
                "mid_sec": start + 0.5,
                "caption": caption,
            }
        )

    return {
        "input_path": str(video_path),
        "description": description,
        "engine": "mlx_vlm_qwen2_vl",
        "scene_count": len(scenes),
        "scenes": scenes,
        "visual_logs": visual_logs,
        "warnings": [],
    }


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
    parser.add_argument("--cleanup",       action="store_true",
                        help="Remove extracted frames when the run finishes.")
    parser.add_argument("--max-words",     type=int,  default=120)
    parser.add_argument("--lang",          default="en")
    parser.add_argument("--segment-sec",   type=float, default=1.0)
    parser.add_argument("--engine",        default="auto")
    parser.add_argument("--json-output",   action="store_true",
                        help="Emit one JSON payload to stdout for app integration.")
    args = parser.parse_args()

    if args.json_output:
        sys.stdout = sys.stderr
        input_paths = args.input if args.input else prompt_input()
        all_clips = collect_clips(input_paths)
        if not all_clips:
            payload = {
                "error": "No valid input clips found for --json-output mode.",
                "warnings": [],
            }
            print(json.dumps(payload), file=ORIGINAL_STDOUT)
            return

        load, _generate, _apply_chat_template, load_config = _load_vlm()
        try:
            print(f"[{get_now()}] 🚀 Loading {MODEL_ID} ...")
            t_load = time.time()
            model, processor = load(MODEL_ID)
            config = load_config(MODEL_ID)
            print(f"[{get_now()}] ✅ Model loaded ({time.time() - t_load:.2f}s)")
            model_bundle = (model, processor, config)

            results = []
            for clip in all_clips:
                try:
                    results.append(
                        analyze_clip_for_app(
                            clip,
                            max_words=args.max_words,
                            max_edge=args.max_edge,
                            jpeg_quality=args.jpeg_quality,
                            max_tokens=args.max_tokens,
                            model_bundle=model_bundle,
                        )
                    )
                except Exception as exc:
                    results.append(
                        {
                            "input_path": str(clip),
                            "error": str(exc),
                            "warnings": [str(exc)],
                            "scenes": [],
                        }
                    )
            payload = yaml_clips_from_app_results(results, args.max_edge, args.jpeg_quality)
            log_file = output_log_path()
            save_log(log_file, payload)
            output_dir = log_file.parent
            for clip_name, record in payload.get("clips", {}).items():
                write_per_clip_yaml(output_dir, clip_name, record)
        except Exception as exc:
            payload = {
                "error": str(exc),
                "warnings": [str(exc)],
            }
        print(json.dumps(payload, ensure_ascii=False), file=ORIGINAL_STDOUT)
        return

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
    output_dir = OUTPUT_DIR
    output_dir.mkdir(parents=True, exist_ok=True)
    log_file   = output_dir / f"{RUN_TS}.yaml"
    print(f"[{get_now()}] 📁 Output dir : {output_dir} (exists={output_dir.exists()})")
    print(f"[{get_now()}] 📄 Log file   : {log_file}")

    # ── Load model ────────────────────────────────────────────────────────────
    print(f"[{get_now()}] 🚀 Loading {MODEL_ID} ...")
    print(f"[{get_now()}] ⚙️  Settings → max_edge={args.max_edge}px | "
          f"jpeg_quality={args.jpeg_quality}")
    t_load = time.time()
    load, generate, apply_chat_template, load_config = _load_vlm()
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
        clip_duration = ffprobe_duration(vid)
        frames, duration = extract_frames_at_1fps(
            vid,
            max_edge=args.max_edge,
            jpeg_quality=args.jpeg_quality,
            duration_override=clip_duration,
        )
        clip_stats.t_extraction     = time.time() - t0
        clip_stats.duration         = clip_duration
        clip_stats.frames_extracted = len(frames)
        print(f"[{get_now()}] 🖼️  {len(frames)} frames extracted in {clip_stats.t_extraction*1000:.0f}ms | duration={clip_duration:.2f}s")

        if frames:
            print(f"[{get_now()}] 🖼️  First frame : {frames[0][0]} (exists={Path(frames[0][0]).exists()})")
            print(f"[{get_now()}] 🖼️  Last frame  : {frames[-1][0]} (timestamp={frames[-1][1]:.3f}s)")
        else:
            print(f"[{get_now()}] ❌ Could not extract frames from {vid.name} — skipping.")
            run_stats.clips.append(clip_stats)
            continue

        print(f"[{get_now()}] 🎞️  {vid.name} | {clip_duration:.2f}s | {len(frames)} frames | ~{args.max_edge}px edge")

        try:
            visual_logs        = []
            t_understand_start = time.time()

            for i, (frame_path, frame_timestamp) in enumerate(frames):
                second        = frame_timestamp
                global_second = global_offset + second
                print(f"[{get_now()}] 🤖 Frame {i+1}/{len(frames)}: clip_t={second:.3f}s | global_t={global_second:.3f}s | {frame_path} (exists={Path(frame_path).exists()})")

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
                    "timestamp":          to_srt_timestamp(global_second),
                    "in_clip_start_time": round(second, 3),
                    "global_start_time":  round(global_second, 3),
                    "timestamp_seconds":  round(global_second, 3),
                    "description":        text,
                })

            clip_stats.t_understanding  = time.time() - t_understand_start
            clip_stats.frames_described = len(visual_logs)

            print(f"\n[{get_now()}] 📝 visual_logs: {len(visual_logs)} entries")
            for entry in visual_logs:
                print(f"             t={entry['timestamp']} | {entry['description'][:80]}")

            record = build_clip_record(
                clip_path=str(vid),
                global_start_time=global_offset,
                duration=clip_duration,
                frames_analyzed=len(frames),
                max_edge=args.max_edge,
                jpeg_quality=args.jpeg_quality,
                visual_logs=visual_logs,
                engine="mlx_vlm_qwen2_vl",
                warnings=[],
            )
            master_results[vid.name] = record
            write_per_clip_yaml(output_dir, vid.name, record)

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
            record = build_clip_record(
                clip_path=str(vid),
                global_start_time=global_offset,
                duration=clip_duration,
                frames_analyzed=len(visual_logs),
                max_edge=args.max_edge,
                jpeg_quality=args.jpeg_quality,
                visual_logs=visual_logs if visual_logs else [],
                engine="mlx_vlm_qwen2_vl",
                warnings=[str(e)],
                error=str(e),
            )
            master_results[vid.name] = record
            write_per_clip_yaml(output_dir, vid.name, record)
            save_log(log_file, {"clips": master_results})

        finally:
            run_stats.clips.append(clip_stats)
        if args.cleanup:
            cleanup_frames(frames)

        global_offset += clip_duration

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

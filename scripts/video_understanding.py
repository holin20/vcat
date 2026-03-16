#!/usr/bin/env python3
import argparse
import base64
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import List, Optional, Tuple


@dataclass
class Scene:
    start_sec: float
    end_sec: float


class AnalyzerError(Exception):
    pass


def run_cmd(cmd: List[str]) -> str:
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if p.returncode != 0:
        raise AnalyzerError(p.stderr.strip() or f"Command failed: {' '.join(cmd)}")
    return p.stdout


def ffprobe_duration(path: str) -> float:
    out = run_cmd([
        "ffprobe", "-v", "error", "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1", path,
    ]).strip()
    try:
        return max(float(out), 0.0)
    except ValueError:
        return 0.0


def detect_scenes(path: str, duration_sec: float, segment_sec: float = 0.0) -> List[Scene]:
    # Fixed segmentation (used for timestamped descriptions/subtitles).
    if segment_sec and segment_sec > 0 and duration_sec > 0:
        seg = max(float(segment_sec), 0.25)
        count = max(1, int(math.ceil(duration_sec / seg)))
        scenes: List[Scene] = []
        for i in range(count):
            s = i * seg
            e = min((i + 1) * seg, duration_sec)
            if e - s > 0.1:
                scenes.append(Scene(s, e))
        return scenes

    try:
        from scenedetect import SceneManager, open_video
        from scenedetect.detectors import AdaptiveDetector

        video = open_video(path)
        manager = SceneManager()
        manager.add_detector(AdaptiveDetector(adaptive_threshold=3.0, min_scene_len=20))
        manager.detect_scenes(video)
        scene_list = manager.get_scene_list()

        scenes: List[Scene] = []
        for start, end in scene_list:
            s = start.get_seconds()
            e = end.get_seconds()
            if e - s > 0.1:
                scenes.append(Scene(s, e))
        if scenes:
            return scenes
    except Exception:
        pass

    # Fallback: uniform pseudo-scenes
    if duration_sec <= 0:
        return [Scene(0.0, 1.0)]
    count = min(6, max(1, int(math.ceil(duration_sec / 8.0))))
    chunk = duration_sec / count
    return [Scene(i * chunk, min((i + 1) * chunk, duration_sec)) for i in range(count)]


def extract_frame(path: str, second: float, output_path: str) -> None:
    run_cmd([
        "ffmpeg", "-y", "-ss", f"{second:.3f}", "-i", path,
        "-frames:v", "1", "-q:v", "2", output_path,
    ])


def transcribe_audio(path: str) -> Tuple[str, str]:
    """
    Returns (transcript_text, status) where status is one of:
    - "ok": succeeded (text may be empty if no speech)
    - "unavailable": faster-whisper not installed
    - "failed": runtime error during transcription
    """
    try:
        from faster_whisper import WhisperModel
    except Exception:
        return "", "unavailable"

    try:
        model = WhisperModel("small", compute_type="int8")
        segments, _ = model.transcribe(path, beam_size=3, vad_filter=True)
        text = " ".join(seg.text.strip() for seg in segments if seg.text.strip())
        text = re.sub(r"\s+", " ", text).strip()
        return text, "ok"
    except Exception:
        return "", "failed"


def _load_florence():
    from transformers import AutoModelForCausalLM, AutoProcessor
    import torch

    model_id = os.environ.get("VCAT_VLM_MODEL", "microsoft/Florence-2-base")
    device = "mps" if hasattr(torch.backends, "mps") and torch.backends.mps.is_available() else "cpu"
    dtype = torch.float16 if device != "cpu" else torch.float32

    # Florence-2 remote-code models may not define `_supports_sdpa`, which can
    # crash during init when transformers probes SDPA support. Force eager
    # attention to bypass that probe.
    #
    # Try local cache first to avoid slow network retries in offline setups.
    def _load(local_files_only: bool):
        model = AutoModelForCausalLM.from_pretrained(
            model_id,
            trust_remote_code=True,
            torch_dtype=dtype,
            attn_implementation="eager",
            local_files_only=local_files_only,
        )
        processor = AutoProcessor.from_pretrained(
            model_id,
            trust_remote_code=True,
            local_files_only=local_files_only,
        )
        return model, processor

    try:
        model, processor = _load(local_files_only=True)
    except Exception:
        model, processor = _load(local_files_only=False)

    try:
        model.to(device)
    except Exception:
        pass
    model.eval()
    return model, processor


def caption_image(image_path: str, model_bundle=None, lang: str = "en") -> str:
    try:
        from PIL import Image
        import torch

        if model_bundle is None:
            model_bundle = _load_florence()

        model, processor = model_bundle
        image = Image.open(image_path).convert("RGB")
        task_token = "<DETAILED_CAPTION>"
        # Keep the task token exact; some Florence-2 processors rely on it for post-processing.
        prompt = task_token
        inputs = processor(text=prompt, images=image, return_tensors="pt")
        device = getattr(next(iter(model.parameters())), "device", None)
        model_dtype = getattr(next(iter(model.parameters())), "dtype", None)
        if device is not None:
            for k, v in list(inputs.items()):
                if torch.is_tensor(v):
                    moved = v.to(device)
                    if model_dtype is not None and moved.is_floating_point():
                        moved = moved.to(dtype=model_dtype)
                    inputs[k] = moved

        with torch.no_grad():
            generated_ids = model.generate(
                input_ids=inputs["input_ids"],
                pixel_values=inputs["pixel_values"],
                max_new_tokens=96,
                num_beams=1,
                do_sample=False,
                use_cache=False,
            )

        # Florence-2 typically requires post-processing to turn raw tokens into a caption.
        raw = processor.batch_decode(generated_ids, skip_special_tokens=False)[0]
        if hasattr(processor, "post_process_generation"):
            try:
                processed = processor.post_process_generation(raw, task=task_token, image_size=image.size)
                if isinstance(processed, str):
                    return re.sub(r"\s+", " ", processed).strip()
                if isinstance(processed, dict):
                    # Prefer common keys, otherwise first stringish value.
                    for key in ("caption", "detailed_caption", "text"):
                        v = processed.get(key)
                        if isinstance(v, str) and v.strip():
                            return re.sub(r"\s+", " ", v).strip()
                    for v in processed.values():
                        if isinstance(v, str) and v.strip():
                            return re.sub(r"\s+", " ", v).strip()
                if isinstance(processed, list):
                    joined = " ".join(str(x).strip() for x in processed if str(x).strip())
                    if joined.strip():
                        return re.sub(r"\s+", " ", joined).strip()
            except Exception:
                pass

        decoded = processor.batch_decode(generated_ids, skip_special_tokens=True)[0]
        decoded = decoded.replace(task_token, "").strip()
        decoded = re.sub(r"\s+", " ", decoded).strip()
        return decoded
    except Exception as exc:
        if os.environ.get("VCAT_DEBUG_CAPTION") == "1":
            raise
        return ""


def _translate_to_zh_hant(text: str, warnings: list[str]) -> str:
    """
    Best-effort translation using an optional local LLM endpoint (llamafile).
    If no local endpoint is reachable, return the original text and append a warning.
    """
    text = (text or "").strip()
    if not text:
        return text

    endpoint = os.getenv("VCAT_LLAMAFILE_ENDPOINT")
    if not endpoint:
        warnings.append(
            "Traditional Chinese requested, but no local translation engine configured (VCAT_LLAMAFILE_ENDPOINT not set)."
        )
        return text

    model = os.getenv("VCAT_LLAMAFILE_MODEL", "llava-v1.5-7b-q4")
    api_key = os.getenv("VCAT_LLAMAFILE_API_KEY", "dummy")
    try:
        body = {
            "model": model,
            "messages": [{
                "role": "user",
                "content": (
                    "Translate the following text to Traditional Chinese (繁體中文). "
                    "Keep meaning, be concise, and output only the translation.\n\n"
                    f"{text}"
                ),
            }],
            "max_tokens": 220,
        }
        resp = _http_post(f"{endpoint.rstrip('/')}/chat/completions", body, api_key)
        msg = resp["choices"][0]["message"]["content"]
        out = (msg or "").strip()
        if out:
            return out
    except Exception:
        pass

    warnings.append("Traditional Chinese requested, but local translation engine was unreachable. Returning English output.")
    return text


def pick_keywords(captions: List[str], transcript: str) -> List[str]:
    text = " ".join(captions + ([transcript] if transcript else []))
    words = re.findall(r"[A-Za-z][A-Za-z\-]{3,}", text.lower())
    stop = {
        "this", "that", "with", "from", "into", "clip", "video", "scene", "about", "there",
        "their", "while", "where", "which", "these", "those", "being", "shows", "showing",
        "camera", "person", "people", "image", "frame", "audio", "background"
    }
    freq = {}
    for w in words:
        if w in stop:
            continue
        freq[w] = freq.get(w, 0) + 1
    ranked = sorted(freq.items(), key=lambda kv: (-kv[1], kv[0]))
    return [w for w, _ in ranked[:5]]


def limit_words(text: str, max_words: int) -> str:
    words = text.split()
    if len(words) <= max_words:
        return text
    return " ".join(words[:max_words]) + "..."


# -----------------------------
# LLaVA via local llamafile API
# -----------------------------
def _b64_image(path: str) -> str:
    with open(path, "rb") as f:
        return "data:image/png;base64," + base64.b64encode(f.read()).decode("ascii")


def _http_post(url: str, payload: dict, api_key: str) -> dict:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
    })
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.URLError as exc:  # pragma: no cover
        raise AnalyzerError(f"llamafile request failed: {exc}") from exc


def _cli_llava_run(bin_path: str, prompt: str, image_paths: list[str]) -> str:
    cmd = [bin_path, "--temp", "0.2", "--top_p", "0.9", "-n", "160"]
    for p in image_paths:
        cmd.extend(["--image", p])
    cmd.extend(["-p", prompt])

    try:
        out = run_cmd(cmd)
    except AnalyzerError as exc:
        raise AnalyzerError(f"llamafile cli failed: {exc}")

    # Take the last non-empty line as the response
    lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
    if not lines:
        raise AnalyzerError("llamafile cli returned empty output")
    return lines[-1]


def describe_window_llava(
    endpoint: str,
    api_key: str,
    model: str,
    prompt: str,
    image_paths: list[str],
) -> str:
    content = [{"type": "text", "text": prompt}]
    for p in image_paths:
        content.append({"type": "image_url", "image_url": {"url": _b64_image(p)}})

    body = {
        "model": model,
        "messages": [{"role": "user", "content": content}],
        "max_tokens": 160,
    }
    resp = _http_post(f"{endpoint.rstrip('/')}/chat/completions", body, api_key)
    try:
        msg = resp["choices"][0]["message"]["content"]
        return msg.strip()
    except Exception as exc:  # pragma: no cover
        raise AnalyzerError(f"llamafile response parse error: {exc}")


def describe_video_llava(path: str, max_words: int, lang: str = "en", segment_sec: float = 0.0) -> dict:
    # This backend supports both an OpenAI-compatible llamafile endpoint and a local
    # Ollama-style endpoint. The URL and model are taken from env vars so the app
    # doesn't need to know which local stack you are using.
    endpoint = os.getenv("VCAT_LLAMAFILE_ENDPOINT", "http://localhost:11434/v1")
    model = os.getenv("VCAT_LLAMAFILE_MODEL", "llava-v1.5-7b-q4")
    api_key = os.getenv("VCAT_LLAMAFILE_API_KEY", "dummy")
    cli_bin = os.getenv("VCAT_LLAMAFILE_BIN")
    segment = int(os.getenv("VCAT_LLAMAFILE_SEGMENT_SEC", "10"))
    if segment_sec and segment_sec > 0:
        segment = max(1, int(round(segment_sec)))
    frames_per = int(os.getenv("VCAT_LLAMAFILE_FRAMES_PER_SEG", "2"))

    duration = ffprobe_duration(path)
    if duration <= 0:
        raise AnalyzerError("Could not read duration for llamafile analysis.")

    segments = max(1, math.ceil(duration / segment))
    lines: list[str] = []
    warnings: list[str] = []

    with tempfile.TemporaryDirectory(prefix="vcat-llava-") as td:
        for i in range(segments):
            start = i * segment
            end = min(duration, (i + 1) * segment)
            if end - start < 0.1:
                continue

            image_paths: list[str] = []
            for j in range(frames_per):
                ts = start + (end - start) * (j + 1) / (frames_per + 1)
                frame_path = os.path.join(td, f"seg{i:02d}_f{j:02d}.png")
                try:
                    extract_frame(path, ts, frame_path)
                    image_paths.append(frame_path)
                except Exception:
                    continue

            if not image_paths:
                continue

            if lang == "zh-Hant":
                clip_prompt = (
                    "請用繁體中文，簡短描述這段約 10 秒的影片內容。"
                    "提到主要動作、場景環境、顯眼物件與氛圍。"
                    "不要加入檔名、時間戳、或攝影器材術語。"
                )
            else:
                clip_prompt = (
                    "Describe concisely what happens in this roughly 10-second clip. "
                    "Mention key actions, setting, notable objects, and mood. "
                    "Skip metadata, timestamps, or camera jargon."
                )

            summary = ""
            try:
                summary = describe_window_llava(endpoint, api_key, model, clip_prompt, image_paths)
            except Exception:
                if cli_bin:
                    summary = _cli_llava_run(cli_bin, clip_prompt, image_paths)
                else:
                    raise
            lines.append(f"{sec_to_mmss(start)}–{sec_to_mmss(end)} {summary}")

    if not lines:
        raise AnalyzerError("No frames described by llamafile.")

    description = limit_words(" ".join(lines), max_words)
    return {
        "description": description,
        "engine": "llamafile_llava",
        "scene_count": segments,
        "warnings": warnings,
    }


def sec_to_mmss(seconds: float) -> str:
    total = max(0, int(round(seconds)))
    h = total // 3600
    m = (total % 3600) // 60
    s = total % 60
    if h:
        return f"{h}:{m:02d}:{s:02d}"
    return f"{m}:{s:02d}"


def build_description(
    filename: str,
    duration: float,
    scene_count: int,
    captions: List[str],
    transcript: str,
    max_words: int,
    lang: str,
    warnings: list[str],
) -> str:
    kept_captions = [c for c in captions if c][:3]
    visual = "; ".join(kept_captions) if kept_captions else "no strong visual captions available"

    transcript_snippet = ""
    if transcript:
        snippet_words = transcript.split()[:18]
        transcript_snippet = " ".join(snippet_words)
        if len(transcript.split()) > 18:
            transcript_snippet += "..."

    if lang == "zh-Hant":
        # Keywords extraction is English-centric; keep this field in Chinese and stable.
        tags = "一般畫面"
    else:
        key_phrases = pick_keywords(kept_captions, transcript)
        tags = ", ".join(key_phrases) if key_phrases else "general footage"

    if lang == "zh-Hant":
        # Captions should already be produced in Traditional Chinese when possible.
        translator_configured = bool(os.getenv("VCAT_LLAMAFILE_ENDPOINT"))
        if not kept_captions:
            visual = "沒有明顯的畫面描述"
        elif translator_configured:
            visual = _translate_to_zh_hant(visual, warnings)
        else:
            # Avoid mixing English into Chinese output when a translator isn't configured.
            visual = "（畫面描述目前只能產生英文；如需繁體中文請設定本機翻譯引擎）"
            warnings.append("Traditional Chinese requested, but no local translation engine configured (VCAT_LLAMAFILE_ENDPOINT not set).")
        base = (
            f"{filename} 長度約 {sec_to_mmss(duration)}，分成約 {scene_count} 個場景片段。"
            f"畫面內容：{visual}。"
            f"主題：{tags}。"
        )
    else:
        base = (
            f"{filename} runs {sec_to_mmss(duration)} across about {scene_count} scene segments. "
            f"Local scene captioning indicates: {visual}. "
            f"Dominant themes: {tags}."
        )

    if transcript_snippet:
        if lang == "zh-Hant":
            if bool(os.getenv("VCAT_LLAMAFILE_ENDPOINT")):
                translated = _translate_to_zh_hant(transcript_snippet, warnings)
                if translated:
                    base += f" 音訊內容：「{translated}」。"
        else:
            base += f" Audio context: \"{transcript_snippet}\"."

    if lang == "zh-Hant":
        base += " 適合作為合併輸出影片中的一段素材。"
    else:
        base += " Suitable as a sequence component in your merged export."
    return limit_words(re.sub(r"\s+", " ", base).strip(), max_words)


def analyze_video(path: str, max_words: int, lang: str, segment_sec: float, engine: str | None = None) -> dict:
    if not os.path.isfile(path):
        raise AnalyzerError(f"Input file not found: {path}")

    # Preferred path: explicit engine selection when requested.
    # "llamafile" forces the llamafile/LLaVA path (if available), "florence" forces the
    # built-in Florence-2 + Whisper pipeline, and None/"auto" chooses the best available.
    engine = (engine or "auto").strip().lower()
    if engine in ("auto", "llamafile"):
        try:
            return describe_video_llava(path, max_words=max_words, lang=lang, segment_sec=segment_sec)
        except Exception:
            if engine == "llamafile":
                # If the caller explicitly requested llamafile, respect failures instead of
                # silently hiding them behind another engine.
                raise
            # Otherwise fall through to the built-in pipeline.

    duration = ffprobe_duration(path)
    scenes = detect_scenes(path, duration, segment_sec=segment_sec)

    captions: List[str] = []
    scene_items: List[dict] = []
    warnings: List[str] = []
    translator_configured = bool(os.getenv("VCAT_LLAMAFILE_ENDPOINT"))

    model_bundle = None
    try:
        model_bundle = _load_florence()
    except Exception as exc:
        warnings.append(f"Florence-2 unavailable ({exc}). Falling back to metadata-only captions.")

    max_scene_items = 8
    with tempfile.TemporaryDirectory(prefix="vcat-scene-") as td:
        for i, scene in enumerate(scenes[:max_scene_items]):
            mid = (scene.start_sec + scene.end_sec) / 2.0
            frame_path = os.path.join(td, f"frame_{i:02d}.jpg")
            try:
                extract_frame(path, mid, frame_path)
                cap = caption_image(frame_path, model_bundle=model_bundle, lang=lang) if model_bundle else ""
                if cap and lang == "zh-Hant" and translator_configured:
                    cap = _translate_to_zh_hant(cap, warnings)
                if cap:
                    captions.append(cap)
                scene_items.append({
                    "index": i,
                    "start_sec": float(scene.start_sec),
                    "end_sec": float(scene.end_sec),
                    "mid_sec": float(mid),
                    "caption": cap or "",
                })
            except Exception:
                scene_items.append({
                    "index": i,
                    "start_sec": float(scene.start_sec),
                    "end_sec": float(scene.end_sec),
                    "mid_sec": float(mid),
                    "caption": "",
                })
                continue

    transcript, transcript_status = transcribe_audio(path)
    if transcript_status == "unavailable":
        warnings.append("Transcript unavailable (faster-whisper not installed).")
    elif transcript_status == "failed":
        warnings.append("Transcript failed (faster-whisper error).")
    elif not transcript:
        warnings.append("No speech detected.")

    description = build_description(
        filename=os.path.basename(path),
        duration=duration,
        scene_count=max(1, len(scenes)),
        captions=captions,
        transcript=transcript,
        max_words=max_words,
        lang=lang,
        warnings=warnings,
    )

    # Avoid repeating the same warning string multiple times.
    if warnings:
        warnings = list(dict.fromkeys(warnings))

    return {
        "description": description,
        "engine": "local_scene_vlm_whisper",
        "scene_count": len(scenes),
        "scenes": scene_items,
        "warnings": warnings,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Local video understanding for clip descriptions.")
    parser.add_argument("--input", required=True, help="Path to video file")
    parser.add_argument("--max-words", type=int, default=95)
    parser.add_argument("--lang", type=str, default="en", choices=["en", "zh-Hant"])
    parser.add_argument("--segment-sec", type=float, default=0.0, help="If >0, segment the clip into fixed windows (seconds).")
    parser.add_argument("--engine", type=str, default="auto", help="Engine selector: auto, llamafile, florence.")
    args = parser.parse_args()

    try:
        result = analyze_video(
            args.input,
            max_words=args.max_words,
            lang=args.lang,
            segment_sec=float(args.segment_sec or 0.0),
            engine=args.engine,
        )
        print(json.dumps(result, ensure_ascii=True))
        return 0
    except AnalyzerError as exc:
        print(json.dumps({"error": str(exc)}))
        return 2
    except Exception as exc:
        print(json.dumps({"error": f"unexpected_error: {exc}"}))
        return 3


if __name__ == "__main__":
    raise SystemExit(main())

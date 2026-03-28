#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROCESS_SCRIPT="$SCRIPT_DIR/process_vlog.py"

# --- CONFIGURATION ---
VENV_DIR=""
PYTHON_BIN=""

resolve_venv_dir() {
    local candidates=()
    local dir="$SCRIPT_DIR"
    local candidate

    if [ -n "${VCAT_VENV_DIR:-}" ]; then
        candidates+=("${VCAT_VENV_DIR}")
    fi
    candidates+=("${SCRIPT_DIR}/.venv")
    candidates+=("${SCRIPT_DIR}/../../../../tools/descriptiongen/.venv")

    for _ in 1 2 3 4 5 6; do
        candidates+=("${dir}/tools/descriptiongen/.venv")
        local parent
        parent="$(dirname "$dir")"
        if [ "$parent" = "$dir" ]; then
            break
        fi
        dir="$parent"
    done

    for candidate in "${candidates[@]}"; do
        if [ -x "${candidate}/bin/python" ] || [ -x "${candidate}/bin/python3" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    printf '%s\n' "${SCRIPT_DIR}/.venv"
    return 0
}

resolve_python_bin() {
    local candidates=(
        "${PYTHON_BIN:-}"
        "${VCAT_PYTHON:-}"
        "/opt/homebrew/bin/python3.11"
        "/usr/local/bin/python3.11"
        "python3.11"
    )
    local candidate
    for candidate in "${candidates[@]}"; do
        if [ -z "$candidate" ]; then
            continue
        fi
        if [[ "$candidate" == */* ]]; then
            if [ -x "$candidate" ]; then
                printf '%s\n' "$candidate"
                return 0
            fi
        elif command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
    done
    return 1
}

VENV_DIR="$(resolve_venv_dir)"

# --- PYTHON CHECK ---
if ! PYTHON_BIN="$(resolve_python_bin)"; then
    echo "❌ python3.11 not found. Install it with: brew install python@3.11" >&2
    exit 1
fi
echo "✅ $PYTHON_BIN found" >&2

# --- VENV SETUP ---
if [ -d "$VENV_DIR" ]; then
    source "$VENV_DIR/bin/activate"
else
    echo "📦 Creating fresh virtual environment (Python $("$PYTHON_BIN" -V 2>&1))..." >&2
    $PYTHON_BIN -m venv "$VENV_DIR"
    source "$VENV_DIR/bin/activate"
fi

# Only install packages once (delete .packages_installed to force reinstall)
if [ ! -f "$VENV_DIR/.packages_installed" ]; then
    echo "📦 Installing packages (first run only)..." >&2
    pip install -U mlx-vlm opencv-python huggingface_hub \
        mlx mlx-lm Pillow numpy torch torchvision pyyaml
    touch "$VENV_DIR/.packages_installed"
else
    echo "✅ Packages already installed. Skipping." >&2
fi

# --- RUN ---
python3 "$PROCESS_SCRIPT" "$@"

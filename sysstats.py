"""
sysstats.py - Shared system usage collection (CPU / RAM / GPU).

Used by both:
  - node.py         (reports stats for its machine via heartbeat)
  - orchestrator.py (reports stats for the master machine)

GPU sources (tried in order):
  1. nvidia-smi  -> NVIDIA GPUs (Linux + Windows)
  2. Linux sysfs -> AMD (amdgpu) / Intel (i915) DRM GPUs
"""

import os
import re
import glob
import subprocess

import psutil


def _read_file(path):
    try:
        with open(path, "r") as f:
            return f.read().strip()
    except Exception:
        return None


def _safe_float(val):
    try:
        return round(float(val), 1)
    except (TypeError, ValueError):
        return None


def _to_mb(raw):
    try:
        return round(int(raw) / (1024 * 1024))
    except (TypeError, ValueError):
        return None


# lspci lookups never change for a given PCI address -> cache them so we
# don't spawn a subprocess on every heartbeat.
_pci_name_cache = {}


def _gpu_display_name(device_dir, real_path):
    """Best-effort human-readable GPU name (amdgpu product_name, else lspci)."""
    name = _read_file(os.path.join(device_dir, "product_name"))
    if name:
        return name

    pci_addr = next(
        (p for p in real_path.split("/")
         if re.fullmatch(r"[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]", p)),
        None
    )
    if not pci_addr:
        return "Unknown GPU"

    if pci_addr not in _pci_name_cache:
        try:
            r = subprocess.run(["lspci", "-s", pci_addr],
                               capture_output=True, text=True, timeout=3)
            desc = r.stdout.strip()
            # lspci output: "01:00.0 VGA compatible controller: AMD ..."
            _pci_name_cache[pci_addr] = desc.split(": ", 1)[1] if ": " in desc else None
        except Exception:
            _pci_name_cache[pci_addr] = None

    return _pci_name_cache[pci_addr] or "Unknown GPU"


def _query_nvidia_gpus():
    """Query NVIDIA GPUs via nvidia-smi (works on Linux and Windows)."""
    try:
        result = subprocess.run(
            ["nvidia-smi",
             "--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode != 0:
            return []

        gpus = []
        for line in result.stdout.strip().splitlines():
            parts = [p.strip() for p in line.split(",")]
            if len(parts) >= 4:
                gpus.append({
                    "name": parts[0],
                    "utilization": _safe_float(parts[1]),
                    "memory_used_mb": _safe_float(parts[2]),
                    "memory_total_mb": _safe_float(parts[3]),
                    "temperature": _safe_float(parts[4]) if len(parts) > 4 else None,
                })
        return gpus
    except Exception:
        return []


def _query_drm_gpus():
    """Query AMD (amdgpu) / Intel (i915) GPUs via Linux kernel sysfs.

    Skips non-GPU DRM entries (card0-VGA-1, card0-HDMI-A-1, ...).
    Returns [] on Windows or when no DRM GPU exposes usable counters.
    """
    gpus = []
    try:
        for card in sorted(glob.glob("/sys/class/drm/card*")):
            if not re.fullmatch(r"card\d+", os.path.basename(card)):
                continue  # Skip card0-VGA-1, card0-eDP-1, card0-HDMI-A-1, etc.

            real = os.path.realpath(card)
            device_dir = os.path.dirname(real)

            busy = _safe_float(_read_file(os.path.join(device_dir, "gpu_busy_percent")))
            vram_used = _read_file(os.path.join(device_dir, "mem_info_vram_used"))
            vram_total = _read_file(os.path.join(device_dir, "mem_info_vram_total"))

            if busy is None and vram_total is None:
                continue  # Not a GPU with usable utilization/VRAM counters

            gpus.append({
                "name": _gpu_display_name(device_dir, real),
                "utilization": busy,
                "memory_used_mb": _to_mb(vram_used),
                "memory_total_mb": _to_mb(vram_total),
                "temperature": None,  # sysfs has no portable temp here
            })
    except Exception:
        pass
    return gpus


def prime_cpu_samplers():
    """Prime psutil CPU samplers.

    psutil.cpu_percent(interval=None) returns 0.0 on the very first call
    (it measures since the previous call), so call it once at startup.
    """
    psutil.cpu_percent(interval=None)
    psutil.cpu_percent(interval=None, percpu=True)


def get_system_stats():
    """Collect node-wide CPU / RAM / GPU utilization (non-blocking)."""
    try:
        vm = psutil.virtual_memory()
        sm = psutil.swap_memory()
    except Exception:
        vm = sm = None

    try:
        load = [round(x, 2) for x in psutil.getloadavg()]
    except Exception:
        load = []

    try:
        cpu_pct = psutil.cpu_percent(interval=None)
        per_core = psutil.cpu_percent(interval=None, percpu=True)
        cpu_count = psutil.cpu_count() or 0
    except Exception:
        cpu_pct, per_core, cpu_count = None, [], 0

    gpus = _query_nvidia_gpus()
    if not gpus:
        gpus = _query_drm_gpus()

    return {
        "cpu": {
            "percent": cpu_pct,
            "per_core": per_core,
            "count": cpu_count,
            "load_avg": load,
        },
        "memory": {
            "total_mb": _to_mb(vm.total) if vm else None,
            "used_mb": _to_mb(vm.used) if vm else None,
            "percent": round(vm.percent, 1) if vm else None,
            "swap_total_mb": _to_mb(sm.total) if sm else None,
            "swap_used_mb": _to_mb(sm.used) if sm else None,
            "swap_percent": round(sm.percent, 1) if sm else None,
        },
        "gpus": gpus,
    }

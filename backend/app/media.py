"""Upload sanitizing. Every image is decoded and re-encoded, which drops EXIF (GPS, device serials) and any
payload hidden after the image data. Videos are only accepted to be split into frames, then deleted."""

import asyncio
import hashlib
import io
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageOps, UnidentifiedImageError

from app.errors import Problem

Image.MAX_IMAGE_PIXELS = 40_000_000  # refuse decompression bombs

IMAGE_FORMATS = {"JPEG", "PNG", "WEBP", "MPO"}  # clients convert HEIC to JPEG before upload
VIDEO_SIGNATURES = (b"ftyp",)  # MP4 / MOV (ISO base media) carry 'ftyp' at offset 4


def sanitize_image(data: bytes, max_side: int) -> bytes:
    try:
        with Image.open(io.BytesIO(data)) as img:
            if img.format not in IMAGE_FORMATS:
                raise Problem(415, "unsupported_media", "Upload JPEG, PNG or WebP images.")
            img = ImageOps.exif_transpose(img)  # keep orientation before EXIF is discarded
            img = img.convert("RGB")
            img.thumbnail((max_side, max_side))
            out = io.BytesIO()
            img.save(out, format="JPEG", quality=85, optimize=True)  # no exif= argument: metadata is dropped
            return out.getvalue()
    except (UnidentifiedImageError, Image.DecompressionBombError, OSError) as error:
        raise Problem(415, "unsupported_media", "That file isn't a readable image.") from error


def looks_like_video(data: bytes) -> bool:
    return len(data) > 12 and data[4:8] in VIDEO_SIGNATURES


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def ffmpeg_available() -> bool:
    return shutil.which("ffmpeg") is not None


def _extract(video: bytes, max_frames: int) -> list[bytes]:
    with tempfile.TemporaryDirectory(prefix="agora-") as tmp:
        src = Path(tmp) / "in.mp4"
        src.write_bytes(video)
        # One frame per second, capped. Audio and metadata are never read.
        subprocess.run(  # noqa: S603 - fixed argv, no shell, input is a temp file we wrote
            [shutil.which("ffmpeg") or "ffmpeg", "-nostdin", "-loglevel", "error", "-i", str(src), "-an", "-sn", "-dn",
             "-vf", "fps=1", "-frames:v", str(max_frames), "-q:v", "3", str(Path(tmp) / "f_%03d.jpg")],
            check=True, timeout=120, capture_output=True,
        )
        return [p.read_bytes() for p in sorted(Path(tmp).glob("f_*.jpg"))]


async def extract_frames(video: bytes, max_frames: int) -> list[bytes]:
    if not ffmpeg_available():
        raise Problem(503, "video_unsupported", "Video processing isn't available here; upload photos instead.")
    try:
        frames = await asyncio.to_thread(_extract, video, max_frames)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise Problem(422, "unreadable_video", "That video couldn't be read.") from error
    if not frames:
        raise Problem(422, "unreadable_video", "No frames could be read from that video.")
    return frames

#!/usr/bin/env python3
"""Serve MJPEG AVI files as multipart HTTP streams."""

from __future__ import annotations

import argparse
import html
import json
import os
import signal
import shutil
import subprocess
import sys
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


DEFAULT_PORT = 8002
BOUNDARY = "ffmpeg"


def run_command(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, capture_output=True, check=False, text=True)


def require_command(command: str) -> None:
    if shutil.which(command) is None:
        raise SystemExit(f"Required command not found: {command}")


def detect_video_codec(path: Path) -> str:
    result = run_command(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=codec_name",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(path),
        ]
    )
    if result.returncode != 0:
        return ""
    return result.stdout.strip().splitlines()[0] if result.stdout.strip() else ""


def get_stream_info(path: Path) -> dict[str, Any]:
    result = run_command(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=codec_name,profile,width,height,r_frame_rate,avg_frame_rate,pix_fmt",
            "-of",
            "json",
            str(path),
        ]
    )
    if result.returncode != 0:
        return {}
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {}
    streams = data.get("streams", [])
    return streams[0] if streams else {}


def discover_streams(media_dir: Path) -> list[dict[str, Any]]:
    streams: list[dict[str, Any]] = []
    for path in sorted(media_dir.iterdir()):
        if not path.is_file() or path.suffix.lower() != ".avi":
            continue
        codec = detect_video_codec(path)
        if codec != "mjpeg":
            print(f"⚠️ Skipping non-MJPEG AVI: {path.name} (codec={codec or 'unknown'})")
            continue
        info = get_stream_info(path)
        streams.append(
            {
                "index": len(streams),
                "name": path.name,
                "path": path,
                "codec": codec,
                "profile": info.get("profile", ""),
                "width": info.get("width", ""),
                "height": info.get("height", ""),
                "fps": info.get("avg_frame_rate") or info.get("r_frame_rate") or "",
                "pix_fmt": info.get("pix_fmt", ""),
            }
        )
    return streams


class MJPEGHandler(BaseHTTPRequestHandler):
    server: "MJPEGServer"

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"{self.client_address[0]} - {fmt % args}")

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path

        if path in {"/", "/index.html"}:
            self.write_index()
            return
        if path == "/streams.json":
            self.write_streams_json()
            return

        if path.startswith("/src") and path.endswith(".mjpeg"):
            stream_name = path.removeprefix("/").removesuffix(".mjpeg")
            try:
                index = int(stream_name.removeprefix("src"))
            except ValueError:
                self.send_error(HTTPStatus.NOT_FOUND, "Unknown stream")
                return
            self.stream_mjpeg(index)
            return

        self.send_error(HTTPStatus.NOT_FOUND, "Unknown path")

    def write_index(self) -> None:
        rows = []
        for stream in self.server.streams:
            url = f"/src{stream['index']}.mjpeg"
            rows.append(
                "<tr>"
                f"<td>src{stream['index']}</td>"
                f"<td>{html.escape(stream['name'])}</td>"
                f"<td>{html.escape(str(stream['codec']))}</td>"
                f"<td>{html.escape(str(stream['profile']))}</td>"
                f"<td>{html.escape(str(stream['width']))}x{html.escape(str(stream['height']))}</td>"
                f"<td>{html.escape(str(stream['fps']))}</td>"
                f"<td><a href=\"{url}\">{url}</a></td>"
                "</tr>"
            )

        body = f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>MJPEG HTTP Sources</title>
  <style>
    body {{ font-family: system-ui, sans-serif; margin: 24px; }}
    table {{ border-collapse: collapse; width: 100%; }}
    th, td {{ border: 1px solid #ddd; padding: 8px; text-align: left; }}
    th {{ background: #f5f5f5; }}
  </style>
</head>
<body>
  <h1>MJPEG HTTP Sources</h1>
  <p>Serving {len(self.server.streams)} MJPEG AVI source(s).</p>
  <table>
    <thead>
      <tr><th>Stream</th><th>File</th><th>Codec</th><th>Profile</th><th>Resolution</th><th>FPS</th><th>URL</th></tr>
    </thead>
    <tbody>{''.join(rows)}</tbody>
  </table>
</body>
</html>
"""
        payload = body.encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def write_streams_json(self) -> None:
        serializable = [
            {key: value for key, value in stream.items() if key != "path"}
            for stream in self.server.streams
        ]
        payload = json.dumps(serializable, indent=2).encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def stream_mjpeg(self, index: int) -> None:
        if index < 0 or index >= len(self.server.streams):
            self.send_error(HTTPStatus.NOT_FOUND, "Unknown stream")
            return

        stream = self.server.streams[index]
        self.send_response(HTTPStatus.OK)
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Pragma", "no-cache")
        self.send_header("Connection", "close")
        self.send_header("Content-Type", f"multipart/x-mixed-replace;boundary={BOUNDARY}")
        self.end_headers()

        process = subprocess.Popen(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-nostdin",
                "-re",
                "-stream_loop",
                "-1",
                "-i",
                str(stream["path"]),
                "-an",
                "-c:v",
                "copy",
                "-f",
                "mpjpeg",
                "-",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        assert process.stdout is not None
        try:
            while True:
                chunk = process.stdout.read(64 * 1024)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)


class MJPEGServer(ThreadingHTTPServer):
    def __init__(self, server_address: tuple[str, int], handler: type[MJPEGHandler], streams: list[dict[str, Any]]):
        super().__init__(server_address, handler)
        self.streams = streams


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Serve MJPEG AVI files over HTTP multipart streams.")
    parser.add_argument("media_folder", help="Folder containing MJPEG AVI files. Non-AVI files are ignored.")
    parser.add_argument("--host", default="0.0.0.0", help="HTTP bind address. Default: 0.0.0.0")
    parser.add_argument("--port", type=int, default=int(os.environ.get("MJPEG_HTTP_PORT", DEFAULT_PORT)), help="HTTP port. Default: 8002")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    media_dir = Path(args.media_folder).expanduser().resolve()
    if not media_dir.is_dir():
        print(f"❌ Error: '{media_dir}' is not a valid directory.")
        return 1

    require_command("ffmpeg")
    require_command("ffprobe")

    streams = discover_streams(media_dir)
    if not streams:
        print(f"⚠️ No MJPEG AVI files found in {media_dir}")
        return 1

    server = MJPEGServer((args.host, args.port), MJPEGHandler, streams)

    def stop_server(signum: int, _frame: Any) -> None:
        print(f"\n🛑 Stopping MJPEG HTTP server after signal {signum}")
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, stop_server)
    signal.signal(signal.SIGTERM, stop_server)

    host_for_display = "127.0.0.1" if args.host == "0.0.0.0" else args.host
    print(f"✅ MJPEG HTTP server listening on http://{host_for_display}:{args.port}/")
    for stream in streams:
        print(
            f"🎥 {stream['name']} -> http://{host_for_display}:{args.port}/src{stream['index']}.mjpeg "
            f"(codec={stream['codec']}, {stream['width']}x{stream['height']}, fps={stream['fps']})"
        )
    print("🟢 Running in foreground. Press Ctrl+C to stop.")

    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())

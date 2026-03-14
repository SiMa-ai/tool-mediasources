from __future__ import annotations

import os
import shutil
import socket
import subprocess
import time
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "mediasrc-udp.sh"


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _wait_for_text(path: Path, needle: str, timeout: float) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if path.exists() and needle in path.read_text(encoding="utf-8"):
            return True
        time.sleep(0.25)
    return False


def test_dry_run_writes_udp_preview_config_and_sdps(tmp_path: Path) -> None:
    runtime_dir = tmp_path / "runtime"
    preview_config = tmp_path / "preview-udp-config.js"
    env = os.environ.copy()
    env["MEDIASRC_UDP_STATE_DIR"] = str(runtime_dir)
    env["MEDIASRC_UDP_PREVIEW_CONFIG_FILE"] = str(preview_config)
    env["MEDIASRC_UDP_HOST"] = "127.0.0.1"

    result = subprocess.run(
        ["bash", str(SCRIPT), "--dry-run", "--streams", "3", "--port-base", "5600"],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
    )

    assert result.returncode == 0, result.stderr

    config_text = preview_config.read_text(encoding="utf-8")
    assert 'streamCount: 3' in config_text
    assert 'baseUrl: "http://127.0.0.1"' in config_text
    assert 'pathPrefix: "udp"' in config_text

    for idx in range(3):
        sdp_path = runtime_dir / f"udp{idx}.sdp"
        assert sdp_path.is_file(), f"missing {sdp_path.name}"
        sdp_text = sdp_path.read_text(encoding="utf-8")
        assert f"m=video {5600 + idx} RTP/AVP 96" in sdp_text
        assert "a=rtpmap:96 H264/90000" in sdp_text

    stdout = result.stdout
    assert "rtsp://" in stdout
    assert "/udp0" in stdout


@pytest.mark.skipif(
    not all(shutil.which(tool) for tool in ("ffmpeg", "mediamtx")),
    reason="requires ffmpeg and mediamtx",
)
def test_live_udp_relay_publishes_rtsp_stream(tmp_path: Path) -> None:
    runtime_dir = tmp_path / "runtime"
    preview_config = tmp_path / "preview-udp-config.js"
    udp_port = _free_port()
    rtsp_port = _free_port()
    preview_port = _free_port()

    env = os.environ.copy()
    env["MEDIASRC_UDP_STATE_DIR"] = str(runtime_dir)
    env["MEDIASRC_UDP_PREVIEW_CONFIG_FILE"] = str(preview_config)
    env["MEDIASRC_UDP_HOST"] = "127.0.0.1"
    env["RTSP_PORT"] = str(rtsp_port)
    env["PREVIEW_HTTP_PORT"] = str(preview_port)

    launcher = subprocess.Popen(
        ["bash", str(SCRIPT), "--streams", "1", "--port-base", str(udp_port)],
        cwd=REPO_ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    sender: subprocess.Popen[str] | None = None
    reader: subprocess.Popen[str] | None = None

    try:
        deadline = time.time() + 20
        while time.time() < deadline:
            if preview_config.exists() and (runtime_dir / "udp0.sdp").exists():
                break
            if launcher.poll() is not None:
                break
            time.sleep(0.25)

        assert preview_config.exists(), "launcher did not write preview config"
        assert (runtime_dir / "udp0.sdp").exists(), "launcher did not write udp0.sdp"
        assert launcher.poll() is None, "launcher exited before the relay came up"

        sender = subprocess.Popen(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-nostdin",
                "-re",
                "-f",
                "lavfi",
                "-i",
                "testsrc=size=320x180:rate=10",
                "-t",
                "6",
                "-an",
                "-c:v",
                "libx264",
                "-preset",
                "ultrafast",
                "-tune",
                "zerolatency",
                "-pix_fmt",
                "yuv420p",
                "-x264-params",
                "repeat-headers=1:keyint=10:min-keyint=10:scenecut=0",
                "-f",
                "rtp",
                "-payload_type",
                "96",
                f"rtp://127.0.0.1:{udp_port}",
            ],
            cwd=REPO_ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
        )

        mediamtx_log = runtime_dir / "logs" / "mediamtx.log"
        published = _wait_for_text(mediamtx_log, "is publishing to path 'udp0'", timeout=20)
        assert published, mediamtx_log.read_text(encoding="utf-8")

        reader = subprocess.Popen(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-nostdin",
                "-rtsp_transport",
                "tcp",
                "-i",
                f"rtsp://127.0.0.1:{rtsp_port}/udp0",
                "-frames:v",
                "1",
                "-f",
                "null",
                "-",
            ],
            cwd=REPO_ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
        )

        subscribed = _wait_for_text(mediamtx_log, "is reading from path 'udp0'", timeout=10)
        if not subscribed:
            launcher.terminate()
            launcher_output = launcher.communicate(timeout=10)[0]
            pytest.fail(
                "RTSP relay never accepted a TCP reader.\n"
                f"launcher output:\n{launcher_output}\n"
                f"mediamtx log:\n{mediamtx_log.read_text(encoding='utf-8')}\n"
            )

    finally:
        if reader is not None and reader.poll() is None:
            reader.terminate()
            try:
                reader.wait(timeout=10)
            except subprocess.TimeoutExpired:
                reader.kill()
                reader.wait(timeout=10)

        if sender is not None and sender.poll() is None:
            sender.terminate()
            try:
                sender.wait(timeout=10)
            except subprocess.TimeoutExpired:
                sender.kill()
                sender.wait(timeout=10)

        if launcher.poll() is None:
            launcher.terminate()
            try:
                launcher.wait(timeout=10)
            except subprocess.TimeoutExpired:
                launcher.kill()
                launcher.wait(timeout=10)

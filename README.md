# Multi-Stream RTSP Launcher

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS%20%7C%20Windows-red?style=flat-square&logo=linux)]()


## Overview

The **Multi-Stream RTSP Launcher** is a Bash tool designed to quickly stand up an [MediaMTX](https://github.com/bluenviron/mediamtx) RTSP server and stream multiple video files over RTSP using [FFmpeg](https://ffmpeg.org).  

It automatically:  
- Installs **FFmpeg** and **MediaMTX** if not already available.  
- Starts a local RTSP server (`rtsp://<local-ip>:9554/`).  
- Scans a media folder for `.mp4` files.  
- Streams each file as a unique RTSP source (`/src0`, `/src1`, …).  
- Keeps processes alive and logs FFmpeg output to `/tmp/ffmpeg_src<N>.log`.  

This is particularly useful for testing **multi-channel video pipelines** and validating AI/vision workloads that depend on live RTSP streams.  


## Usage

### 1. Download the tool and video assets
```bash
sima-cli install gh:sima-ai/tool-mediasources
```

### 2. Dependencies

- FFmpeg → Installed automatically if missing (apt-get, yum, or brew).
- MediaMTX → Downloaded and installed automatically from GitHub releases.
- Bash ≥ 4.0

### 3. Supported platforms:

- Linux (Debian/Ubuntu, CentOS/RHEL)
- macOS (via Homebrew)
- Windows (manual install of FFmpeg, MediaMTX required)

### 4. Run with a media folder

```bash
./mediasrc.sh ../videos-480p30
```

> [!IMPORTANT]
> On Windows, open Powershell and run:

```powershell
mediasrc.bat ..\videos-480p30
```


The folder should contain one or more .mp4 files.
Each file will be exposed as its own RTSP stream.

The launcher runs in foreground mode and uses a WebRTC-compatible H.264 profile
(no B-frames) so streams can be viewed in `preview.html`.

Press `Ctrl+C` to stop all launched stream publishers:

```bash
./mediasrc.sh ../videos-480p30
```

To force passthrough mode (`-c:v copy`), disable compatibility mode:

```bash
WEBRTC_COMPAT=0 ./mediasrc.sh ../videos-480p30
```

### 5. Preview the streams

```bash
open preview.html
```

`mediasrc.sh` automatically writes `preview-config.js` so `preview.html`
uses the detected number of input videos.


## UDP Preview Relay

`mediasrc-udp.sh` is a companion launcher for live publishers that already emit
H.264 over RTP/UDP. It creates one MediaMTX relay per UDP input port and writes
`preview-udp-config.js` so the browser grid can open the matching WebRTC paths.
The UDP launcher expects `ffmpeg` and `mediamtx` to already be available in
`PATH`.

### Start UDP relays

```bash
./mediasrc-udp.sh --streams 4 --port-base 5600
```

This reserves the following inputs by default:

- UDP `5600` -> RTSP/WebRTC path `/udp0`
- UDP `5602` -> RTSP/WebRTC path `/udp1`
- UDP `5604` -> RTSP/WebRTC path `/udp2`
- UDP `5606` -> RTSP/WebRTC path `/udp3`

`--port-base` must be even. Each relay reserves an RTP/RTCP port pair, so the
odd port beside each listed RTP port is left available for RTCP.

Generated SDP files and relay logs are written under `.mediasrc-udp/`.

### Preview the UDP-backed streams

```bash
open preview-udp.html
```

### Dry-run the setup

```bash
./mediasrc-udp.sh --streams 4 --port-base 5600 --dry-run
```

Dry-run mode writes the runtime config and SDP files without starting MediaMTX
or FFmpeg relay processes.

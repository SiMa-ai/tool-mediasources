# Multi-Stream RTSP Launcher

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS%20%7C%20Windows-red?style=flat-square&logo=linux)]()


## Overview

The **Multi-Stream RTSP Launcher** is a Bash tool designed to quickly stand up an [MediaMTX](https://github.com/bluenviron/mediamtx) RTSP server and stream multiple video files over RTSP using [FFmpeg](https://ffmpeg.org).  

It automatically:  
- Installs **FFmpeg** and **MediaMTX** if not already available.  
- Starts a local RTSP server (`rtsp://<local-ip>:8554/`).  
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

### 5. Preview the streams

```bash
open preview.html
```
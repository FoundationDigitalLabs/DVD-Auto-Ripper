# 📀 DVD Auto-Ripper

A fully automated DVD ripping pipeline powered by [MakeMKV](https://www.makemkv.com/). Insert a disc, walk away — the script detects it, rips it, renames the output to a clean Title Case filename, organizes multi-part discs, and ejects the tray when it's done.

## ✨ Features

| Feature | Description |
|---|---|
| **Auto-Detection** | Dynamically finds any connected optical drive (USB or SATA) — no need to hardcode `/dev/sr0` |
| **Live Dashboard** | Real-time terminal UI showing current status, progress bar, success/fail counters, and errors |
| **Progress Bar** | Parses MakeMKV's robot-mode output to display `[########-------] 55%` during rips |
| **Smart Naming** | Converts raw disc labels like `THE_DARK_KNIGHT` → `The Dark Knight.mkv` |
| **Multi-Part Support** | Discs with multiple titles are automatically numbered `_Part01`, `_Part02`, etc. |
| **Disk Space Check** | Refuses to start a rip if less than 10 GB is available, preventing partial rips |
| **Auto-Eject** | Pops the tray open after every rip (success or failure) so you can swap discs |
| **Per-Disc Logging** | Each rip generates its own log file for easy troubleshooting |

---

## 📋 Prerequisites

### 1. MakeMKV

MakeMKV must be installed and `makemkvcon` must be available in your system PATH.

**Install on Ubuntu/Debian:**
```bash
sudo apt install makemkv-bin makemkv-oss
```

**Verify installation:**
```bash
makemkvcon --help
```

> **Note:** MakeMKV requires a license key. A free beta key is available at [makemkv.com/forum](https://www.makemkv.com/forum/viewtopic.php?f=5&t=1053) and must be entered in the MakeMKV GUI or written to `~/.MakeMKV/settings.conf`.

### 2. System Utilities

These are typically pre-installed on most Linux distributions:

```bash
# Verify all dependencies are present
which lsblk eject tput blockdev df
```

| Tool | Purpose |
|---|---|
| `lsblk` | Detects optical drives and reads disc labels |
| `eject` | Opens the disc tray after ripping |
| `tput` | Controls terminal output for the dashboard (part of `ncurses`) |
| `blockdev` | Checks if a disc is physically present in the drive |
| `df` | Checks available disk space before ripping |

### 3. Hardware

- An optical DVD/Blu-ray drive (internal SATA or external USB)
- The drive must be recognized by the system as a `rom` type device in `lsblk`

---

## ⚙️ Configuration

All settings are stored in `config.env`. This file **must exist** in the same directory as the script.

### `config.env`

```bash
# Root directory where all rip data is stored
DRIVE_ROOT="/media/jake/Backups"

# Final destination for completed .mkv files
DEST_FOLDER="$DRIVE_ROOT/MakeMKV"

# Temporary working directory (cleaned up automatically after each rip)
BASE_TEMP="$DRIVE_ROOT/temp_rip_work"

# Minimum title length in seconds. Titles shorter than this are skipped.
# Examples: 900 = 15 min, 1800 = 30 min, 3600 = 60 min
MIN_LENGTH=900
```

| Variable | Default | Description |
|---|---|---|
| `DRIVE_ROOT` | `/media/jake/Backups` | Root path for all rip-related storage |
| `DEST_FOLDER` | `$DRIVE_ROOT/MakeMKV` | Where finished `.mkv` files are saved |
| `BASE_TEMP` | `$DRIVE_ROOT/temp_rip_work` | Temporary directory during active rips (auto-cleaned) |
| `MIN_LENGTH` | `900` | Minimum title length in seconds to include in the rip |

---

## 🚀 Setup & Usage

### Step 1: Clone or Download

```bash
git clone https://github.com/your-repo/DVD-Auto-Ripper.git
cd DVD-Auto-Ripper
```

### Step 2: Make Executable

```bash
chmod +x auto_rip.sh
```

### Step 3: Configure Paths

Edit `config.env` to match your system:

```bash
nano config.env
```

Make sure the `DRIVE_ROOT` path exists and has sufficient storage space.

### Step 4: Run

```bash
./auto_rip.sh
```

The dashboard will appear immediately. Insert a DVD and the script will take it from there.

### Step 5: Stop

Press `Ctrl+C` at any time to stop the script. If a rip is in progress, MakeMKV will be interrupted and the temp directory for that disc will remain (it will be cleaned up automatically on the next run for the same disc).

---

## 🖥️ Dashboard

When running, the terminal displays a live dashboard:

```
================================================
 📀 DVD AUTO-RIPPER DASHBOARD
================================================
 Status:       Ripping: The Dark Knight [########-------] 55%
 Last Activity: 14:32:07
------------------------------------------------
 📊 STATS: Success: 3 | Fail: 0
 ⚠️  Last Error: None
================================================

 💿 New Disc Detected: The Dark Knight
 ⏳ Ripping in background... Please wait.
```

### Status Messages

| Status | Meaning |
|---|---|
| `Waiting for disc...` | Idle — polling the drive every 10 seconds |
| `Detecting: LABEL` | A new disc label was found, cleaning the name |
| `Ripping: Name [Starting...]` | MakeMKV has launched, waiting for first progress update |
| `Ripping: Name [####...] XX%` | Actively ripping with real-time progress |

---

## 📁 Output Structure

```
/media/jake/Backups/
├── MakeMKV/                        # Finished rips
│   ├── The Dark Knight.mkv         # Single-title disc
│   ├── Persuasion_Part01.mkv       # Multi-title disc
│   └── Persuasion_Part02.mkv
└── temp_rip_work/                  # Working directory
    └── logs/                       # Per-disc log files
        ├── rip_The Dark Knight.log
        └── rip_Persuasion.log
```

---

## 🔧 Troubleshooting

### No MKV files were produced
- Check the log file in `$BASE_TEMP/logs/` for details
- This usually means no titles on the disc met the `MIN_LENGTH` threshold
- Try lowering `MIN_LENGTH` in `config.env` (e.g., from `900` to `300`)

### Drive not detected
- Verify the drive is recognized: `lsblk -d -o NAME,TYPE | grep rom`
- If using USB, try unplugging and re-plugging the drive
- The script will automatically recover once the drive reappears

### "Disk full" error
- The script requires at least **10 GB** of free space on `$DRIVE_ROOT`
- Free up space or change `DRIVE_ROOT` to a different volume

### Progress bar stuck on "Starting..."
- The `--progress=-stdout` flag is required for MakeMKV to output progress data
- Verify your MakeMKV version supports this flag: `makemkvcon --help`

### Parts are numbered in the wrong order
- The script sorts multi-title output by file modification time (oldest first)
- This matches the order MakeMKV ripped them, which corresponds to the disc's playback order

---

## 📝 License

This project is provided as-is for personal use. MakeMKV has its own licensing terms — please refer to [makemkv.com](https://www.makemkv.com/) for details.

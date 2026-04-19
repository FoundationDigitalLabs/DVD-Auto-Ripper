#!/bin/bash
# =============================================================================
#  DVD Auto-Ripper
#  Automatically detects, rips, renames, and organizes DVDs using MakeMKV.
#
#  Features:
#    - Auto-detects optical drives (USB or SATA) via lsblk
#    - Real-time terminal dashboard with live progress bar
#    - Disc label → Title Case filename conversion
#    - Multi-part DVD support (auto-numbered _Part01, _Part02, etc.)
#    - Disk space safety check before each rip
#    - Auto-eject on completion or failure
#    - Per-disc log files for troubleshooting
#
#  Dependencies: makemkvcon, lsblk, eject, tput
#  Config:       config.env (must exist in the same directory)
#
#  Usage:        ./auto_rip.sh
#                (Insert a DVD and the script does the rest)
# =============================================================================

# ---------------------
# 1. LOAD CONFIGURATION
# ---------------------
# All user-configurable paths and settings live in config.env.
# The script will not run without it.
if [ -f "config.env" ]; then
    source config.env
else
    echo "❌ Error: config.env file not found. Please create it."
    exit 1
fi

# ---------------------
# 2. PATH SETUP
# ---------------------
# Defaults are provided in case config.env omits a value.
DRIVE_ROOT="${DRIVE_ROOT:-/media/jake/Backups}"
DEST_FOLDER="${DEST_FOLDER:-$DRIVE_ROOT/MakeMKV}"
BASE_TEMP="${BASE_TEMP:-$DRIVE_ROOT/temp_rip_work}"
LOG_DIR="$BASE_TEMP/logs"

# Track which disc was last processed to avoid re-ripping the same disc
LAST_DISC=""

# ---------------------
# 3. DASHBOARD STATE
# ---------------------
TOTAL_SUCCESSES=0
TOTAL_FAILURES=0
LAST_ACTIVITY="None"
LAST_ERROR="None"
CURRENT_STATUS="Waiting for disc..."

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# ---------------------
# 4. DASHBOARD RENDERER
# ---------------------
# Uses tput to overwrite the same terminal lines in place.
# $(tput el) clears leftover characters when the new text is shorter
# than what was previously displayed on that line.
draw_dashboard() {
    tput cup 0 0
    echo "================================================"
    echo " 📀 DVD AUTO-RIPPER DASHBOARD"
    echo "================================================"
    echo " Status:       $CURRENT_STATUS$(tput el)"
    echo " Last Activity: $LAST_ACTIVITY$(tput el)"
    echo "------------------------------------------------"
    echo " 📊 STATS: Success: $TOTAL_SUCCESSES | Fail: $TOTAL_FAILURES$(tput el)"
    echo " ⚠️  Last Error: $LAST_ERROR$(tput el)"
    echo "================================================"
    echo ""
    tput ed
}

# Initialize the terminal
# Hide the cursor so it doesn't visibly bounce during dashboard redraws.
# The trap ensures the cursor is always restored on exit (Ctrl+C, kill, etc.)
tput civis
trap 'tput cnorm; exit' EXIT INT TERM
clear
draw_dashboard

# =============================================================================
# MAIN LOOP — Polls for new discs every 10 seconds
# =============================================================================
while true; do

    # -------------------------------------------------------------------------
    # STEP 0: AUTO-DETECT DRIVE
    # -------------------------------------------------------------------------
    # Dynamically finds the first optical drive (type "rom") via lsblk.
    # This allows hot-plugging USB DVD drives without hardcoding /dev/sr0.
    DRIVE_PATH="/dev/$(lsblk -d -n -o NAME,TYPE | awk '$2=="rom" {print $1}' | head -n 1)"

    # If no drive is found (e.g., USB drive unplugged), wait and retry
    if [ "$DRIVE_PATH" == "/dev/" ]; then
        sleep 5
        continue
    fi

    # -------------------------------------------------------------------------
    # STEP 1: CHECK FOR A DISC
    # -------------------------------------------------------------------------
    # Read the disc's volume label. Strip newlines, carriage returns, and
    # any non-printable characters that some DVDs embed in their labels.
    RAW_NAME=$(lsblk -n -o LABEL "$DRIVE_PATH" 2>/dev/null | tr -d '\n\r' | sed 's/[^[:print:]]//g')

    # -------------------------------------------------------------------------
    # STEP 2: NEW DISC DETECTED?
    # -------------------------------------------------------------------------
    # Only proceed if a label exists AND it's different from the last disc.
    # This prevents re-ripping the same disc if it's still in the tray.
    if [ -n "$RAW_NAME" ] && [ "$RAW_NAME" != "$LAST_DISC" ]; then
        
        CURRENT_STATUS="Detecting: $RAW_NAME"
        draw_dashboard
        
        # --- Name Cleaning ---
        # 1. Replace underscores with spaces
        # 2. Strip any characters that aren't alphanumeric or spaces
        # 3. Convert to Title Case (e.g., "THE DARK KNIGHT" → "The Dark Knight")
        CLEAN_NAME=$(echo "$RAW_NAME" | tr '_' ' ' | sed 's/[^a-zA-Z0-9 ]//g')
        CLEAN_NAME=$(echo "$CLEAN_NAME" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')
        
        # ---------------------------------------------------------------------
        # STEP 2.5: DISK SPACE SAFETY CHECK
        # ---------------------------------------------------------------------
        # A typical DVD rip uses 4-8 GB. Abort if less than 10 GB is available
        # to prevent partial rips and system instability from a full disk.
        FREE_SPACE_GB=$(df -BG "$DRIVE_ROOT" | awk 'NR==2 {print $4}' | tr -d 'G')
        if [ "$FREE_SPACE_GB" -lt "${MIN_SPACE_GB:-10}" ]; then
            echo " ❌ Error: Not enough space on $DRIVE_ROOT (${FREE_SPACE_GB}GB free)."
            LAST_ERROR="Disk full (${FREE_SPACE_GB}GB free)"
            CURRENT_STATUS="Waiting for disc..."
            draw_dashboard
            LAST_DISC="$RAW_NAME"
            eject "$DRIVE_PATH"
            continue
        fi

        echo " 💿 New Disc Detected: $CLEAN_NAME"
        echo " ⏳ Ripping in background... Please wait."

        # --- Prepare temp working directory and log file ---
        TEMP_DIR="$BASE_TEMP/temp_$CLEAN_NAME"
        LOG_FILE="$LOG_DIR/rip_$CLEAN_NAME.log"
        rm -rf "$TEMP_DIR" 
        mkdir -p "$TEMP_DIR"
        
        # ---------------------------------------------------------------------
        # STEP 3: RIP THE DISC WITH LIVE PROGRESS
        # ---------------------------------------------------------------------
        # MakeMKV is run in --robot mode for machine-parsable output.
        # --progress=-stdout is REQUIRED to get PRGV progress lines;
        # without it, robot mode only emits MSG: and DRV: lines.
        #
        # Output is piped (not redirected to a file) because MakeMKV
        # flushes line-by-line to pipes but block-buffers to files.
        # Each line is simultaneously written to the log and parsed for
        # PRGV progress updates.
        #
        # PRGV format: PRGV:current,total,max
        #   - current = progress of the current title being ripped
        #   - total   = overall progress across all titles
        #   - max     = constant (65536), used as the denominator
        #   - Overall percentage = total * 100 / max
        CURRENT_STATUS="Ripping: $CLEAN_NAME [Starting...]"
        draw_dashboard
        echo "--- Rip Started: $(date) ---" > "$LOG_FILE"
        
        makemkvcon --robot --progress=-stdout --minlength="$MIN_LENGTH" mkv dev:"$DRIVE_PATH" all "$TEMP_DIR" 2>&1 | while IFS= read -r line; do
            echo "$line" >> "$LOG_FILE"
            if [[ "$line" == PRGV:* ]]; then
                IFS=',:' read -r _ CURRENT_VAL TOTAL_VAL MAX_VAL <<< "$line"
                if [ -n "$MAX_VAL" ] && [ "$MAX_VAL" -gt 0 ] 2>/dev/null; then
                    PERCENT=$(( TOTAL_VAL * 100 / MAX_VAL ))
                    BAR_LENGTH=15
                    FILLED=$(( PERCENT * BAR_LENGTH / 100 ))
                    EMPTY=$(( BAR_LENGTH - FILLED ))
                    BAR=$(printf "%${FILLED}s" | tr ' ' '#')
                    BAR="${BAR}$(printf "%${EMPTY}s" | tr ' ' '-')"
                    CURRENT_STATUS="Ripping: $CLEAN_NAME [${BAR}] ${PERCENT}%"
                    draw_dashboard
                fi
            fi
        done
        
        # ---------------------------------------------------------------------
        # STEP 4: MOVE, RENAME, AND ORGANIZE
        # ---------------------------------------------------------------------
        FILE_COUNT=$(ls -1 "$TEMP_DIR"/*.mkv 2>/dev/null | wc -l)
        
        if [ "$FILE_COUNT" -eq 1 ]; then
            # --- Single title: rename directly ---
            mkdir -p "$DEST_FOLDER"
            mv "$TEMP_DIR"/*.mkv "$DEST_FOLDER/$CLEAN_NAME.mkv"
            echo " ✅ Success! Saved $CLEAN_NAME.mkv"
            
            TOTAL_SUCCESSES=$((TOTAL_SUCCESSES + 1))
            LAST_ACTIVITY=$(date +"%H:%M:%S")
            LAST_ERROR="None"
            CURRENT_STATUS="Waiting for disc..."
            draw_dashboard
            
        elif [ "$FILE_COUNT" -gt 1 ]; then
            # --- Multiple titles: append _Part01, _Part02, etc. ---
            # Files are sorted by modification time (oldest first) so that
            # part numbers match the order MakeMKV ripped them, regardless
            # of what filenames MakeMKV chose (e.g., title.mkv, 01.mkv).
            mkdir -p "$DEST_FOLDER"
            COUNTER=1
            ls -1tr "$TEMP_DIR"/*.mkv 2>/dev/null | while IFS= read -r f; do
                printf -v PART_NUM "%02d" "$COUNTER"
                mv "$f" "$DEST_FOLDER/${CLEAN_NAME}_Part${PART_NUM}.mkv"
                ((COUNTER++))
            done
            echo " ✅ Success! Saved $FILE_COUNT files for $CLEAN_NAME"
            
            TOTAL_SUCCESSES=$((TOTAL_SUCCESSES + 1))
            LAST_ACTIVITY=$(date +"%H:%M:%S")
            LAST_ERROR="None"
            CURRENT_STATUS="Waiting for disc..."
            draw_dashboard
            
        else
            # --- No MKV files produced ---
            # This usually means no titles met the MIN_LENGTH threshold.
            # Check the log file in $LOG_DIR for details.
            echo " ❌ Error: No MKV files over ${MIN_LENGTH:-0} seconds were found."
            
            TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
            LAST_ACTIVITY=$(date +"%H:%M:%S")
            LAST_ERROR="No MKV found for $CLEAN_NAME"
            CURRENT_STATUS="Waiting for disc..."
            draw_dashboard
        fi

        # --- Cleanup temp directory ---
        rm -rf "$TEMP_DIR" 2>/dev/null

        # ---------------------------------------------------------------------
        # STEP 5: MARK DISC AS DONE
        # ---------------------------------------------------------------------
        LAST_DISC="$RAW_NAME"

        # ---------------------------------------------------------------------
        # STEP 6: EJECT THE TRAY
        # ---------------------------------------------------------------------
        echo " ⏏️ Ejecting tray..."
        eject "$DRIVE_PATH"
        echo "----------------------------------------"
        echo " 👀 Waiting for the next disc..."
    fi

    # -------------------------------------------------------------------------
    # STEP 7: HARDWARE-LEVEL RESET
    # -------------------------------------------------------------------------
    # When the tray is empty or open, blockdev returns size 0.
    # Reset LAST_DISC so the same disc can be re-ripped if reinserted.
    DRIVE_SIZE=$(blockdev --getsize64 "$DRIVE_PATH" 2>/dev/null)
    
    if [ "$DRIVE_SIZE" == "0" ] || [ -z "$DRIVE_SIZE" ]; then
        LAST_DISC=""
    fi

    sleep 10
done

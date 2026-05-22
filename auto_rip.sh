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
#  Dependencies: makemkvcon, lsblk, eject, tput, findmnt
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
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
else
    echo "❌ Error: config.env file not found at $CONFIG_FILE. Please create it."
    exit 1
fi

# ---------------------
# 2. PATH SETUP
# ---------------------
# Defaults are provided in case config.env omits a value.
DEFAULT_DRIVE_ROOT="${HOME:-$SCRIPT_DIR}/Desktop/DVD-Rips"
DRIVE_ROOT="${DRIVE_ROOT:-$DEFAULT_DRIVE_ROOT}"
DEST_FOLDER="${DEST_FOLDER:-$DRIVE_ROOT/MakeMKV}"
BASE_TEMP="${BASE_TEMP:-$DRIVE_ROOT/temp_rip_work}"
LOG_DIR="$BASE_TEMP/logs"
MIN_LENGTH="${MIN_LENGTH:-900}"
MIN_SPACE_GB="${MIN_SPACE_GB:-10}"

fatal_error() {
    echo "❌ Error: $1"
    exit 1
}

ensure_directory() {
    local dir="$1"
    mkdir -p "$dir" || fatal_error "Could not create directory: $dir"
}

validate_storage_root() {
    if [ ! -d "$DRIVE_ROOT" ]; then
        fatal_error "DRIVE_ROOT does not exist: $DRIVE_ROOT"
    fi

    if [ ! -w "$DRIVE_ROOT" ]; then
        fatal_error "DRIVE_ROOT is not writable: $DRIVE_ROOT"
    fi

    if [[ "$DRIVE_ROOT" == /media/* || "$DRIVE_ROOT" == /mnt/* ]]; then
        if command -v findmnt >/dev/null 2>&1; then
            local mount_target
            mount_target=$(findmnt -n -T "$DRIVE_ROOT" -o TARGET 2>/dev/null | head -n 1)

            if [ -z "$mount_target" ] || [ "$mount_target" = "/" ]; then
                if [ "${ALLOW_UNMOUNTED_DRIVE_ROOT:-0}" != "1" ]; then
                    fatal_error "$DRIVE_ROOT appears to be under /media or /mnt but is not mounted. Set ALLOW_UNMOUNTED_DRIVE_ROOT=1 only if this is intentional."
                fi
            fi
        else
            fatal_error "findmnt is required to validate DRIVE_ROOT paths under /media or /mnt."
        fi
    fi
}

validate_numeric_config() {
    if ! [[ "$MIN_LENGTH" =~ ^[0-9]+$ ]]; then
        fatal_error "MIN_LENGTH must be a whole number of seconds."
    fi

    if ! [[ "$MIN_SPACE_GB" =~ ^[0-9]+$ ]]; then
        fatal_error "MIN_SPACE_GB must be a whole number of GB."
    fi
}

clean_disc_name() {
    local raw_name="$1"
    local clean_name

    clean_name=$(echo "$raw_name" | tr '_' ' ' | sed 's/[^a-zA-Z0-9 ]//g')
    clean_name=$(echo "$clean_name" | awk '{
        out=""
        for (i=1; i<=NF; i++) {
            word=toupper(substr($i,1,1)) tolower(substr($i,2))
            out=(out == "" ? word : out " " word)
        }
        print out
    }')
    echo "$clean_name"
}

fallback_disc_name() {
    date +"Untitled_Disc_%Y%m%d_%H%M%S"
}

destination_exists_for_name() {
    local clean_name="$1"

    [ -e "$DEST_FOLDER/$clean_name.mkv" ] && return 0
    compgen -G "$DEST_FOLDER/${clean_name}_Part*.mkv" >/dev/null && return 0

    return 1
}

get_free_space_gb() {
    df -P -BG "$DRIVE_ROOT" 2>/dev/null | awk 'NR==2 {gsub(/G/, "", $4); print $4}'
}

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
validate_numeric_config
validate_storage_root
ensure_directory "$LOG_DIR"

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

record_success() {
    TOTAL_SUCCESSES=$((TOTAL_SUCCESSES + 1))
    LAST_ACTIVITY=$(date +"%H:%M:%S")
    LAST_ERROR="None"
    CURRENT_STATUS="Waiting for disc..."
    draw_dashboard
}

record_failure() {
    local message="$1"

    TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
    LAST_ACTIVITY=$(date +"%H:%M:%S")
    LAST_ERROR="$message"
    CURRENT_STATUS="Waiting for disc..."
    draw_dashboard
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
    # When the tray is empty or open, blockdev returns size 0.
    # Reset LAST_DISC so the same disc can be re-ripped if reinserted.
    DRIVE_SIZE=$(blockdev --getsize64 "$DRIVE_PATH" 2>/dev/null)

    if [ "$DRIVE_SIZE" == "0" ] || [ -z "$DRIVE_SIZE" ]; then
        LAST_DISC=""
        sleep 10
        continue
    fi

    # Read the disc's volume label. Strip newlines, carriage returns, and
    # any non-printable characters that some DVDs embed in their labels.
    RAW_NAME=$(lsblk -n -o LABEL "$DRIVE_PATH" 2>/dev/null | tr -d '\n\r' | sed 's/[^[:print:]]//g')
    DISC_KEY="${RAW_NAME:-unlabeled:$DRIVE_PATH:$DRIVE_SIZE}"
    DISPLAY_NAME="${RAW_NAME:-Unlabeled disc}"

    # -------------------------------------------------------------------------
    # STEP 2: NEW DISC DETECTED?
    # -------------------------------------------------------------------------
    # Only proceed if the current disc differs from the last disc.
    # This prevents re-ripping the same disc if it's still in the tray.
    if [ "$DISC_KEY" != "$LAST_DISC" ]; then
        
        CURRENT_STATUS="Detecting: $DISPLAY_NAME"
        draw_dashboard
        
        # --- Name Cleaning ---
        # 1. Replace underscores with spaces
        # 2. Strip any characters that aren't alphanumeric or spaces
        # 3. Convert to Title Case (e.g., "THE DARK KNIGHT" → "The Dark Knight")
        # 4. Fall back to a timestamped name when a disc has no usable label.
        CLEAN_NAME=$(clean_disc_name "$RAW_NAME")
        if [ -z "$CLEAN_NAME" ]; then
            CLEAN_NAME=$(fallback_disc_name)
        fi
        
        # ---------------------------------------------------------------------
        # STEP 2.5: DISK SPACE SAFETY CHECK
        # ---------------------------------------------------------------------
        # A typical DVD rip uses 4-8 GB. Abort if less than 10 GB is available
        # to prevent partial rips and system instability from a full disk.
        FREE_SPACE_GB=$(get_free_space_gb)
        if ! [[ "$FREE_SPACE_GB" =~ ^[0-9]+$ ]]; then
            echo " ❌ Error: Could not determine free space on $DRIVE_ROOT."
            record_failure "Free space check failed"
            LAST_DISC="$DISC_KEY"
            eject "$DRIVE_PATH"
            continue
        fi

        if [ "$FREE_SPACE_GB" -lt "$MIN_SPACE_GB" ]; then
            echo " ❌ Error: Not enough space on $DRIVE_ROOT (${FREE_SPACE_GB}GB free)."
            record_failure "Disk full (${FREE_SPACE_GB}GB free)"
            LAST_DISC="$DISC_KEY"
            eject "$DRIVE_PATH"
            continue
        fi

        ensure_directory "$DEST_FOLDER"
        if destination_exists_for_name "$CLEAN_NAME"; then
            echo " ❌ Error: Destination already contains files for $CLEAN_NAME. Refusing to overwrite."
            record_failure "Output exists for $CLEAN_NAME"
            LAST_DISC="$DISC_KEY"
            eject "$DRIVE_PATH"
            continue
        fi

        echo " 💿 New Disc Detected: $CLEAN_NAME"
        echo " ⏳ Ripping in background... Please wait."

        # --- Prepare temp working directory and log file ---
        TEMP_DIR="$BASE_TEMP/temp_$CLEAN_NAME"
        LOG_FILE="$LOG_DIR/rip_$CLEAN_NAME.log"
        KEEP_TEMP_DIR=0

        ensure_directory "$BASE_TEMP"
        rm -rf -- "$TEMP_DIR"
        ensure_directory "$TEMP_DIR"
        
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
        MAKEMKV_STATUS=${PIPESTATUS[0]}
        echo "--- Rip Finished: $(date) (makemkvcon exit: $MAKEMKV_STATUS) ---" >> "$LOG_FILE"
        
        # ---------------------------------------------------------------------
        # STEP 4: MOVE, RENAME, AND ORGANIZE
        # ---------------------------------------------------------------------
        mapfile -t MKV_FILES < <(find "$TEMP_DIR" -maxdepth 1 -type f -name "*.mkv" -printf "%T@ %p\n" 2>/dev/null | sort -n | sed 's/^[^ ]* //')
        FILE_COUNT=${#MKV_FILES[@]}
        
        if [ "$MAKEMKV_STATUS" -ne 0 ]; then
            echo " ❌ Error: MakeMKV failed with exit code $MAKEMKV_STATUS. See $LOG_FILE."
            if [ "$FILE_COUNT" -gt 0 ]; then
                KEEP_TEMP_DIR=1
            fi
            record_failure "MakeMKV failed ($MAKEMKV_STATUS)"

        elif [ "$FILE_COUNT" -eq 1 ]; then
            # --- Single title: rename directly ---
            DEST_FILE="$DEST_FOLDER/$CLEAN_NAME.mkv"

            if [ -e "$DEST_FILE" ]; then
                echo " ❌ Error: Destination already exists: $DEST_FILE"
                KEEP_TEMP_DIR=1
                record_failure "Output exists for $CLEAN_NAME"
            elif mv -- "${MKV_FILES[0]}" "$DEST_FILE"; then
                echo " ✅ Success! Saved $CLEAN_NAME.mkv"
                record_success
            else
                echo " ❌ Error: Failed to move rip to $DEST_FILE"
                KEEP_TEMP_DIR=1
                record_failure "Move failed for $CLEAN_NAME"
            fi
            
        elif [ "$FILE_COUNT" -gt 1 ]; then
            # --- Multiple titles: append _Part01, _Part02, etc. ---
            # Files are sorted by modification time (oldest first) so that
            # part numbers match the order MakeMKV ripped them, regardless
            # of what filenames MakeMKV chose (e.g., title.mkv, 01.mkv).
            COLLISION_FOUND=0
            MOVE_FAILED=0
            
            for i in "${!MKV_FILES[@]}"; do
                printf -v PART_NUM "%02d" "$((i + 1))"
                DEST_FILE="$DEST_FOLDER/${CLEAN_NAME}_Part${PART_NUM}.mkv"

                if [ -e "$DEST_FILE" ]; then
                    COLLISION_FOUND=1
                    break
                fi
            done

            if [ "$COLLISION_FOUND" -eq 1 ]; then
                echo " ❌ Error: Destination already contains a part file for $CLEAN_NAME. Refusing to overwrite."
                KEEP_TEMP_DIR=1
                record_failure "Output exists for $CLEAN_NAME"
            else
                for i in "${!MKV_FILES[@]}"; do
                    printf -v PART_NUM "%02d" "$((i + 1))"
                    DEST_FILE="$DEST_FOLDER/${CLEAN_NAME}_Part${PART_NUM}.mkv"

                    if ! mv -- "${MKV_FILES[$i]}" "$DEST_FILE"; then
                        MOVE_FAILED=1
                        break
                    fi
                done

                if [ "$MOVE_FAILED" -eq 1 ]; then
                    echo " ❌ Error: Failed to move all files for $CLEAN_NAME."
                    KEEP_TEMP_DIR=1
                    record_failure "Move failed for $CLEAN_NAME"
                else
                    echo " ✅ Success! Saved $FILE_COUNT files for $CLEAN_NAME"
                    record_success
                fi
            fi
            
        else
            # --- No MKV files produced ---
            # This usually means no titles met the MIN_LENGTH threshold.
            # Check the log file in $LOG_DIR for details.
            echo " ❌ Error: No MKV files over $MIN_LENGTH seconds were found."
            record_failure "No MKV found for $CLEAN_NAME"
        fi

        # --- Cleanup temp directory ---
        if [ "$KEEP_TEMP_DIR" -eq 1 ]; then
            echo " ⚠️  Temp files left for inspection: $TEMP_DIR"
        else
            rm -rf -- "$TEMP_DIR" 2>/dev/null
        fi

        # ---------------------------------------------------------------------
        # STEP 5: MARK DISC AS DONE
        # ---------------------------------------------------------------------
        LAST_DISC="$DISC_KEY"

        # ---------------------------------------------------------------------
        # STEP 6: EJECT THE TRAY
        # ---------------------------------------------------------------------
        echo " ⏏️ Ejecting tray..."
        eject "$DRIVE_PATH"
        echo "----------------------------------------"
        echo " 👀 Waiting for the next disc..."
    fi

    sleep 10
done

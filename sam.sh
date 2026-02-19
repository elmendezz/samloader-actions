#!/bin/bash

# --- Configuration and Setup ---
export WDIR
WDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load color definitions, exit if they're missing.
if [ -f "$WDIR/tools/colors" ]; then
    source "$WDIR/tools/colors"
    source "$WDIR/tools/gofile.sh"
else
    echo "Error: Color definitions not found at '$WDIR/tools/colors'." >&2
    exit 1
fi


# --- Helper Functions for Colored Output ---
red() { echo -e "${RED}$1${RESET}"; }
yellow() { echo -e "${LIGHT_YELLOW}$1${RESET}"; }
green() { echo -e "${MINT_GREEN}$1${RESET}"; }
blue() { echo -e "${BLUE}$1${RESET}"; }


# --- Script Functions ---

# Display usage information
usage() {
    echo ""
    echo "$(yellow "Usage:") ./sam.sh [mode_options]"
    echo ""
    echo "$(blue "Mode 1: Direct Download")"
    echo "  Downloads firmware from a provided URL."
    echo "  $(yellow "Required:") --url <link> --model <model>"
    echo ""
    echo "$(blue "Mode 2: Samloader Download")"
    echo "  Finds and downloads firmware using device-specific info."
    echo "  $(yellow "Required:") --model <model> --imei <imei> --csc <csc>"
    echo ""
    echo "$(yellow "General Options:")"
    echo "  --help           Show this help message"
    echo ""
    echo "$(yellow "Examples:")"
    echo "  ./sam.sh --url \"https://example.com/firmware.zip\" --model \"SM-G998B\""
    echo "  ./sam.sh --model \"SM-G998B\" --imei \"123456789012345\" --csc \"XAA\""
}

# Parse all command-line arguments into global variables
parse_args() {
    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
            --url=*)
                URL="${key#*=}"
                shift # past argument=value
                ;;
            --model=*)
                MODEL="${key#*=}"
                shift # past argument=value
                ;;
            --imei=*)
                IMEI="${key#*=}"
                shift # past argument=value
                ;;
            --csc=*)
                CSC="${key#*=}"
                shift # past argument=value
                ;;
            --url|--model|--imei|--csc)
                if [[ -z "$2" || "$2" =~ ^-- ]]; then
                    red "Error: Argument for $1 is missing." >&2
                    usage >&2
                    exit 1
                fi
                case $key in
                    --url) URL="$2" ;;
                    --model) MODEL="$2" ;;
                    --imei) IMEI="$2" ;;
                    --csc) CSC="$2" ;;
                esac
                shift # past argument
                shift # past value
                ;;
            --help)
                usage
                exit 0
                ;;
            *)  # unknown option
                red "Error: Unknown option '$1'." >&2
                usage >&2
                exit 1
                ;;
        esac
    done
}

# Validate that the correct arguments were provided for the chosen mode
validate_args() {
    if [[ -n "$URL" ]]; then
        # Direct Download Mode
        MODE="direct"
        if [[ -z "$MODEL" ]]; then
            red "Error: Direct download mode requires --model." >&2; usage >&2; exit 1
        fi
        if [[ -n "$IMEI" || -n "$CSC" ]]; then
            red "Error: --imei and --csc cannot be used with --url." >&2; usage >&2; exit 1
        fi
    elif [[ -n "$MODEL" ]]; then
        # Samloader Mode
        MODE="samloader"
        if [[ -z "$IMEI" || -z "$CSC" ]]; then
            red "Error: Samloader mode requires --model, --imei, and --csc." >&2; usage >&2; exit 1
        fi
    else
        # No mode could be determined
        red "Error: Invalid combination of arguments." >&2
        yellow "Please specify arguments for either Direct or Samloader mode." >&2
        usage >&2
        exit 1
    fi
}

# Initialize git submodules with clear error handling
init_submodules() {
    if [ ! -f "$WDIR/lptools/lpunpack" ]; then
        green "Initializing required Git submodules..."
        if ! git submodule update --init --recursive; then
            red "Error: Failed to initialize Git submodules." >&2
            yellow "Please check your Git configuration and network connection." >&2
            exit 1
        fi
    fi
}

# Check for and install required system packages only if they are missing
install_dependencies() {
    local packages="android-sdk-libsparse-utils lz4 openssl python3 python3-pip"
    local to_install=""
    
    # Silently check for missing packages first
    for pkg in $packages; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            to_install="$to_install $pkg"
        fi
    done

    # Only if packages are missing, print messages and install them
    if [ -n "$to_install" ]; then
        echo -e "\n\t$(yellow "Installing missing packages:$to_install")"
        if ! (sudo apt-get update -y && sudo apt-get install -y$to_install > /dev/null 2>&1); then
            red "Error: Failed to install required packages. Please run the command manually." >&2
            exit 1
        fi
        green "[+] Requirements installed successfully."
    fi
}

# Execute the download from a direct link
run_direct_download() {
    green "Direct Download Mode Selected"
    echo -e "====================================\n"
    echo -e "$(yellow "[+] Model:") ${MODEL}"
    echo -e "$(yellow "[+] URL:")   ${URL}\n"
    echo -e "====================================\n"

    green "Attempting to download firmware from the provided link...\n"
    # Add retry and continue logic for robustness against transient network errors
    if ! curl -L --fail --retry 3 --retry-delay 10 --continue-at - "$URL" -o "$WDIR/Downloads/firmware.zip"; then
        red "Download failed after multiple retries! Please check the link and your network connection." >&2
        exit 1
    fi
    green "Download completed successfully."
}

# Execute the download using samloader
run_samloader_download() {
    green "Samloader Download Mode Selected"
    
    green "Checking/Installing Samloader pip package..."
    if ! pip3 install --user --upgrade git+https://github.com/martinetd/samloader.git > /dev/null 2>&1; then
        red "Error: Failed to install samloader." >&2
        exit 1
    fi
    
    echo -e "====================================\n"
    echo -e "$(yellow "[+] Model:") ${MODEL}"
    echo -e "$(yellow "[+] IMEI:")  ${IMEI:0:9}XXXXXX"
    echo -e "$(yellow "[+] CSC:")   ${CSC}\n"
    echo -e "====================================\n"

    green "Fetching latest firmware version..."
    VERSION=$(python3 -m samloader -m "${MODEL}" -r "${CSC}" -i "${IMEI}" checkupdate 2>/dev/null)
    if [ -z "$VERSION" ]; then
        red "Model, region, or IMEI not found (403). Please check your inputs." >&2
        exit 1
    fi
    yellow "Update found: ${VERSION}"

    green "Attempting to download firmware..."
    local max_retries=3
    local attempt=1
    local success=false
    while [ $attempt -le $max_retries ] && [ "$success" = false ]; do
        if [ $attempt -gt 1 ]; then
            yellow "Retrying download in 15 seconds... (Attempt $attempt of $max_retries)"
            sleep 15
        fi
        if python3 -m samloader -m "${MODEL}" -r "${CSC}" -i "${IMEI}" download -v "${VERSION}" -O "$WDIR/Downloads"; then
            success=true
        fi
        ((attempt++))
    done

    if [ "$success" = false ]; then
        red "Download failed after $max_retries attempts. This can be due to network issues or incorrect device details." >&2
        exit 1
    fi
    green "Download completed."

    green "Decrypting firmware..."
    local FILE
    FILE=$(ls "$WDIR"/Downloads/*.enc*)
    if ! python3 -m samloader -m "${MODEL}" -r "${CSC}" -i "${IMEI}" decrypt -v "${VERSION}" -i "$FILE" -o "$WDIR/Downloads/firmware.zip"; then
        red "Decryption failed." >&2
        exit 1
    fi
    rm "${FILE}"
    green "Decryption completed."
}

# Organize firmware parts into folders, zip them, and upload
organize_and_upload_parts() {
    local ver_name="${1:-stock}"
    green "\n[+] Organizing and uploading firmware parts (AP, BL, CP, CSC)..."
    
    local EXTRACT_DIR="$WDIR/Downloads/Parts"
    rm -rf "$EXTRACT_DIR"
    mkdir -p "$EXTRACT_DIR"
    
    # Extract tars from firmware.zip
    if [ -f "$WDIR/Downloads/firmware.zip" ]; then
        unzip -j -o "$WDIR/Downloads/firmware.zip" "*.tar.md5" -d "$EXTRACT_DIR"
    else
        yellow "firmware.zip not found, skipping parts organization."
        return
    fi
    
    cd "$EXTRACT_DIR" || return
    
    # Create directories and move files
    mkdir -p AP BL CP CSC
    mv AP_*.tar.md5 AP/ 2>/dev/null
    mv BL_*.tar.md5 BL/ 2>/dev/null
    mv CP_*.tar.md5 CP/ 2>/dev/null
    mv CSC_*.tar.md5 CSC/ 2>/dev/null
    mv HOME_CSC_*.tar.md5 CSC/ 2>/dev/null
    
    # Process each folder
    for part in AP BL CP CSC; do
        if [ -n "$(ls -A $part 2>/dev/null)" ]; then
            green "Processing $part..."
            
            # Extract tars inside the folder to get raw images
            cd "$part" || continue
            for tarfile in *.tar.md5; do
                [ -f "$tarfile" ] && tar -xf "$tarfile" && rm "$tarfile"
            done
            cd ..
            
            # Upload if in workflow mode
            if [[ "${WORKFLOW_MODE:-0}" == "1" ]]; then
                local link=$(upload_to_gofile "$EXTRACT_DIR/$part" || upload_to_filebin "$EXTRACT_DIR/$part" || upload_to_fileio "$EXTRACT_DIR/$part")
                if [[ -n "$link" ]]; then
                    echo "GOLINK_${part}=$link" >> $GITHUB_ENV
                    export GOLINK_${part}="$link"
                fi
            fi
        fi
    done
}

# --- Main Execution ---
main() {
    clear
    blue "Samloader Actions - By @ravindu644\n"

    # Handle arguments
    parse_args "$@"
    validate_args
    
    # Prepare environment
    init_submodules
    install_dependencies
    rm -rf "$WDIR/Downloads" "$WDIR/output" "$WDIR/Dist" "$WDIR/docs"
    mkdir -p "$WDIR/Downloads" "$WDIR/output" "$WDIR/Dist" "$WDIR/docs"

    # Run selected mode
    if [ "$MODE" == "direct" ]; then
        run_direct_download
    else
        run_samloader_download
    fi

    # --- Post-processing ---
    local GOLINK_FULL=""

    # 1. Create full stock package
    green "\nCreating full stock firmware package..."
    # Sanitize VERSION for filename, as it can contain slashes.
    VERSION_FILENAMEFRIENDLY=$(echo "${VERSION}" | tr '/' '_')
    STOCK_ZIP_NAME="${MODEL}_${VERSION_FILENAMEFRIENDLY:-stock}_FULL.zip"
    if [ -f "$WDIR/Downloads/firmware.zip" ]; then
        cp "$WDIR/Downloads/firmware.zip" "$WDIR/Dist/$STOCK_ZIP_NAME"
        green "Full stock package created: Dist/$STOCK_ZIP_NAME"
        if [[ "${WORKFLOW_MODE:-0}" == "1" ]]; then
            GOLINK_FULL=$(upload_to_gofile "$WDIR/Dist/$STOCK_ZIP_NAME" || upload_to_filebin "$WDIR/Dist/$STOCK_ZIP_NAME" || upload_to_fileio "$WDIR/Dist/$STOCK_ZIP_NAME")
            if [[ -n "$GOLINK_FULL" ]]; then
                echo "GOLINK_FULL=$GOLINK_FULL" >> $GITHUB_ENV
            fi
        fi
    else
        yellow "Warning: firmware.zip not found, skipping full stock package creation."
    fi

    # 1.5 Organize and upload individual parts
    organize_and_upload_parts "${VERSION_FILENAMEFRIENDLY}"

    # 2. Create Magisk-ready package (by running worker)
    green "\nRunning post-processing for Magisk-ready package..."
    if ! source "$WDIR/tools/worker.sh"; then
        red "Post-processing script failed." >&2
        exit 1
    fi

    # 3. Generate a JSON file for GitHub Pages UI
    green "\nGenerating metadata file for GitHub Pages..."
    JSON_FILE="$WDIR/docs/firmware_info.json"
    # Assuming worker.sh creates its own zip file in the Dist directory.
    MAGISK_ZIP_NAME=$(find "$WDIR/Dist" -name "*.zip" ! -name "$STOCK_ZIP_NAME" -printf "%f\n" | head -n 1)

    cat > "$JSON_FILE" << EOL
{
  "model": "${MODEL}",
  "version": "${VERSION:-N/A}",
  "csc": "${CSC:-N/A}",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "downloads": {
    "full_stock_zip": "${STOCK_ZIP_NAME}",
    "magisk_ready_zip": "${MAGISK_ZIP_NAME:-N/A}",
    "gofile_full": "${GOLINK_FULL:-N/A}",
    "gofile_magisk": "${GOLINK_MAGISK:-N/A}",
    "gofile_ap": "${GOLINK_AP:-N/A}",
    "gofile_bl": "${GOLINK_BL:-N/A}",
    "gofile_cp": "${GOLINK_CP:-N/A}",
    "gofile_csc": "${GOLINK_CSC:-N/A}"
  }
}
EOL
    green "Metadata file created: docs/firmware_info.json"

    green "\nScript finished successfully!"
}

# Run the main function with all script arguments
main "$@"

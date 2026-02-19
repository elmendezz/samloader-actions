#!/bin/bash

# Function to get the best GoFile server
get_gofile_server() {
    local max_retries=10
    local count=0
    
    while [ $count -lt $max_retries ]; do
        # Use User-Agent to avoid bot detection
        local response=$(curl -s -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36" https://api.gofile.io/getServer)
        
        # Parse server using python
        local server=$(echo "$response" | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['server'])" 2>/dev/null)
        
        if [ -n "$server" ]; then
            echo "$server"
            return 0
        fi
        
        sleep $((count + 1))
        count=$((count + 1))
    done
    return 1
}

# Internal function to upload a single file
upload_file_core() {
    local file="$1"
    local folderId="$2"
    local server="$3"

    # If server not provided, try to get it (fallback)
    if [ -z "$server" ]; then
        server=$(get_gofile_server)
    fi

    if [ -z "$server" ]; then
        echo "Error: No GoFile server found" >&2
        return 1
    fi

    local args=(-F "file=@$file")
    if [ -n "$folderId" ]; then
        args+=(-F "folderId=$folderId")
    fi

    local response=$(curl -s -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36" -X POST "https://$server.gofile.io/uploadFile" "${args[@]}")
    local status=$(echo "$response" | python3 -c "import sys, json; print(json.load(sys.stdin).get('status'))" 2>/dev/null)

    if [ "$status" == "ok" ]; then
        local page=$(echo "$response" | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['downloadPage'])")
        local parent=$(echo "$response" | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['parentFolder'])")
        echo "$page $parent"
    else
        echo "Error uploading $file: $response" >&2
        return 1
    fi
}

# --- Filebin Fallback Function ---
upload_to_filebin() {
    local target="$1"
    echo "⚠️ GoFile upload failed. Trying fallback: Filebin.net" >&2

    if [[ -d "$target" ]]; then
        echo "📤 Uploading folder $(basename "$target") to Filebin.net..." >&2
        local bin_id=""
        local mainLink=""
        
        for file in "$target"/*; do
            if [ -f "$file" ]; then
                echo "   Uploading $(basename "$file")..." >&2
                
                local url="https://filebin.net/"
                if [ -n "$bin_id" ]; then
                    url="https://filebin.net/$bin_id"
                fi

                local response=$(curl -s -X POST "$url" --data-binary "@$file" -H "accept: application/json")
                
                if [ -z "$bin_id" ]; then
                    bin_id=$(echo "$response" | python3 -c "import sys, json; print(json.load(sys.stdin).get('bin', {}).get('id'))" 2>/dev/null)
                    if [ -n "$bin_id" ]; then
                        mainLink="https://filebin.net/$bin_id"
                    fi
                fi
                
                if [ -z "$bin_id" ]; then
                    echo "❌ Error uploading $(basename "$file") to Filebin: $response" >&2
                    return 1 # Fail fast for folder upload
                fi
                sleep 1
            fi
        done
        echo "$mainLink"

    elif [[ -f "$target" ]]; then
        echo "📤 Uploading $target to Filebin.net..." >&2
        local response=$(curl -s -X POST "https://filebin.net/" --data-binary "@$target" -H "accept: application/json")
        local bin_id=$(echo "$response" | python3 -c "import sys, json; print(json.load(sys.stdin).get('bin', {}).get('id'))" 2>/dev/null)
        
        if [ -n "$bin_id" ]; then
            echo "https://filebin.net/$bin_id"
        else
            echo "❌ Failed to upload to Filebin: $response" >&2
            return 1
        fi
    fi
}

# Main function to upload file or folder
upload_to_gofile() {
    local target="$1"

    # Fetch server once per batch to avoid rate limits
    local server=$(get_gofile_server)
    if [ -z "$server" ]; then
        echo "❌ Error: Unable to connect to GoFile servers." >&2
        return 1
    fi

    if [[ -d "$target" ]]; then
        echo "📤 Uploading folder $(basename "$target") to GoFile ($server)..." >&2
        local folderId=""
        local mainLink=""
        
        for file in "$target"/*; do
            if [ -f "$file" ]; then
                echo "   Uploading $(basename "$file")..." >&2
                read -r link parent <<< $(upload_file_core "$file" "$folderId" "$server")
                if [ -n "$parent" ] && [ "$parent" != "None" ]; then folderId="$parent"; fi
                if [ -z "$mainLink" ]; then mainLink="$link"; fi
                sleep 1
            fi
        done
        echo "$mainLink"
    elif [[ -f "$target" ]]; then
        echo "📤 Uploading $target to GoFile ($server)..." >&2
        read -r link parent <<< $(upload_file_core "$target" "" "$server")
        echo "$link"
    else
        echo "❌ File/Directory not found: $target" >&2
        return 1
    fi
}

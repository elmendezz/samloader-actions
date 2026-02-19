#!/bin/bash

# Function to get the best GoFile server
get_gofile_server() {
    curl -s https://api.gofile.io/getServer | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['server'])"
}

# Internal function to upload a single file
upload_file_core() {
    local file="$1"
    local folderId="$2"
    local server=$(get_gofile_server)

    if [ -z "$server" ]; then
        echo "Error: No GoFile server found" >&2
        return 1
    fi

    local args=(-F "file=@$file")
    if [ -n "$folderId" ]; then
        args+=(-F "folderId=$folderId")
    fi

    local response=$(curl -s -X POST "https://$server.gofile.io/uploadFile" "${args[@]}")
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

# Main function to upload file or folder
upload_to_gofile() {
    local target="$1"

    if [[ -d "$target" ]]; then
        echo "📤 Uploading folder $(basename "$target") to GoFile..." >&2
        local folderId=""
        local mainLink=""
        
        for file in "$target"/*; do
            if [ -f "$file" ]; then
                echo "   Uploading $(basename "$file")..." >&2
                read -r link parent <<< $(upload_file_core "$file" "$folderId")
                if [ -n "$parent" ] && [ "$parent" != "None" ]; then folderId="$parent"; fi
                if [ -z "$mainLink" ]; then mainLink="$link"; fi
            fi
        done
        echo "$mainLink"
    elif [[ -f "$target" ]]; then
        echo "📤 Uploading $target to GoFile..." >&2
        read -r link parent <<< $(upload_file_core "$target")
        echo "$link"
    else
        echo "❌ File/Directory not found: $target" >&2
        return 1
    fi
}

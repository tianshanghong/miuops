#!/bin/bash

# Helper script to delete a Cloudflare Tunnel and clean up related files
# This script ONLY deletes tunnels — DNS CNAME records must be removed manually from Cloudflare dashboard

set -e

# Ensure cloudflared is installed
if ! command -v cloudflared &> /dev/null; then
    echo "Error: cloudflared is not installed. Please install it first."
    exit 1
fi

# Check if jq is installed (required for JSON parsing)
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Please install it first:"
    echo "  - macOS: brew install jq"
    echo "  - Ubuntu/Debian: sudo apt install jq"
    echo "  - CentOS/RHEL: sudo yum install jq"
    exit 1
fi

# Check if the user is logged in
if [ ! -f ~/.cloudflared/cert.pem ]; then
    echo "You need to log in to Cloudflare first."
    cloudflared login
fi

# Display title
echo "=============================================="
echo "        Cloudflare Tunnel Deletion Tool       "
echo "=============================================="
echo "NOTE: This script only deletes the tunnel itself."
echo "      DNS CNAME records must be removed manually from Cloudflare dashboard."
echo "=============================================="

# List all available tunnels
echo "Fetching your tunnels..."
TUNNELS_RAW=$(cloudflared tunnel list -o json 2>&1)

# Check if the command succeeded
if [[ $? -ne 0 ]]; then
    echo "Error fetching tunnels: $TUNNELS_RAW"
    exit 1
fi

# Check for valid JSON
if ! echo "$TUNNELS_RAW" | jq empty &>/dev/null; then
    echo "Error: Invalid JSON returned from cloudflared:"
    echo "$TUNNELS_RAW"
    echo ""
    echo "Try running 'cloudflared tunnel list' manually to verify."
    exit 1
fi

# Check if tunnels exist by a different method
if [ -z "$TUNNELS_RAW" ] || [ "$TUNNELS_RAW" == "[]" ] || [ "$TUNNELS_RAW" == "null" ]; then
    echo "No tunnels found in your Cloudflare account."
    echo "You can create a tunnel using: ./miuops up"
    exit 0
fi

# First check if JSON has a specific structure we expect
TUNNELS_COUNT=$(echo "$TUNNELS_RAW" | jq 'if type == "array" then length else 0 end')

if [ "$TUNNELS_COUNT" -eq 0 ]; then
    echo "No tunnels found or unexpected JSON format returned."
    echo "Raw output from cloudflared:"
    echo "$TUNNELS_RAW"
    echo ""
    echo "Try running 'cloudflared tunnel list' manually to verify."
    exit 0
fi

# Display tunnels in a formatted table
echo ""
echo "Your Cloudflare Tunnels:"
echo "-----------------------------------------------------------------------------"
printf "%-40s | %-20s | %-20s\n" "TUNNEL ID" "NAME" "CREATED"
echo "-----------------------------------------------------------------------------"

# Use a safer approach to extract and display tunnel info
echo "$TUNNELS_RAW" | jq -r '.[] | [.id, .name, .created_at] | @tsv' | \
while IFS=$'\t' read -r id name created; do
    printf "%-40s | %-20s | %-20s\n" "$id" "$name" "$created"
done

echo "-----------------------------------------------------------------------------"
echo ""

# Ask which tunnel to delete
read -p "Enter the ID of the tunnel you want to delete (or press Enter to cancel): " TUNNEL_ID

if [ -z "$TUNNEL_ID" ]; then
    echo "No tunnel ID provided. Exiting."
    exit 1
fi

# Verify the tunnel exists
if ! echo "$TUNNELS_RAW" | jq -e ".[] | select(.id == \"$TUNNEL_ID\")" > /dev/null; then
    echo "Error: No tunnel found with ID $TUNNEL_ID"
    exit 1
fi

# Get the tunnel name for confirmation
TUNNEL_NAME=$(echo "$TUNNELS_RAW" | jq -r ".[] | select(.id == \"$TUNNEL_ID\") | .name")

# Confirm deletion
echo ""
echo "You are about to delete the following tunnel:"
echo "ID:   $TUNNEL_ID"
echo "Name: $TUNNEL_NAME"
echo ""
echo "NOTE: This script will NOT modify any DNS records."
echo "      You'll need to remove CNAME records manually from Cloudflare dashboard."
echo ""

read -p "Are you sure you want to delete this tunnel? (y/N): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Deletion cancelled."
    exit 0
fi

# Delete the tunnel
echo "Deleting tunnel '$TUNNEL_NAME' ($TUNNEL_ID)..."
DELETION_RESULT=$(cloudflared tunnel delete "$TUNNEL_ID" 2>&1)
if [[ $? -ne 0 ]]; then
    echo "Error deleting tunnel: $DELETION_RESULT"
    exit 1
fi

echo "Tunnel successfully deleted from Cloudflare."

# Remove local credential file if it exists
if [ -f "files/$TUNNEL_ID.json" ]; then
    echo "Removing local credential file..."
    rm "files/$TUNNEL_ID.json"
    echo "Local credential file removed."
else
    echo "No local credential file found in project directory."
fi

# Check if there's a credentials file in the default location
if [ -f ~/.cloudflared/$TUNNEL_ID.json ]; then
    echo "Removing credentials file from ~/.cloudflared/..."
    rm ~/.cloudflared/$TUNNEL_ID.json
    echo "Credentials file removed from ~/.cloudflared/"
else
    echo "No credentials file found in ~/.cloudflared/"
fi

echo ""
echo "========================================================="
echo "Tunnel '$TUNNEL_NAME' ($TUNNEL_ID) has been deleted."
echo ""
echo "IMPORTANT NEXT STEPS:"
echo "1. Remove CNAME records for this tunnel from Cloudflare dashboard"
echo "2. Delete group_vars/all.yml so the next './miuops up' creates a fresh tunnel"
echo "=========================================================" 
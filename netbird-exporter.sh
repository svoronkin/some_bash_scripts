#!/bin/bash

# Check if a port number is provided as an argument
if [ -z "$1" ]; then
  echo "Usage: $0 <port>"
  exit 1
fi

# Set the port variable from the first argument
PORT=$1
host=$(hostname)

# Define a function to extract values from JSON using jq
extract_json_value() {
    echo "$1" | jq -r "$2"
}

# Function to generate metrics
get_metrics() {
    # Get the JSON output from netbird status command
    json_output=$(netbird status --json)

    # Extract metrics using jq
    peers_total=$(extract_json_value "$json_output" '.peers.total')
    peers_connected=$(extract_json_value "$json_output" '.peers.connected')
    daemon_version=$(extract_json_value "$json_output" '.daemonVersion')
    relays_total=$(extract_json_value "$json_output" '.relays.total')
    relays_available=$(extract_json_value "$json_output" '.relays.available')

    # Generate the metrics in Prometheus format
    cat <<EOF
# HELP netbird_peers_total Total number of peers
# TYPE netbird_peers_total gauge
netbird_peers_total{host="$host"} $peers_total

# HELP netbird_peers_connected Number of connected peers
# TYPE netbird_peers_connected gauge
netbird_peers_connected{host="$host"} $peers_connected

# HELP netbird_daemon_version Daemon version of Netbird
# TYPE netbird_daemon_version gauge
netbird_daemon_version{host="$host", version="$daemon_version"} 1

# HELP netbird_relays_total Total number of relays
# TYPE netbird_relays_total gauge
netbird_relays_total{host="$host"} $relays_total

# HELP netbird_relays_available Number of available relays
# TYPE netbird_relays_available gauge
netbird_relays_available{host="$host"} $relays_available
EOF
}

cleanup() {
    echo "Stopping server and releasing port $PORT..."
    kill "$nc_pid" 2>/dev/null
    exit 0
}
# Trap termination signals (e.g., Ctrl+C) and call the cleanup function
trap cleanup EXIT INT TERM

# Start a simple HTTP server to expose metrics on the specified port
while true; do
    # Serve the metrics directly
    { echo -e "HTTP/1.1 200 OK\nContent-Type: text/plain\r\n\r\n$(get_metrics)"; } | nc -w 3 -l 0.0.0.0 $PORT &
    nc_pid=$!  # Save the PID of the background nc process
    wait "$nc_pid"  # Wait for the nc process to finish
done

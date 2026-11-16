#!/bin/bash

LOG_FILE="$HOME/ideagent_debian_audit.log"
PIPE_FILE="/tmp/ideagent_audit.pipe"

echo "========================================================================="
echo " Starting IDEAgent Integrated Audit (Debian 12)"
echo " Logging to: $LOG_FILE"
echo " Press [CTRL+C] to stop."
echo "========================================================================="

# Clean up any broken system pipes from previous runs
rm -f "$PIPE_FILE"
mkfifo "$PIPE_FILE"

# Print clean CSV Headers
echo "Timestamp_Epoch,Traffic_Type,Src_IP,Src_Port,Dst_IP,Dst_Port,Packet_Size_Bytes,Resolved_Domain" > "$LOG_FILE"

declare -A DNS_CACHE

mask_ip() {
    local ip="$1"
    if [[ -z "$ip" ]]; then 
        echo "N/A"
    elif [[ "$ip" =~ ^192\.168\. ]]; then 
        echo "192.x.x.${ip##*.}"
    else 
        echo "$ip"
    fi
}

get_domain_name() {
    local ip="$1"
    ip=$(echo "$ip" | tr -d '[:space:]')

    if [[ "$ip" == "127.0.0.1" || "$ip" =~ ^172\. || "$ip" =~ ^192\. || "$ip" =~ ^224\. || "$ip" == "255.255.255.255" || -z "$ip" ]]; then
        echo "INTERNAL"
        return
    fi

    if [[ -n "${DNS_CACHE[$ip]}" ]]; then
        echo "${DNS_CACHE[$ip]}"
        return
    fi

    # Fast reverse DNS lookup (1 second timeout). Drops trailing dot.
    local domain
    domain=$(dig +short -x "$ip" +time=1 +tries=1 2>/dev/null | head -n 1 | sed 's/\.$//')
    
    if [[ -z "$domain" ]]; then 
        domain="Unknown_Domain"
    fi
    
    DNS_CACHE[$ip]="$domain"
    echo "$domain"
}

# Handle cleanup gracefully when the user presses CTRL+C
cleanup() {
    echo -e "\nShutting down audit securely..."
    kill "$TSHARK_PID" 2>/dev/null
    rm -f "$PIPE_FILE"
    exit 0
}
trap cleanup SIGINT SIGTERM

# Launch packet sniffer silently into the background, pushing directly to memory pipe
sudo tshark -i any -n -T fields \
  -E separator=, \
  -e frame.time_epoch \
  -e ip.src \
  -e tcp.srcport -e udp.srcport \
  -e ip.dst \
  -e tcp.dstport -e udp.dstport \
  -e frame.len \
  2>/dev/null > "$PIPE_FILE" &
TSHARK_PID=$!

# Read raw chunks directly without character or column limit cuts
while IFS=, read -r timestamp src_ip tcp_src udp_src dst_ip tcp_dst udp_dst len; do
    [ -z "$src_ip" ] && continue

    # Clean up tshark values (takes the first match if multiple ports are returned like '443,443')
    src_ip=$(echo "$src_ip" | awk -F, '{print $1}')
    dst_ip=$(echo "$dst_ip" | awk -F, '{print $1}')
    
    raw_src_port="${tcp_src:-$udp_src}"
    raw_dst_port="${tcp_dst:-$udp_dst}"
    src_port=$(echo "$raw_src_port" | awk -F, '{print $1}')
    dst_port=$(echo "$raw_dst_port" | awk -F, '{print $1}')

    [ -z "$src_port" ] && src_port="0"
    [ -z "$dst_port" ] && dst_port="0"

    TRAFFIC_TYPE="OUTBOUND_EXTERNAL"
    DOMAIN_INFO="N/A"

    # 1. Component Port Analysis
    if [[ "$src_port" == "5810" || "$dst_port" == "5810" || "$src_port" == "2222" || "$dst_port" == "2222" ]]; then
        TRAFFIC_TYPE="RAG_SERVER"
    elif [[ "$src_port" == "22" || "$dst_port" == "22" ]]; then
        TRAFFIC_TYPE="SFTP_RAG_WATCHER"
    elif [[ "$src_port" == "8000" || "$dst_port" == "8000" ]]; then
        TRAFFIC_TYPE="CHROMADB"
    elif [[ "$src_port" == "5820" || "$dst_port" == "5820" ]]; then
        TRAFFIC_TYPE="MPC_SERVER"

    # 2. Public AI Routing Infrastructure
    elif [[ ( "$src_ip" =~ ^(142\.250|172\.217|74\.125)\. && "$src_port" == "443" ) || ( "$dst_ip" =~ ^(142\.250|172\.217|74\.125)\. && "$dst_port" == "443" ) ]]; then
        TRAFFIC_TYPE="GOOGLE_AI_API"

    # 3. Virtual Interfaces & Local Network Switches
    elif [[ "$src_ip" == "127.0.0.1" || "$dst_ip" == "127.0.0.1" || "$src_ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. || "$dst_ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then
        TRAFFIC_TYPE="DOCKER_OR_LOOPBACK"
    elif [[ "$src_ip" =~ ^192\.168\. && "$dst_ip" =~ ^192\.168\. ]]; then
        TRAFFIC_TYPE="LOCAL_LAN_TRAFFIC"
    fi

    # 4. Resolve domain name using the RAW unmasked external IP address
    if [[ "$TRAFFIC_TYPE" == "OUTBOUND_EXTERNAL" ]]; then
        if [[ "$src_ip" =~ ^192\.168\. || "$src_ip" == "127.0.0.1" || "$src_ip" =~ ^172\. ]]; then
            DOMAIN_INFO=$(get_domain_name "$dst_ip")
        else
            DOMAIN_INFO=$(get_domain_name "$src_ip")
        fi
    fi

    # 5. Mask internal IPs conditionally at the very end for the log file
    MASKED_SRC=$(mask_ip "$src_ip")
    MASKED_DST=$(mask_ip "$dst_ip")

    # Output log stream safely to file
    echo "$timestamp,$TRAFFIC_TYPE,$MASKED_SRC,$src_port,$MASKED_DST,$dst_port,$len,$DOMAIN_INFO" >> "$LOG_FILE"
done < "$PIPE_FILE"

#!/bin/bash

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "[-] Error: This script must be run with sudo or as root." >&2
    exit 1
fi

echo "[+] Starting NFS Export Configuration with Project Groups..."

# 1. Define Groups, Directories, and Mappings
G_PROJ1="project1staff"
G_PROJ2="project2staff"

# Create groups if they do not exist
for grp in "$G_PROJ1" "$G_PROJ2"; do
    if ! getent group "$grp" > /dev/null 2>&1; then
        groupadd "$grp"
        echo "    Created local group: $grp"
    else
        echo "    Group $grp already exists."
    fi
done

PSEUDO_ROOT="/export"
CORP_DATA="/corpdata"

# Setup nested map arrays for source, target, and associated group
# Format: [source_dir]="target_dir:group_name"
declare -A CONFIG_MAP=(
    ["$CORP_DATA/proj1"]="$PSEUDO_ROOT/project1:$G_PROJ1"
    ["$CORP_DATA/proj2"]="$PSEUDO_ROOT/project2:$G_PROJ2"
)

# 2. Create Directories with Project Group Ownership
echo "[+] Creating directories and setting permissions..."
for src in "${!CONFIG_MAP[@]}"; do
    # Split the target path and group name
    IFS=":" read -r tgt grp <<< "${CONFIG_MAP[$src]}"
    
    # Create source and target bind points
    mkdir -p "$src" "$tgt"
    
    # Set ownership (root for user, project group for group)
    chown -R root:"$grp" "$src"
    chown -R root:"$grp" "$tgt"
    
    # 2775 ensures group members can write, and new files inherit the group
    chmod -R 2775 "$src"
    chmod -R 2775 "$tgt"
done

# 3. Configure /etc/fstab Bind Mounts
echo "[+] Updating /etc/fstab with special bind mounts..."
for src in "${!CONFIG_MAP[@]}"; do
    IFS=":" read -r tgt grp <<< "${CONFIG_MAP[$src]}"
    
    # Check if entry already exists to prevent duplicates
    if ! grep -qs "$tgt" /etc/fstab; then
        echo -e "${src}\t${tgt}\tnone\tbind\t0 0" >> /etc/fstab
        echo "    Added bind mount for $tgt"
    else
        echo "    Bind mount for $tgt already exists in /etc/fstab"
    fi
done

# Mount everything listed in fstab
echo "[+] Mounting directories..."
mount -a

# 4. Configure /etc/exports (Pseudo-Root Structure)
echo "[+] Configuring /etc/exports..."

# Backup existing exports file
cp /etc/exports /etc/exports.bak.$(date +%F_%T)

# Define export configurations
# Note: For group permissions to map accurately across clients, 
# client users must share identical UIDs/GIDs with the server environment.
cat << EOF > /etc/exports
# NFSv4 Pseudo-root definition
$PSEUDO_ROOT           *(rw,sync,fsid=0,crossmnt,no_subtree_check,secure_locks)

# Export paths relative to the pseudo-root for clients
$PSEUDO_ROOT/project1  *(rw,sync,no_subtree_check,no_root_squash)
$PSEUDO_ROOT/project2  *(rw,sync,no_subtree_check,no_root_squash)
EOF

# 5. Handle NFS Server Lifecycle
echo "[+] Managing nfs-server.service..."
systemctl daemon-reload

if systemctl is-active --quiet nfs-server; then
    echo "    Restarting active NFS server..."
    systemctl restart nfs-server
else
    echo "    Enabling and starting NFS server..."
    systemctl enable --now nfs-server
fi

# 6. Verify and Report Status
echo -e "\n========================================="
echo "[+] NFS Export Status Report (exportfs -v):"
echo "========================================="
exportfs -v

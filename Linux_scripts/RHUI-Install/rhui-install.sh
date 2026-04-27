#!/bin/bash

set -euo pipefail

METADATA_URL="http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01"
HEADER="Metadata:true"
RHUI_HOST="rhui4-1.microsoft.com"

#--------------------------------------------------
# UI Helpers
#--------------------------------------------------
line() { echo "--------------------------------------------------"; }
section() { echo; echo "[ $1 ]"; }
info() { echo "➜  $1"; }
ok() { echo "✔  $1"; }
warn() { echo "⚠  $1"; }
fail() { echo "✖  $1"; exit 1; }

#--------------------------------------------------
# Helper: Package Manager
#--------------------------------------------------
pkg_mgr() {
    if [[ "$OS_VERSION" -ge 8 ]]; then
        echo "dnf"
    else
        echo "yum"
    fi
}

#--------------------------------------------------
# Helper: Repo Query
#--------------------------------------------------
repo_query() {
    if [[ "$OS_VERSION" -ge 8 ]]; then
        dnf repoquery --config "$1" --qf "$2" "$3" 2>/dev/null || true
    else
        repoquery --config "$1" --qf "$2" "$3" 2>/dev/null || true
    fi
}

#--------------------------------------------------
# 1. OS Details
#--------------------------------------------------
section "Detecting Operating System"

[ -f /etc/os-release ] || fail "OS detection failed"

source /etc/os-release
OS_VERSION=$(echo "$VERSION_ID" | cut -d '.' -f1)
OS_MINOR=$(echo "$VERSION_ID" | cut -d '.' -f2)

ok "OS        : $PRETTY_NAME"
ok "Version   : $OS_VERSION"

#--------------------------------------------------
# 2. RHUI Check
#--------------------------------------------------
section "Checking Existing RHUI"

RHUI_INSTALLED=$(rpm -qa | grep -i rhui || true)

if [[ -n "$RHUI_INSTALLED" ]]; then
    warn "RHUI already installed"
    echo "$RHUI_INSTALLED"
    exit 0
fi

ok "RHUI not present"

#--------------------------------------------------
# 3. Azure Metadata
#--------------------------------------------------
section "Fetching Azure Metadata"

METADATA=$(curl -s -H "$HEADER" "$METADATA_URL") || fail "Metadata fetch failed"

OFFER=$(echo "$METADATA" | grep -oP '"offer":\s*"\K[^"]+' | head -1)
SKU=$(echo "$METADATA" | grep -oP '"sku":\s*"\K[^"]+' | head -1)

ok "Offer : $OFFER"
ok "SKU   : $SKU"

#--------------------------------------------------
# 4. Detect Image Type
#--------------------------------------------------
section "Detecting Image Type"

SKU_LOWER=$(echo "$SKU" | tr '[:upper:]' '[:lower:]')
IMAGE_SUFFIX="standard"

if echo "$SKU_LOWER" | grep -q "sapapps"; then
    IMAGE_SUFFIX="sapapps"
elif echo "$SKU_LOWER" | grep -q "sap" && echo "$SKU_LOWER" | grep -q "ha"; then
    IMAGE_SUFFIX="sap-ha"
elif echo "$SKU_LOWER" | grep -q "sap"; then
    IMAGE_SUFFIX="sap"
elif echo "$SKU_LOWER" | grep -q "ha"; then
    IMAGE_SUFFIX="ha"
fi

ok "Detected Image Type : $IMAGE_SUFFIX"

#--------------------------------------------------
# 5. Preview Available RHUI Packages
#--------------------------------------------------
section "Preview Available RHUI Packages"
#BASE_REPO means NON-EUS.
BASE_REPO="microsoft-azure-rhel${OS_VERSION}"
EUS_REPO="microsoft-azure-rhel${OS_VERSION}-eus"

if [[ "$IMAGE_SUFFIX" == "sapapps" ]]; then
    if [[ "$OS_VERSION.$OS_MINOR" == "7.9" || "$OS_VERSION.$OS_MINOR" == "8.10" ]]; then
        BASE_REPO="${BASE_REPO}-base-sap-apps"
        FILTER="rhui-azure-rhel${OS_VERSION}-base-sap-apps*"
        LABEL="BASE packages:"
    else
        BASE_REPO="${BASE_REPO}-sapapps"
        FILTER="rhui-azure-rhel${OS_VERSION}-sapapps*"
        LABEL="EUS/E4S packages:"
    fi
elif [[ "$IMAGE_SUFFIX" == "sap-ha" ]]; then
    if [[ "$OS_VERSION.$OS_MINOR" == "7.9" || "$OS_VERSION.$OS_MINOR" == "8.10" ]]; then
        BASE_REPO="${BASE_REPO}-base-sap-ha"
        FILTER="rhui-azure-rhel${OS_VERSION}-base-sap-ha*"
        LABEL="BASE packages:"
    else
        BASE_REPO="${BASE_REPO}-sap-ha"
        FILTER="rhui-azure-rhel${OS_VERSION}-sap-ha*"
        LABEL="EUS/E4S packages:"
    fi
elif [[ "$IMAGE_SUFFIX" == "ha" ]]; then
    if [[ "$OS_VERSION.$OS_MINOR" == "7.9" || "$OS_VERSION.$OS_MINOR" == "8.10" ]]; then
        BASE_REPO="${BASE_REPO}-base-ha"
        FILTER="rhui-azure-rhel${OS_VERSION}-base-ha*"
        LABEL="BASE packages:"
    else
        BASE_REPO="${BASE_REPO}-ha"
        FILTER="rhui-azure-rhel${OS_VERSION}-ha*"
        LABEL="EUS/E4S packages:"
    fi
else
    FILTER="rhui-azure-rhel${OS_VERSION}*"
    LABEL="Base (Non-EUS) packages:"
fi

PREVIEW_CONFIG="/tmp/rhui-preview.repo"

cat <<EOF > "$PREVIEW_CONFIG"
[$BASE_REPO]
name=Base Repo
baseurl=https://${RHUI_HOST}/pulp/repos/unprotected/${BASE_REPO}
enabled=1
gpgcheck=0
sslverify=1
EOF

BASE_PKGS=$(repo_query "$PREVIEW_CONFIG" "%{name}-%{version}-%{release}.%{arch}" "$FILTER" | sort -u)

echo "$LABEL"
if [[ -n "$BASE_PKGS" ]]; then
    echo "$BASE_PKGS" | sed 's/^/  - /'
    ok "Packages are available"
else
    echo "  (none found)"
    warn "No packages found"
fi

# Only show EUS section for STANDARD images
if [[ "$IMAGE_SUFFIX" == "standard" ]]; then

echo
echo "EUS-specific packages:"

cat <<EOF >> "$PREVIEW_CONFIG"
[$EUS_REPO]
name=EUS Repo
baseurl=https://${RHUI_HOST}/pulp/repos/unprotected/${EUS_REPO}
enabled=1
gpgcheck=0
sslverify=1
EOF

EUS_PKGS=$(repo_query "$PREVIEW_CONFIG" "%{name}-%{version}-%{release}.%{arch}" "rhui-azure-rhel${OS_VERSION}-eus*" | sort -u)

if [[ -n "$EUS_PKGS" ]]; then
    echo "$EUS_PKGS" | sed 's/^/  - /'
    ok "EUS is available"
else
    echo "  (not available)"
    warn "EUS is NOT available"
fi

fi

rm -f "$PREVIEW_CONFIG"

#--------------------------------------------------
# 6. EUS / Non-EUS Selection
#--------------------------------------------------
section "EUS / Non-EUS Selection"

USE_BASE=0
if [[ "$OS_VERSION.$OS_MINOR" == "7.9" || "$OS_VERSION.$OS_MINOR" == "8.10" ]]; then
    USE_BASE=1
fi

EUS_AVAILABLE=0
if [[ "$IMAGE_SUFFIX" == "standard" && -n "${EUS_PKGS:-}" ]]; then
    EUS_AVAILABLE=1
fi

if [[ "$IMAGE_SUFFIX" != "standard" ]]; then

    if [[ "$USE_BASE" -eq 1 ]]; then
        warn "EUS is not applicable for this system"
        echo ""
        info "Proceeding with BASE automatically"
        MODE="BASE"
    else
        warn "Non-EUS is not applicable for this system"
        echo ""
        info "Proceeding with EUS automatically"
        MODE="1"
    fi

else

    if [[ "$EUS_AVAILABLE" -eq 1 ]]; then
        echo "Choose support model:"
        line
        echo "1) EUS / E4S (Extended Update Support)"
        echo "   - Provides longer lifecycle for a specific RHEL minor version"
        echo "   - Recommended for stability"
        echo
        echo "2) Non-EUS / Base"
        echo "   - Always available"
        echo
        read -p "Enter choice [1-2] (default: 1): " MODE
        MODE=${MODE:-1}
    else
        warn "EUS is not available for this system"
        echo ""
        info "Proceeding with Non-EUS automatically"
        MODE="2"
    fi

fi

#--------------------------------------------------
# 7. Package Selection
#--------------------------------------------------
section "Selecting RHUI Package"

PKG_BASE="rhui-azure-rhel${OS_VERSION}"

case "$IMAGE_SUFFIX" in
    sapapps)
        if [[ "$OS_VERSION.$OS_MINOR" == "7.9" || "$OS_VERSION.$OS_MINOR" == "8.10" ]]; then
            PKG="${PKG_BASE}-base-sap-apps"
            REPO_NAME="microsoft-azure-rhel${OS_VERSION}-base-sap-apps"
        else
            PKG="${PKG_BASE}-sapapps"
            REPO_NAME="microsoft-azure-rhel${OS_VERSION}-sapapps"
        fi
        ;;
    sap-ha)
        if [[ "$OS_VERSION.$OS_MINOR" == "7.9" || "$OS_VERSION.$OS_MINOR" == "8.10" ]]; then
            PKG="${PKG_BASE}-base-sap-ha"
            REPO_NAME="microsoft-azure-rhel${OS_VERSION}-base-sap-ha"
        else
            PKG="${PKG_BASE}-sap-ha"
            REPO_NAME="microsoft-azure-rhel${OS_VERSION}-sap-ha"
        fi
        ;;
    ha)
        if [[ "$OS_VERSION.$OS_MINOR" == "7.9" || "$OS_VERSION.$OS_MINOR" == "8.10" ]]; then
            PKG="${PKG_BASE}-base-ha"
            REPO_NAME="microsoft-azure-rhel${OS_VERSION}-base-ha"
        else
            PKG="${PKG_BASE}-ha"
            REPO_NAME="microsoft-azure-rhel${OS_VERSION}-ha"
        fi
        ;;
    sap)
        PKG="${PKG_BASE}-sap"
        REPO_NAME="microsoft-azure-rhel${OS_VERSION}-sap"
        ;;
    standard)
        if [[ "$MODE" == "1" ]]; then
            PKG="${PKG_BASE}-eus"
            REPO_NAME="microsoft-azure-rhel${OS_VERSION}-eus"
        else
            PKG="${PKG_BASE}"
            REPO_NAME="microsoft-azure-rhel${OS_VERSION}"
        fi
        ;;
esac

ok "Selected Package : $PKG"
ok "Repo Name : $REPO_NAME"

#--------------------------------------------------
# 8. Create Repo
#--------------------------------------------------
CONFIG_FILE="/tmp/rhui.repo"

section "Creating Repository Configuration"

cat <<EOF > "$CONFIG_FILE"
[$REPO_NAME]
name=Microsoft Azure RPMs for RHEL $OS_VERSION ($REPO_NAME)
baseurl=https://${RHUI_HOST}/pulp/repos/unprotected/${REPO_NAME}
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
sslverify=1
EOF

ok "Repository file created"

#--------------------------------------------------
# 9. Install RHUI
#--------------------------------------------------
section "Installing RHUI Package"
PM=$(pkg_mgr)
TMP_LOG="/tmp/rhui_install.log"

info "Installing package: $PKG"

if ! $PM --config "$CONFIG_FILE" install -y "$PKG" >"$TMP_LOG" 2>&1; then
    echo
    echo "✖ Installation failed"
    echo
    echo "------ ERROR DETAILS ------"
    cat "$TMP_LOG"
    echo "---------------------------"
    exit 1
fi

ok "Installed: $PKG"

rm -f "$CONFIG_FILE" "$TMP_LOG"
#--------------------------------------------------
# 10. VERSION LOCK
#--------------------------------------------------
section "Configuring release version lock"

CURRENT_VERSION="$VERSION_ID"
SET_LOCK=0

# SAP / HA → only if NOT base versions
if [[ "$IMAGE_SUFFIX" != "standard" ]]; then
    if [[ "$OS_VERSION.$OS_MINOR" != "7.9" && "$OS_VERSION.$OS_MINOR" != "8.10" ]]; then
        SET_LOCK=1
    fi
fi

# Standard → only if EUS selected
if [[ "$IMAGE_SUFFIX" == "standard" && "${MODE:-}" == "1" ]]; then
    SET_LOCK=1
fi

if [[ "$SET_LOCK" -eq 1 ]]; then

    if [[ "$OS_VERSION" -ge 8 ]]; then
        VAR_PATH="/etc/dnf/vars/releasever"
    else
        VAR_PATH="/etc/yum/vars/releasever"
    fi

    mkdir -p "$(dirname "$VAR_PATH")"
    echo "$CURRENT_VERSION" > "$VAR_PATH"

    ok "releasever locked to $CURRENT_VERSION"

else
    info "releasever lock not required"
fi

#--------------------------------------------------
# 11. Validation
#--------------------------------------------------
section "Validating Installation"

rpm -qa | grep -i rhui || fail "RHUI install failed"
ok "RHUI package verified"

$PM repolist >/dev/null 2>&1 || fail "Repo access failed"
ok "Repositories accessible"

#--------------------------------------------------
# 12. Summary
#--------------------------------------------------
section "Installation Complete"

echo "RHUI installation completed successfully!"
echo
echo "Summary"
line
echo "OS        : $PRETTY_NAME"
echo "Version   : $OS_VERSION"
echo "Image     : $IMAGE_SUFFIX"
echo "Repo      : $REPO_NAME"
echo "Package   : $(rpm -qa | grep -i rhui)"
line

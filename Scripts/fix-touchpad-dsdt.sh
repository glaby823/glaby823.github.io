#!/usr/bin/env bash
#
# fix-touchpad-dsdt.sh (v2)
#
# Automatise le patch ACPI DSDT pour corriger le touchpad sur certains
# laptops Lenovo AMD, sur Arch, Ubuntu/Debian et Fedora, avec GRUB ou
# systemd-boot (classique ou UKI).
#
# Méthode : le noyau Linux peut charger une DSDT de remplacement si elle se
# trouve dans un segment cpio NON COMPRESSÉ placé en tête de l'initrd, au
# chemin kernel/firmware/acpi/dsdt.aml (même mécanisme que le microcode
# CPU). Avec GRUB, il existe une méthode plus simple et native (directive
# "acpi" du menu GRUB), qui ne passe pas par l'initrd.
#
# Usage :
#   chmod +x fix-touchpad-dsdt.sh
#   sudo ./fix-touchpad-dsdt.sh
#
# ATTENTION : ce patch est spécifique à un modèle de DSDT donné (Lenovo/AMD).
# S'il ne s'applique pas proprement, le script s'arrête sans rien modifier.

set -euo pipefail

WORKDIR="${SUDO_USER:+/home/$SUDO_USER}/acpi"
WORKDIR="${WORKDIR:-$HOME/acpi}"
PATCH_URL="https://launchpadlibrarian.net/738328314/dsdt.patch"
DSDT_TARGET="/boot/dsdt.aml"
GRUB_CUSTOM="/etc/grub.d/40_custom"
GRUB_ENTRY_TITLE="Arch Linux (DSDT patchee - touchpad)"

log()  { echo -e "\n\033[1;34m==>\033[0m $*"; }
warn() { echo -e "\033[1;33mAttention:\033[0m $*"; }
err()  { echo -e "\033[1;31mErreur:\033[0m $*" >&2; }
die()  { err "$*"; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "Ce script doit être lancé avec sudo (il modifie /boot, /etc/grub.d ou les entrées systemd-boot)."
}

detect_distro() {
    [[ -f /etc/os-release ]] || die "Impossible de détecter la distribution (/etc/os-release introuvable)."
    . /etc/os-release
    local id="${ID:-unknown}" id_like="${ID_LIKE:-}"
    case "$id" in
        arch|manjaro|endeavouros)          FAMILY="arch" ;;
        ubuntu|debian|linuxmint|pop)       FAMILY="debian" ;;
        fedora)                            FAMILY="fedora" ;;
        *)
            case "$id_like" in
                *arch*)          FAMILY="arch" ;;
                *debian*)        FAMILY="debian" ;;
                *fedora*|*rhel*) FAMILY="fedora" ;;
                *) die "Distribution '$id' non supportée (arch / debian-ubuntu / fedora uniquement)." ;;
            esac ;;
    esac
    log "Distribution détectée : $id (famille : $FAMILY)"
}

detect_bootloader() {
    if [[ -f /boot/loader/loader.conf ]] || [[ -f /boot/efi/loader/loader.conf ]] || [[ -f /efi/loader/loader.conf ]]; then
        BOOTLOADER="systemd-boot"
    elif [[ -f /etc/default/grub ]] || [[ -f /boot/grub/grub.cfg ]] || [[ -f /boot/grub2/grub.cfg ]]; then
        BOOTLOADER="grub"
    elif command -v grub-mkconfig >/dev/null 2>&1 || command -v grub2-mkconfig >/dev/null 2>&1; then
        BOOTLOADER="grub"
    else
        die "Bootloader non détecté (ni GRUB ni systemd-boot). Ce script ne gère que ces deux-là."
    fi
    log "Bootloader détecté : $BOOTLOADER"
}

install_dependencies() {
    log "Installation des dépendances (acpica, wget, patch, cpio)..."
    case "$FAMILY" in
        arch)
            pacman -Sy --needed --noconfirm acpica wget patch cpio
            if [[ "$BOOTLOADER" == "grub" ]]; then
                pacman -S --needed --noconfirm grub
            fi
            ;;
        debian)
            apt-get update
            apt-get install -y acpica-tools wget patch cpio
            if [[ "$BOOTLOADER" == "grub" ]]; then
                apt-get install -y grub2-common
            fi
            ;;
        fedora)
            dnf install -y acpica-tools wget patch cpio
            if [[ "$BOOTLOADER" == "grub" ]]; then
                dnf install -y grub2-tools
            fi
            ;;
    esac
}

prepare_workdir() {
    log "Préparation du dossier de travail : $WORKDIR"
    mkdir -p "$WORKDIR"
    cd "$WORKDIR"
    if [[ -n "$(ls -A "$WORKDIR" 2>/dev/null)" ]]; then
        log "Le dossier n'est pas vide, nettoyage..."
        rm -f "$WORKDIR"/*
    fi
}

dump_acpi_tables() {
    log "Extraction des tables ACPI (acpidump -b)..."
    acpidump -b
    [[ -f dsdt.dat ]] || die "dsdt.dat introuvable après acpidump. Abandon."
}

disassemble_dsdt() {
    log "Désassemblage de la DSDT (iasl -d dsdt.dat)..."
    iasl -d dsdt.dat
    [[ -f dsdt.dsl ]] || die "dsdt.dsl introuvable après désassemblage. Abandon."
}

download_patch() {
    log "Téléchargement du patch depuis $PATCH_URL..."
    wget -q -O dsdt.patch "$PATCH_URL" || die "Échec du téléchargement du patch."
    [[ -s dsdt.patch ]] || die "Le fichier de patch téléchargé est vide."
}

apply_patch() {
    log "Application du patch sur dsdt.dsl..."
    cp dsdt.dsl dsdt.dsl.orig.bak
    if ! patch dsdt.dsl < dsdt.patch; then
        err "Le patch ne s'est pas appliqué proprement."
        err "Cela peut arriver si votre DSDT diffère de celle visée par ce patch (autre modèle/BIOS)."
        die "Abandon : aucune modification n'a été faite sur /boot, GRUB ou systemd-boot."
    fi
}

reassemble_dsdt() {
    log "Réassemblage de la DSDT patchée (iasl -sa dsdt.dsl)..."
    iasl -sa dsdt.dsl
    [[ -f dsdt.aml ]] || die "dsdt.aml introuvable après réassemblage. Abandon."
}

install_dsdt() {
    log "Copie de dsdt.aml vers $DSDT_TARGET..."
    cp dsdt.aml "$DSDT_TARGET"
}

### ---- Méthode GRUB : entrée de menu explicite, autonome ----
# On n'utilise plus la simple directive "acpi" au niveau racine de
# 40_custom : certains systèmes (comme ce test) n'ont pas de script
# /etc/grub.d/10_linux pour générer les entrées linux/initrd automatiques,
# donc rien ne consomme cette table. On écrit donc une entrée de menu
# GRUB complète et indépendante, avec les bons chemins calculés via
# grub-mkrelpath (qui gère correctement le cas où /boot EST la partition
# EFI elle-même, où "acpi /boot/dsdt.aml" serait un chemin incorrect).
# L'ancienne UKI n'est JAMAIS déplacée ni supprimée : cette entrée est
# ajoutée en plus, jamais définie par défaut automatiquement.

create_grub_menuentry() {
    log "Création d'une entrée GRUB explicite (indépendante de 10_linux)..."

    local kernel_abs initramfs_abs
    case "$FAMILY" in
        arch)
            kernel_abs="/boot/vmlinuz-linux"
            initramfs_abs="/boot/initramfs-linux.img"
            ;;
        debian)
            kernel_abs="/boot/vmlinuz-$(uname -r)"
            initramfs_abs="/boot/initrd.img-$(uname -r)"
            ;;
        fedora)
            kernel_abs="/boot/vmlinuz-$(uname -r)"
            initramfs_abs="/boot/initramfs-$(uname -r).img"
            ;;
    esac
    [[ -f "$kernel_abs" ]]    || die "Image noyau introuvable : $kernel_abs (le système utilise peut-être encore une UKI)"
    [[ -f "$initramfs_abs" ]] || die "Initramfs introuvable : $initramfs_abs (le système utilise peut-être encore une UKI)"

    local ucode_abs=""
    for u in /boot/amd-ucode.img /boot/intel-ucode.img; do
        [[ -f "$u" ]] && ucode_abs="$u"
    done

    command -v grub-mkrelpath >/dev/null 2>&1 || die "grub-mkrelpath introuvable (paquet grub non installé ?)."

    local grub_dsdt grub_kernel grub_initramfs grub_ucode=""
    grub_dsdt="$(grub-mkrelpath "$DSDT_TARGET")"
    grub_kernel="$(grub-mkrelpath "$kernel_abs")"
    grub_initramfs="$(grub-mkrelpath "$initramfs_abs")"
    [[ -n "$ucode_abs" ]] && grub_ucode="$(grub-mkrelpath "$ucode_abs")"

    local root_opts
    root_opts="$(sed -E 's/BOOT_IMAGE=[^ ]*//; s/initrd=[^ ]*//' /proc/cmdline | xargs)"

    mkdir -p "$(dirname "$GRUB_CUSTOM")"
    local marker="### fix-touchpad-dsdt.sh: entrée ACPI DSDT patchée ###"
    if [[ -f "$GRUB_CUSTOM" ]] && grep -qF "$marker" "$GRUB_CUSTOM"; then
        log "Entrée déjà présente dans $GRUB_CUSTOM, rien à faire."
        return
    fi

    {
        echo ""
        echo "$marker"
        echo "menuentry '${GRUB_ENTRY_TITLE}' {"
        echo "    acpi $grub_dsdt"
        echo "    linux $grub_kernel $root_opts"
        if [[ -n "$grub_ucode" ]]; then
            echo "    initrd $grub_ucode $grub_initramfs"
        else
            echo "    initrd $grub_initramfs"
        fi
        echo "}"
    } >> "$GRUB_CUSTOM"

    log "Entrée ajoutée à $GRUB_CUSTOM, en plus des entrées existantes."
    warn "Les anciennes UKI ne sont ni déplacées ni supprimées : elles restent accessibles au menu."
}

set_grub_default() {
    log "Passage de cette entrée en choix par défaut de GRUB..."
    local def_file="/etc/default/grub"
    [[ -f "$def_file" ]] || die "$def_file introuvable."

    if [[ ! -f "${def_file}.bak" ]]; then
        cp "$def_file" "${def_file}.bak"
        log "Sauvegarde créée : ${def_file}.bak"
    fi

    sed -i '/^GRUB_DEFAULT=/d' "$def_file"
    printf 'GRUB_DEFAULT="%s"\n' "$GRUB_ENTRY_TITLE" >> "$def_file"
    log "GRUB_DEFAULT défini sur : $GRUB_ENTRY_TITLE"
}

regen_grub_config() {
    log "Régénération de la configuration GRUB..."
    case "$FAMILY" in
        arch)
            grub-mkconfig -o /boot/grub/grub.cfg
            ;;
        debian)
            if command -v update-grub >/dev/null 2>&1; then
                update-grub
            else
                grub-mkconfig -o /boot/grub/grub.cfg
            fi
            ;;
        fedora)
            if [[ -d /sys/firmware/efi ]]; then
                CFG="/boot/efi/EFI/fedora/grub.cfg"
            else
                CFG="/boot/grub2/grub.cfg"
            fi
            grub2-mkconfig -o "$CFG"
            ;;
    esac
}

### ---- Méthode systemd-boot : early cpio + entrées de boot ----
# Le noyau charge une table ACPI de remplacement si elle est présente dans
# un segment cpio NON COMPRESSÉ, placé avant l'initrd principal. On construit
# donc un mini-cpio contenant kernel/firmware/acpi/dsdt.aml, et on l'ajoute
# comme ligne "initrd" supplémentaire (avant l'initrd principal) dans les
# entrées de boot systemd-boot. C'est la méthode documentée par le noyau,
# identique à celle utilisée pour le microcode CPU.

find_esp_dir() {
    if command -v bootctl >/dev/null 2>&1; then
        local esp
        esp="$(bootctl --print-esp-path 2>/dev/null || true)"
        if [[ -n "$esp" ]]; then
            ESP_DIR="$esp"
            return
        fi
    fi
    for candidate in /boot /boot/efi /efi; do
        if [[ -d "$candidate/loader" ]] || [[ -d "$candidate/EFI" ]]; then
            ESP_DIR="$candidate"
            return
        fi
    done
    die "Impossible de localiser la partition ESP (ni bootctl, ni /boot/loader, ni /boot/efi)."
}

build_acpi_override_cpio() {
    log "Construction du segment cpio non compressé pour l'override ACPI..."
    local override_dir="$WORKDIR/acpi_override"
    rm -rf "$override_dir"
    mkdir -p "$override_dir/kernel/firmware/acpi"
    cp dsdt.aml "$override_dir/kernel/firmware/acpi/dsdt.aml"
    ( cd "$override_dir" && find kernel -print0 | cpio -0 -H newc --create ) > "$ESP_DIR/acpi_override.img" \
        || die "Échec de la création de l'archive cpio."
    log "Créé : $ESP_DIR/acpi_override.img"
}

# Insère "initrd /acpi_override.img" juste avant la première ligne "initrd"
# existante d'un fichier d'entrée systemd-boot (idempotent).
patch_entry_file() {
    local entry="$1"
    grep -q '^initrd[[:space:]]\+/acpi_override\.img$' "$entry" && return 0
    grep -q '^linux[[:space:]]' "$entry" || return 0   # pas une vraie entrée boot
    local tmp
    tmp="$(mktemp)"
    local inserted=0
    while IFS= read -r line; do
        if [[ $inserted -eq 0 && "$line" =~ ^initrd[[:space:]] ]]; then
            echo "initrd  /acpi_override.img" >> "$tmp"
            inserted=1
        fi
        echo "$line" >> "$tmp"
    done < "$entry"
    # Si le fichier n'avait aucune ligne initrd, on l'ajoute après "linux"
    if [[ $inserted -eq 0 ]]; then
        rm -f "$tmp"; tmp="$(mktemp)"
        while IFS= read -r line; do
            echo "$line" >> "$tmp"
            if [[ "$line" =~ ^linux[[:space:]] ]]; then
                echo "initrd  /acpi_override.img" >> "$tmp"
            fi
        done < "$entry"
    fi
    mv "$tmp" "$entry"
    log "Entrée patchée : $entry"
}

systemd_boot_classic_patch() {
    local entries_dir="$ESP_DIR/loader/entries"
    local found=0
    if [[ -d "$entries_dir" ]]; then
        shopt -s nullglob
        for f in "$entries_dir"/*.conf; do
            if grep -q '^linux[[:space:]]' "$f" 2>/dev/null; then
                found=1
                patch_entry_file "$f"
            fi
        done
        shopt -u nullglob
    fi
    [[ $found -eq 1 ]]
}

# Détecte si le système est configuré pour démarrer via une UKI (Unified
# Kernel Image) plutôt qu'un couple noyau+initramfs classique. Dans ce cas,
# ni la commande "acpi" de GRUB, ni les entrées systemd-boot classiques ne
# peuvent s'appliquer : le noyau et l'initrd sont packagés ensemble dans un
# .efi autonome, chainloadé indépendamment de tout override.
is_arch_uki_active() {
    [[ "$FAMILY" == "arch" ]] || return 1
    local preset="/etc/mkinitcpio.d/linux.preset"
    [[ -f "$preset" ]] || return 1
    grep -qE '^\s*default_uki=' "$preset"
}

# Convertit le preset mkinitcpio d'Arch pour produire une image classique
# (vmlinuz + initramfs séparés) au lieu d'une UKI, régénère les images, et
# déplace les anciennes UKI hors de /boot/EFI/Linux (nécessaire pour que le
# hook GRUB "15_uki" cesse de les chainloader en priorité, et pour que
# "10_linux" génère de vraies entrées linux/initrd).
ensure_arch_classic_images() {
    is_arch_uki_active || return 0
    log "Configuration UKI détectée sur Arch : conversion vers un boot classique (nécessaire pour l'override ACPI, quel que soit le bootloader)..."

    local preset="/etc/mkinitcpio.d/linux.preset"
    cp "$preset" "${preset}.bak"
    cat > "$preset" <<EOF
# mkinitcpio preset file for the 'linux' package (modifié : override ACPI)
ALL_kver="/boot/vmlinuz-linux"
PRESETS=('default' 'fallback')
default_image="/boot/initramfs-linux.img"
fallback_image="/boot/initramfs-linux-fallback.img"
fallback_options="-S autodetect"
EOF
    log "Preset modifié (sauvegarde : ${preset}.bak). Régénération des images..."
    mkinitcpio -P
    log "Images classiques générées. Les anciennes UKI restent en place dans /boot/EFI/Linux (non touchées)."
}

systemd_boot_classic_patch() {
    local entries_dir="$ESP_DIR/loader/entries"
    local found=0
    if [[ -d "$entries_dir" ]]; then
        shopt -s nullglob
        for f in "$entries_dir"/*.conf; do
            if grep -q '^linux[[:space:]]' "$f" 2>/dev/null; then
                found=1
                patch_entry_file "$f"
            fi
        done
        shopt -u nullglob
    fi
    [[ $found -eq 1 ]]
}

# Crée des entrées systemd-boot génériques pointant vers les images
# classiques (utilisé quand aucune entrée n'existait déjà, typiquement après
# ensure_arch_classic_images, ou sur un système déjà classique sans entrée).
create_systemd_boot_entries() {
    local vmlinuz initramfs initramfs_fb
    case "$FAMILY" in
        arch)
            vmlinuz="/vmlinuz-linux"
            initramfs="/initramfs-linux.img"
            initramfs_fb="/initramfs-linux-fallback.img"
            ;;
        *)
            warn "Création automatique d'entrées systemd-boot non prise en charge pour $FAMILY."
            warn "Le fichier $ESP_DIR/acpi_override.img a été créé ; ajoutez-le manuellement"
            warn "comme ligne 'initrd' (avant l'initrd principal) dans votre entrée de boot."
            return 1
            ;;
    esac

    [[ -f "$ESP_DIR$vmlinuz" ]] || { warn "Image noyau introuvable : $ESP_DIR$vmlinuz"; return 1; }

    local root_opts
    root_opts="$(sed -E 's/BOOT_IMAGE=[^ ]*//; s/initrd=[^ ]*//' /proc/cmdline | xargs)"

    local ucode_line=""
    for u in "$ESP_DIR"/amd-ucode.img "$ESP_DIR"/intel-ucode.img; do
        [[ -f "$u" ]] && ucode_line="initrd  /$(basename "$u")"
    done

    mkdir -p "$ESP_DIR/loader/entries"
    {
        echo "title   Arch Linux"
        echo "linux   $vmlinuz"
        [[ -n "$ucode_line" ]] && echo "$ucode_line"
        echo "initrd  /acpi_override.img"
        echo "initrd  $initramfs"
        echo "options $root_opts"
    } > "$ESP_DIR/loader/entries/arch.conf"

    if [[ -f "$ESP_DIR$initramfs_fb" ]]; then
        {
            echo "title   Arch Linux (fallback)"
            echo "linux   $vmlinuz"
            [[ -n "$ucode_line" ]] && echo "$ucode_line"
            echo "initrd  /acpi_override.img"
            echo "initrd  $initramfs_fb"
            echo "options $root_opts"
        } > "$ESP_DIR/loader/entries/arch-fallback.conf"
    fi

    log "Entrées créées : $ESP_DIR/loader/entries/arch.conf (PAS définie par défaut, à choisir manuellement au menu)."
}

apply_systemd_boot_override() {
    find_esp_dir
    build_acpi_override_cpio

    if systemd_boot_classic_patch; then
        log "Entrées systemd-boot classiques trouvées et patchées avec succès."
        return
    fi

    log "Aucune entrée de boot classique trouvée."
    create_systemd_boot_entries || true
}

main() {
    require_root
    detect_distro
    detect_bootloader
    install_dependencies
    prepare_workdir
    dump_acpi_tables
    disassemble_dsdt
    download_patch
    apply_patch
    reassemble_dsdt

    # La conversion UKI -> classique doit se faire AVANT la configuration du
    # bootloader, quel que soit celui-ci : sans elle, ni "acpi" (GRUB) ni les
    # entrées systemd-boot classiques ne peuvent s'appliquer.
    ensure_arch_classic_images

    case "$BOOTLOADER" in
        grub)
            install_dsdt
            create_grub_menuentry
            set_grub_default
            regen_grub_config
            ;;
        systemd-boot)
            install_dsdt
            apply_systemd_boot_override
            ;;
    esac

    log "Terminé ! Redémarrez la machine."
    if [[ "$BOOTLOADER" == "grub" ]]; then
        log "L'entrée '${GRUB_ENTRY_TITLE}' est maintenant celle par défaut."
        log "En cas de souci : /etc/default/grub.bak permet de revenir en arrière"
        log "(sudo cp /etc/default/grub.bak /etc/default/grub && sudo grub-mkconfig -o /boot/grub/grub.cfg)."
    else
        log "Sélectionnez manuellement la nouvelle entrée dans le menu systemd-boot pour tester."
    fi
    log "Fichiers de travail conservés dans : $WORKDIR (dont dsdt.dsl.orig.bak, sauvegarde avant patch)"
    log "Vérification après redémarrage : sudo dmesg | grep -i dsdt (doit afficher 00001001, pas 00001000)"
}

main "$@"
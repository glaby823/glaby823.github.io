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
GRUB_LINE="acpi ${DSDT_TARGET}"

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

### ---- Méthode GRUB : directive native "acpi", pas d'initrd impliqué ----

update_grub_custom() {
    log "Mise à jour de $GRUB_CUSTOM..."
    mkdir -p "$(dirname "$GRUB_CUSTOM")"
    if [[ -f "$GRUB_CUSTOM" ]] && grep -qF "$GRUB_LINE" "$GRUB_CUSTOM"; then
        log "La ligne est déjà présente, rien à faire."
    else
        printf '\n%s\n' "$GRUB_LINE" >> "$GRUB_CUSTOM"
        log "Ligne ajoutée : $GRUB_LINE"
    fi
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

# Sur Arch, convertit un setup UKI (arch-linux.efi) en boot classique
# (vmlinuz + initramfs séparés) pour pouvoir y attacher l'override ACPI, et
# crée les entrées de boot correspondantes.
convert_arch_uki_to_classic() {
    log "Configuration UKI détectée : conversion vers un boot classique (nécessaire pour l'override ACPI)..."

    local preset="/etc/mkinitcpio.d/linux.preset"
    [[ -f "$preset" ]] || die "Preset mkinitcpio introuvable : $preset"
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

    local root_opts kver
    root_opts="$(sed -E 's/BOOT_IMAGE=[^ ]*//; s/initrd=[^ ]*//' /proc/cmdline | xargs)"
    kver="$(uname -r)"

    local ucode_line=""
    for u in "$ESP_DIR"/amd-ucode.img "$ESP_DIR"/intel-ucode.img; do
        [[ -f "$u" ]] && ucode_line="initrd  /$(basename "$u")"
    done

    mkdir -p "$ESP_DIR/loader/entries"
    cat > "$ESP_DIR/loader/entries/arch.conf" <<EOF
title   Arch Linux
linux   /vmlinuz-linux
${ucode_line}
initrd  /acpi_override.img
initrd  /initramfs-linux.img
options ${root_opts}
EOF
    cat > "$ESP_DIR/loader/entries/arch-fallback.conf" <<EOF
title   Arch Linux (fallback)
linux   /vmlinuz-linux
${ucode_line}
initrd  /acpi_override.img
initrd  /initramfs-linux-fallback.img
options ${root_opts}
EOF
    # Nettoyage des lignes vides si pas de microcode
    sed -i '/^$/d' "$ESP_DIR/loader/entries/arch.conf" "$ESP_DIR/loader/entries/arch-fallback.conf"

    sed -i '/^default /d' "$ESP_DIR/loader/loader.conf" 2>/dev/null || true
    echo "default arch.conf" >> "$ESP_DIR/loader/loader.conf"

    log "Entrées créées et définies par défaut : $ESP_DIR/loader/entries/arch.conf"
    warn "Les anciennes images UKI (arch-linux*.efi) restent en place mais ne sont plus utilisées ;"
    warn "vous pouvez les supprimer une fois le bon fonctionnement confirmé après redémarrage."
}

apply_systemd_boot_override() {
    find_esp_dir
    build_acpi_override_cpio

    if systemd_boot_classic_patch; then
        log "Entrées systemd-boot classiques trouvées et patchées avec succès."
        return
    fi

    log "Aucune entrée de boot classique trouvée : setup probablement basé sur une UKI."
    case "$FAMILY" in
        arch)
            convert_arch_uki_to_classic
            ;;
        fedora|debian)
            warn "Setup UKI détecté sur $FAMILY : la conversion automatique n'est pas prise en"
            warn "charge par ce script (mécanismes trop variables selon les versions de dracut/"
            warn "systemd). Le fichier $ESP_DIR/acpi_override.img a été créé ; il faut l'ajouter"
            warn "manuellement comme ligne 'initrd' (avant l'initrd principal) dans votre entrée"
            warn "de boot ou reconstruire votre UKI en incluant ce segment en tête de l'initrd."
            ;;
    esac
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

    case "$BOOTLOADER" in
        grub)
            install_dsdt
            update_grub_custom
            regen_grub_config
            ;;
        systemd-boot)
            install_dsdt
            apply_systemd_boot_override
            ;;
    esac

    log "Terminé ! Redémarrez la machine pour que le touchpad soit pris en compte."
    log "Fichiers de travail conservés dans : $WORKDIR (dont dsdt.dsl.orig.bak, sauvegarde avant patch)"
    log "Vérification après redémarrage : sudo dmesg | grep -i dsdt (doit afficher 00001001, pas 00001000)"
}

main "$@"
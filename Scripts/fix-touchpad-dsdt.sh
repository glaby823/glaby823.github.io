#!/usr/bin/env bash
#
# fix-touchpad-dsdt.sh
#
# Automatise le patch ACPI DSDT pour corriger le touchpad sur certains
# laptops Lenovo AMD, sur Arch, Ubuntu/Debian et Fedora.
#
# Basé sur un guide manuel, avec correction de deux coquilles :
#   - "patch dsdt.dsl < dstd.patch"  ->  "< dsdt.patch"
#   - "sudo udpate-grub"             ->  bonne commande selon la distro
#
# Usage :
#   chmod +x fix-touchpad-dsdt.sh
#   sudo ./fix-touchpad-dsdt.sh
#
# ATTENTION : ce patch est spécifique à un modèle de DSDT donné
# (Lenovo/AMD). S'il ne s'applique pas proprement sur votre machine,
# le script s'arrête sans rien modifier sur le système.

set -euo pipefail

# ---------- Réglages ----------
WORKDIR="${SUDO_USER:+/home/$SUDO_USER}/acpi"
WORKDIR="${WORKDIR:-$HOME/acpi}"
PATCH_URL="https://launchpadlibrarian.net/738328314/dsdt.patch"
DSDT_TARGET="/boot/dsdt.aml"
GRUB_CUSTOM="/etc/grub.d/40_custom"
GRUB_LINE="acpi ${DSDT_TARGET}"

# ---------- Fonctions utilitaires ----------
log()  { echo -e "\n\033[1;34m==>\033[0m $*"; }
err()  { echo -e "\033[1;31mErreur:\033[0m $*" >&2; }
die()  { err "$*"; exit 1; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Ce script doit être lancé avec sudo (il modifie /boot et /etc/grub.d)."
    fi
}

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_ID_LIKE="${ID_LIKE:-}"
    else
        die "Impossible de détecter la distribution (/etc/os-release introuvable)."
    fi

    case "$DISTRO_ID" in
        arch|manjaro|endeavouros)
            FAMILY="arch" ;;
        ubuntu|debian|linuxmint|pop)
            FAMILY="debian" ;;
        fedora)
            FAMILY="fedora" ;;
        *)
            case "$DISTRO_ID_LIKE" in
                *arch*)           FAMILY="arch" ;;
                *debian*)         FAMILY="debian" ;;
                *fedora*|*rhel*)  FAMILY="fedora" ;;
                *) die "Distribution '$DISTRO_ID' non supportée (arch / debian-ubuntu / fedora uniquement)." ;;
            esac
            ;;
    esac
    log "Distribution détectée : $DISTRO_ID (famille : $FAMILY)"
}

detect_bootloader() {
    if [[ -d /etc/grub.d ]] && command -v grub-mkconfig >/dev/null 2>&1 || command -v grub2-mkconfig >/dev/null 2>&1; then
        BOOTLOADER="grub"
    elif [[ -f /boot/loader/loader.conf ]] || command -v bootctl >/dev/null 2>&1; then
        BOOTLOADER="systemd-boot"
    else
        die "Bootloader non détecté (ni GRUB ni systemd-boot). Ce script ne gère que ces deux-là."
    fi
    log "Bootloader détecté : $BOOTLOADER"
}

install_dependencies() {
    log "Installation des dépendances (acpica, wget, patch, grub)..."
    case "$FAMILY" in
        arch)
            pacman -Sy --needed --noconfirm acpica wget patch cpio grub
            ;;
        debian)
            apt-get update
            apt-get install -y acpica-tools wget patch cpio grub2-common
            ;;
        fedora)
            dnf install -y acpica-tools wget patch cpio grub2-tools
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
        die "Abandon : aucune modification n'a été faite sur /boot ou /etc/grub.d."
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

### ---- Méthode systemd-boot (et fallback universel) : override via initrd ----
# Le noyau Linux peut charger une DSDT de remplacement si elle se trouve
# dans l'initramfs, au chemin kernel/firmware/acpi/dsdt.aml. On construit
# donc une petite archive cpio contenant ce fichier, et on la préfixe à
# chaque image d'initramfs présente dans /boot (comme pour le microcode).

apply_initrd_override() {
    log "Intégration de dsdt.aml dans l'initramfs (méthode systemd-boot)..."

    local override_dir="$WORKDIR/acpi_override"
    rm -rf "$override_dir"
    mkdir -p "$override_dir/kernel/firmware/acpi"
    cp dsdt.aml "$override_dir/kernel/firmware/acpi/dsdt.aml"

    ( cd "$override_dir" && find kernel -print0 | cpio -0 -H newc --create ) > "$WORKDIR/acpi_override.cpio" \
        || die "Échec de la création de l'archive cpio."

    shopt -s nullglob
    local images=(/boot/initramfs-*.img)
    shopt -u nullglob
    [[ ${#images[@]} -gt 0 ]] || die "Aucun fichier initramfs trouvé dans /boot (chemin attendu : /boot/initramfs-*.img)."

    for img in "${images[@]}"; do
        local orig="${img}.orig"
        # On garde toujours une copie de l'initramfs "propre" (sans override)
        # pour pouvoir régénérer proprement, y compris après un rerun du script.
        if [[ ! -f "$orig" ]]; then
            cp "$img" "$orig"
        fi
        cat "$WORKDIR/acpi_override.cpio" "$orig" > "$img"
        log "Table ACPI intégrée dans : $img"
    done

    setup_pacman_hook_if_arch
}

# Sur Arch, chaque mise à jour du noyau régénère l'initramfs et écraserait
# notre modification. On installe un hook pacman qui réapplique
# automatiquement l'override après chaque régénération de mkinitcpio.
setup_pacman_hook_if_arch() {
    [[ "$FAMILY" == "arch" ]] || return 0

    local reapply_script="/usr/local/bin/reapply-acpi-override.sh"
    local hook_file="/etc/pacman.d/hooks/95-acpi-override.hook"

    cat > "$reapply_script" <<EOF
#!/usr/bin/env bash
# Généré par fix-touchpad-dsdt.sh : réapplique l'override ACPI dans
# l'initramfs après chaque régénération par mkinitcpio.
set -e
CPIO="$WORKDIR/acpi_override.cpio"
[[ -f "\$CPIO" ]] || exit 0
shopt -s nullglob
for img in /boot/initramfs-*.img; do
    orig="\${img}.orig"
    if [[ ! -f "\$orig" ]]; then
        cp "\$img" "\$orig"
    fi
    cat "\$CPIO" "\$orig" > "\$img"
done
EOF
    chmod +x "$reapply_script"

    mkdir -p /etc/pacman.d/hooks
    cat > "$hook_file" <<EOF
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = linux
Target = linux-lts
Target = mkinitcpio

[Action]
Description = Réapplication de l'override ACPI DSDT dans l'initramfs
When = PostTransaction
Exec = $reapply_script
EOF
    log "Hook pacman installé : les mises à jour du noyau réappliqueront automatiquement l'override."
}

update_grub_custom() {
    log "Mise à jour de $GRUB_CUSTOM..."
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
            apply_initrd_override
            ;;
    esac

    log "Terminé ! Redémarrez la machine pour que le touchpad soit pris en compte."
    log "Fichiers de travail conservés dans : $WORKDIR (dont dsdt.dsl.orig.bak, sauvegarde avant patch)"
    if [[ "$BOOTLOADER" == "systemd-boot" ]]; then
        log "Note : les images d'initramfs originales sont sauvegardées en *.orig dans /boot."
    fi
}

main "$@"
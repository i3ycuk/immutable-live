#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
ISO_ROOT=${ISO_ROOT:-"${PROJECT_DIR}/disk/boot/iso"}
PERSISTENCE_DIR=${PERSISTENCE_DIR:-"${PROJECT_DIR}/disk/persistence"}
VM_NAME=${VM_NAME:-immutable-live}
MEMORY=${MEMORY:-2G}
VM_STATE_DIR=${VM_STATE_DIR:-"${SCRIPT_DIR}"}
PERSISTENCE_LABEL=persistence

clear

usage() {
	cat <<'EOF'
Запуск immutable-live в QEMU.

Использование:
  run-vm.sh [--dry-run]

Переменные окружения:
  ISO_ROOT          каталог с подкаталогами amd64/arm64
	PERSISTENCE_DIR   исходная папка для ext4-раздела persistence
	VM_STATE_DIR      место образов ВМ (по умолчанию: рядом со скриптом)
	PERSISTENCE_MOUNT_DIR  read-only mountpoint на хосте
  MEMORY            объём памяти QEMU (по умолчанию: 2G)
EOF
}

DRY_RUN=false
case ${1:-} in
	'') ;;
	--dry-run) DRY_RUN=true ;;
	-h|--help) usage; exit 0 ;;
	*) echo "Неизвестный параметр: $1" >&2; usage >&2; exit 2 ;;
esac

case $(uname -m) in
	x86_64|amd64|i386|i486|i586|i686)
		ARCH=amd64
		QEMU=qemu-system-x86_64
		MACHINE=pc
		;;
	aarch64|arm64|armv8*)
		ARCH=arm64
		QEMU=qemu-system-aarch64
		MACHINE=virt
		;;
	*)
		echo "Неподдерживаемая архитектура процессора: $(uname -m)" >&2
		exit 1
		;;
esac

ISO_DIR=${ISO_ROOT}/${ARCH}
[[ -d ${ISO_DIR} ]] || { echo "Каталог ISO не найден: ${ISO_DIR}" >&2; exit 1; }
[[ -d ${PERSISTENCE_DIR} ]] || { echo "Каталог persistence не найден: ${PERSISTENCE_DIR}" >&2; exit 1; }

mapfile -d '' ISO_FILES < <(find "${ISO_DIR}" -maxdepth 1 -type f \
	\( -iname '*.iso' -o -iname '*.img' \) -print0 | sort -z)
[[ ${#ISO_FILES[@]} -gt 0 ]] || { echo "В ${ISO_DIR} нет ISO/IMG-файлов" >&2; exit 1; }

PERSISTENCE_BASE=${VM_STATE_DIR}/persistence-base.ext4
PERSISTENCE_OVERLAY=${VM_STATE_DIR}/persistence-overlay.qcow2
PERSISTENCE_FINGERPRINT=${VM_STATE_DIR}/persistence.sha256
PERSISTENCE_MOUNT_DIR=${PERSISTENCE_MOUNT_DIR:-"${VM_STATE_DIR}/persistence-mount"}
PERSISTENCE_SIZE=${PERSISTENCE_SIZE:-512M}

persistence_fingerprint() {
	tar -C "${PERSISTENCE_DIR}" --sort=name --mtime='UTC 1970-01-01' \
		--owner=0 --group=0 --numeric-owner -cf - . | sha256sum | cut -d' ' -f1
}

QEMU_ARGS=(
	-name "${VM_NAME}"
	-machine "${MACHINE}"
	-m "${MEMORY}"
	-boot menu=on,strict=on
	-display default
	-no-reboot
	-drive "file=${PERSISTENCE_OVERLAY},format=qcow2,if=virtio,media=disk"
)

if [[ -e /dev/kvm ]]; then
	QEMU_ARGS+=(-enable-kvm)
fi

for iso in "${ISO_FILES[@]}"; do
	QEMU_ARGS+=(-drive "file=${iso},media=cdrom,readonly=on")
done

printf 'Архитектура: %s\nISO: %s\nPersistence base (ext4, label=%s): %s\nPersistence writes: %s\n' \
	"${ARCH}" "${#ISO_FILES[@]} файл(ов)" "${PERSISTENCE_LABEL}" "${PERSISTENCE_DIR}" "${PERSISTENCE_OVERLAY}"

if [[ ${DRY_RUN} = true ]]; then
	printf '%q ' "${QEMU}" "${QEMU_ARGS[@]}"
	printf '\n'
	exit 0
fi

command -v mke2fs >/dev/null 2>&1 || { echo "Не найден mke2fs (пакет e2fsprogs)" >&2; exit 1; }
command -v qemu-img >/dev/null 2>&1 || { echo "Не найден qemu-img (пакет qemu-utils)" >&2; exit 1; }
command -v "${QEMU}" >/dev/null 2>&1 || {
	echo "Не найден ${QEMU}. Установите пакет qemu-system-${ARCH}." >&2
	exit 1
}
command -v mount >/dev/null 2>&1 || { echo "Не найден mount (пакет util-linux)" >&2; exit 1; }
command -v umount >/dev/null 2>&1 || { echo "Не найден umount (пакет util-linux)" >&2; exit 1; }
command -v mountpoint >/dev/null 2>&1 || { echo "Не найден mountpoint (пакет util-linux)" >&2; exit 1; }

mkdir -p "${VM_STATE_DIR}"
mkdir -p "${PERSISTENCE_MOUNT_DIR}"
STORED_PERSISTENCE_FINGERPRINT=
if [[ -f ${PERSISTENCE_FINGERPRINT} ]]; then
	read -r STORED_PERSISTENCE_FINGERPRINT < "${PERSISTENCE_FINGERPRINT}"
fi

CURRENT_PERSISTENCE_FINGERPRINT=$(persistence_fingerprint)

if [[ ${CURRENT_PERSISTENCE_FINGERPRINT} != "${STORED_PERSISTENCE_FINGERPRINT}" ||
	! -f ${PERSISTENCE_BASE} || ! -f ${PERSISTENCE_OVERLAY} ]]; then
	if mountpoint -q "${PERSISTENCE_MOUNT_DIR}"; then
		umount "${PERSISTENCE_MOUNT_DIR}"
	fi
	rm -f "${PERSISTENCE_BASE}" "${PERSISTENCE_OVERLAY}"
	mke2fs -q -t ext4 -L "${PERSISTENCE_LABEL}" -d "${PERSISTENCE_DIR}" "${PERSISTENCE_BASE}" "${PERSISTENCE_SIZE}"
	qemu-img create -q -f qcow2 -F raw -b "${PERSISTENCE_BASE}" "${PERSISTENCE_OVERLAY}"
	printf '%s\n' "${CURRENT_PERSISTENCE_FINGERPRINT}" > "${PERSISTENCE_FINGERPRINT}"
fi

if ! mountpoint -q "${PERSISTENCE_MOUNT_DIR}"; then
	mount -o loop,ro "${PERSISTENCE_BASE}" "${PERSISTENCE_MOUNT_DIR}"
fi

exec "${QEMU}" "${QEMU_ARGS[@]}"
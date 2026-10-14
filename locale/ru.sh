#!/usr/bin/env bash
# Russian locale for immutable-live installer

declare -gA MSG=(
    # Main titles
    [APP_TITLE]="Установка immutable-live"
    [DIALOG_DRIVE_TITLE]="Выбор целевого накопителя"
    [DIALOG_DRIVE_DESC]="Выберите целевой USB-накопитель для установки immutable-live:\n(Внимание: Все данные на выбранном диске будут стёрты!)"
    [DIALOG_PERSIST_TITLE]="Размер Persistence"
    [DIALOG_PERSIST_DESC]="Выбран накопитель: {DRIVE} ({MODEL}, {SIZE})\n\nУкажите размер раздела Persistence:\n- В процентах: 50%, 75%\n- В мегабайтах/гигабайтах: 4096M, 8G, 16GiB"
    [DIALOG_LUKS_TITLE]="Шифрование LUKS"
    [DIALOG_LUKS_DESC]="Введите пароль для шифрования раздела Persistence (LUKS):\n(Оставьте поле пустым, если шифрование НЕ требуется)"
    [DIALOG_LUKS_CONFIRM_TITLE]="Подтверждение пароля LUKS"
    [DIALOG_LUKS_CONFIRM_DESC]="Повторите пароль LUKS для подтверждения:"
    [DIALOG_HOSTNAME_TITLE]="Имя хоста"
    [DIALOG_HOSTNAME_DESC]="Введите hostname (латинские буквы, цифры и дефис):"
    [DIALOG_USER_TITLE]="Учетная запись"
    [DIALOG_USER_DESC]="Введите имя пользователя Linux:"
    [DIALOG_USERPASS_TITLE]="Пароль пользователя"
    [DIALOG_USERPASS_DESC]="Введите пароль для пользователя {USER}:"
    [DIALOG_USERPASS_CONFIRM_TITLE]="Подтверждение пароля"
    [DIALOG_USERPASS_CONFIRM_DESC]="Повторите пароль пользователя:"
    [DIALOG_AUTOLOGIN_TITLE]="Автоматический вход"
    [DIALOG_AUTOLOGIN_DESC]="Включить автоматический вход для пользователя {USER}?"
    [DIALOG_SWAP_TITLE]="Настройка Swap"
    [DIALOG_SWAP_DESC]="Включить файл подкачки (Swap) на Live USB?"
    [DIALOG_SWAP_SIZE_TITLE]="Размер Swap"
    [DIALOG_SWAP_SIZE_DESC]="Укажите размер Swap (например: 2G, 2048M или 10%):\nОбщий объем накопителя: {SIZE}"
    [DIALOG_WARNING_ROOT_TITLE]="ВНИМАНИЕ: Опасный режим"
    [DIALOG_WARNING_ROOT_DESC]="Вы собираетесь отобразить ВСЕ накопители, включая системные с рабочей ОС.\n\nСлучайный выбор системного диска приведёт к полному уничтожению вашей операционной системы!\n\nОтобразить все накопители?"
    [DIALOG_CRITICAL_TITLE]="КРИТИЧЕСКОЕ ПРЕДУПРЕЖДЕНИЕ"
    [DIALOG_CRITICAL_DESC]="ВНИМАНИЕ! Вы выбрали СИСТЕМНЫЙ ДИСК ({DRIVE}), на котором установлена текущая ОС (/ root).\n\nУстановка на этот диск ПОЛНОСТЬЮ УНИЧТОЖИТ вашу операционную систему!\n\nВы АБСОЛЮТНО уверены, что хотите продолжить?"
    [DIALOG_FINAL_TITLE]="Итоговое подтверждение"
    [DIALOG_SUMMARY]="Параметры установки:
- Накопитель:       {DRIVE} ({MODEL}, {SIZE})
- Persistence:      {PERSIST_MiB} MiB ({PERSIST_INPUT})
- Шифрование LUKS:  {LUKS_STATUS}
- Hostname:         {HOSTNAME}
- Пользователь:     {USER}
- Автовход:         {AUTOLOGIN}
- Swap:             {SWAP_STATUS}

ВНИМАНИЕ: Все существующие разделы и данные на {DRIVE} будут ПОЛНОСТЬЮ УНИЧТОЖЕНЫ!
Продолжить установку?"
    [DIALOG_SUCCESS_TITLE]="Успех"
    [DIALOG_SUCCESS_DESC]="Установка immutable-live на накопитель {DRIVE} успешно завершена!\n\nСкопируйте ваши Live ISO-образы в каталог /iso на USB-накопителе."

    # Error messages
    [ERR_COMMAND_FAILED]="Сбой в строке {LINE} (код {STATUS}): {CMD}. Установка остановлена; накопитель может требовать очистки/повторной разметки."
    [ERR_ROOT_REQUIRED]="Ошибка: Требуются права суперпользователя. Запустите с sudo."
    [ERR_DIALOG_NOT_FOUND]="Ошибка: Не установлен ни whiptail, ни dialog."
    [ERR_DIALOG_CANCELLED]="Установщик отменён или окно завершилось с ошибкой: {CONTEXT}."
    [ERR_NO_DRIVES]="Дисковые накопители не найдены."
    [ERR_NO_USB]="Не обнаружены USB-диски. Показать все накопители, включая системный диск? Его выбор может уничтожить текущую ОС."
    [ERR_PERSIST_TOO_SMALL]="Размер Persistence должен быть не менее 512 MiB."
    [ERR_PERSIST_TOO_LARGE]="Размер Persistence слишком велик. Необходимо оставить минимум 512 MiB для загрузочного раздела Ventoy и ISO-образов."
    [ERR_LUKS_MISMATCH]="Введённые пароли LUKS не совпадают. Попробуйте снова."
    [ERR_HOSTNAME_INVALID]="Некорректный hostname. Используйте буквы, цифры, точку или дефис."
    [ERR_USER_INVALID]="Некорректное имя пользователя. Разрешены строчные латинские буквы, цифры, '_' и '-'."
    [ERR_USERPASS_EMPTY]="Пароль не может быть пустым."
    [ERR_USERPASS_MISMATCH]="Пароли не совпадают. Попробуйте ещё раз."
    [ERR_SWAP_INVALID]="Ошибка: размер Swap должен быть положительным и меньше размера раздела Persistence ({MAX} MiB)."
    [ERR_ENV_EXAMPLE_NOT_FOUND]="Файл .env.example не найден: {PATH}"
    [ERR_VENTOY_FAILED]="Ventoy не создал ожидаемые разделы 1 и 2. Проверьте вывод Ventoy и повторите установку."
    [ERR_PERSISTENCE_PARTITION]="Не удалось создать или обнаружить раздел Persistence ({PART})."
    [ERR_VENTOY_PARTITION]="Не удалось смонтировать раздел Ventoy ({PART}). Возможно, не установлена поддержка ExFAT."
    [ERR_COMMAND_MISSING]="Не найдена обязательная команда: {CMD}"
    [ERR_PARTITION_TOOL_MISSING]="Нужен parted, sfdisk или fdisk для создания persistence-раздела."
    [ERR_LUKS_TOOL_MISSING]="Требуется cryptsetup для LUKS-шифрования."

    # Info/Warning messages
    [INFO_DOWNLOADING_VENTOY]="Ventoy binaries not found in tools/ventoy. Downloading Ventoy..."
    [INFO_STARTING]="Начало подготовки накопителя {DRIVE}..."
    [INFO_UNMOUNTING]="Размонтирование существующих разделов на {DRIVE}..."
    [INFO_INSTALLING_VENTOY]="Установка Ventoy (резервирование {SIZE} MiB в конце диска)..."
    [INFO_LARGE_DISK_GPT]="Накопитель больше 2 TiB: включаю GPT для Ventoy."
    [INFO_CREATING_PERSISTENCE]="Создание раздела Persistence..."
    [INFO_FORMATTING]="Форматирование файловой системы ext4 (label=persistence) на {DEV}..."
    [INFO_LUKS_SETUP]="Настройка шифрования LUKS1 на {PART}..."
    [INFO_DEPLOYING]="Развертывание файлов конфигурации persistence..."
    [INFO_ENV_CREATED]="Создан файл .env из .env.example с правами 600"
    [INFO_CONFIGURING_VENTOY]="Настройка загрузчика Ventoy на разделе {PART}..."
    [INFO_COMPLETE]="Установка успешно завершена!"

    # Drive selection
    [DRIVE_TAG_SYSTEM]="[СИСТЕМА (ROOT)]"
    [DRIVE_TAG_INTERNAL]="[Внутренний диск]"
    [DRIVE_TAG_USB]="[USB/Съемный]"
    [DRIVE_OPTION_SHOW_ALL]="[!] Показать все диски (включая системные)"

    # Labels
    [LABEL_ENABLED]="Включено (LUKS1)"
    [LABEL_DISABLED]="Отключено"
    [LABEL_ENABLED_SWAP]="Включен ({SIZE})"
    [LABEL_DISABLED_SWAP]="Отключен"
    [LABEL_ENABLED_AUTOLOGIN]="Включен"
    [LABEL_DISABLED_AUTOLOGIN]="Отключен"
)
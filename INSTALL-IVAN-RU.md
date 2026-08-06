# Установка из актуального репозитория

Репозиторий:

```text
https://github.com/ivan-panov/remnawave-reverse
```

Запуск последней версии из ветки `main`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ivan-panov/remnawave-reverse/refs/heads/main/install_remnawave.sh)
```

Для загрузки в файл и предварительной проверки:

```bash
cd /root
curl -fL \
  https://raw.githubusercontent.com/ivan-panov/remnawave-reverse/refs/heads/main/install_remnawave.sh \
  -o install_remnawave.sh
chmod +x install_remnawave.sh
bash -n install_remnawave.sh
./install_remnawave.sh
```

Скрипт, языковые файлы и модули обновляются только из ветки `main` этого репозитория. Репозиторий и ветку можно временно переопределить переменными `REMNAWAVE_REVERSE_REPO` и `REMNAWAVE_REVERSE_BRANCH`.

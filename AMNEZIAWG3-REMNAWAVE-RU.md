# AmneziaWG 3.0 → Remnawave

Сборка добавляет пункт:

```text
13. AmneziaWG 3.0 — вход трафика в Remnawave
```

## Схема

```text
Клиент AmneziaWG 3.0
        ↓ UDP
VPS RU: awg0
        ↓ TPROXY TCP/UDP
Remnawave Node / Xray: AWG3_TPROXY_IN
        ↓
выбранный outbound, обычно VLESS_OUT_FL
        ↓
VPS Finland → Интернет
```

## Какая версия устанавливается

Используется официальный `bivlked/amneziawg-installer` **v5.24.0**, закреплённый на неизменяемом commit:

```text
2c86966f59d54c0fd0bcf66639c537558a1a0c25
```

Upstream ставит модуль AmneziaWG 3.0 на x86_64 с ядром Linux 6.7+. На старых ядрах и части ARM-конфигураций upstream может выбрать fallback 2.0. Пункт 13 намеренно блокирует такие хосты и после установки дополнительно проверяет:

```bash
modinfo -F version amneziawg
```

TPROXY включается только если версия начинается с `3.`.

## Требования

- Ubuntu 24.04 на полноценной KVM/VM VPS;
- архитектура x86_64;
- ядро Linux 6.7 или новее;
- Panel и локальная Remnawave Node на VPS RU;
- ноде назначен рабочий Config Profile;
- для выхода RU → FL сначала создаётся пункт 12;
- root, Docker Compose, iptables mangle/TPROXY.

## Установка

```bash
sudo ./install_remnawave.sh
rr
```

1. При необходимости создайте пункт 12 — VLESS-каскад.
2. Откройте пункт 13 → «Создать интеграцию автоматически».
3. Выберите локальную RU-ноду и outbound.
4. Значения по умолчанию: UDP `38389`, подсеть `172.16.17.0/24`, TPROXY `12345`.

Официальный AWG-установщик может перезагрузить VPS дважды. Служба продолжения возобновляет установку автоматически.

Проверка после загрузки:

```bash
modinfo -F version amneziawg
systemctl status awg-quick@awg0 --no-pager
systemctl status remnawave-awg3-tproxy --no-pager
journalctl -u remnawave-awg3-bootstrap -u remnawave-awg3-tproxy --no-pager -n 150
```

## Откат

Пункт 13 поддерживает отключение, повторное включение и полное удаление. Исходный Config Profile сохраняется до клонирования. При полном удалении восстанавливается исходное назначение профиля и при необходимости удаляется установленный модулем AmneziaWG.

## Обновление старой AWG2-интеграции

Если пункт 13 из предыдущей сборки уже использовался, сначала удалите интеграцию через старую сборку. Затем установите эту версию и создайте пункт 13 заново. Одновременное использование служб `remnawave-awg2-*` и `remnawave-awg3-*` не поддерживается.

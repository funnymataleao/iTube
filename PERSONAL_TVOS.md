# iTube для Apple TV

Нативная tvOS-сборка iTube на основе исторического модуля SmartTubeIOS. Лицензия и история upstream
сохранены; основной репозиторий проекта подключён как `upstream`.

## Установка через Xcode

1. Откройте `SmartTube.xcworkspace`.
2. Выберите схему **iTube**.
3. Выберите спаренную Apple TV или Apple TV 4K Simulator.
4. В Signing & Capabilities выберите свою Personal Team, если Xcode попросит.
5. Нажмите Run.

Приложение устанавливается напрямую на Apple TV. Для входа откройте Settings →
Sign In и завершите device-code flow на телефоне или Mac.

## Обновление из upstream

```sh
git fetch upstream
git switch personal-tvos
git merge upstream/main
```

После разрешения возможных конфликтов соберите и запустите схему **iTube**
ещё раз. Установка поверх существующей версии сохраняет локальные настройки и
данные входа в Keychain.

## Основные отличия tvOS-сборки

- персональная Home-лента с полками YouTube и тематическими категориями;
- отдельные вкладки Subscriptions, Search и History;
- AVPlayer без рекламных вставок YouTube;
- SponsorBlock и DeArrow;
- минимальные настройки для гостиной;
- Firebase/Crashlytics и `GoogleService-Info.plist` не входят в tvOS-бандл.

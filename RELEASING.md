# Публикация автообновлений macOS

Sparkle получает подписанный appcast по HTTPS. В приложение встраивается только открытый EdDSA-ключ. Закрытый ключ нужен при подготовке каждого выпуска. Храните его в Keychain или в закрытом хранилище релизов. Не включайте его в исходники, логи, приложение и GitHub Release.

## Настроить канал один раз

1. Создайте постоянный HTTPS-адрес ленты. Для GitHub Releases можно использовать `https://github.com/fqfqfqff/still-snow/releases/latest/download/appcast.xml`. Этот адрес предназначен для опубликованных стабильных релизов. Для pre-release используйте отдельную постоянную ссылку и отдельно публикуемый канал.
2. Для существующего канала используйте открытый ключ из `release/macos-public-key.txt` и соответствующий закрытый ключ. Для нового независимого канала получите новую пару командой ниже. Sparkle создаст закрытую часть в Keychain. Для автоматизации её можно экспортировать с `-x` в защищённое место.

```sh
sparkle="$(./scripts/fetch-sparkle.sh)"
"$sparkle/bin/generate_keys" --account still-snow
"$sparkle/bin/generate_keys" --account still-snow -p
```

3. Перед первым публичным выпуском соберите приложение с реальными значениями, затем проверьте подписанную ленту на отдельной копии. Приложения, которые были собраны без ленты, потребуют однократной замены через DMG.

## Подготовить очередной выпуск

```sh
export STILLSNOW_UPDATE_FEED='https://github.com/fqfqfqff/still-snow/releases/latest/download/appcast.xml'
export STILLSNOW_UPDATE_PUBLIC_KEY="$(cat release/macos-public-key.txt)"
export STILLSNOW_VERSION='0.1.2'
export STILLSNOW_BUILD_NUMBER=3
./scripts/test-macos.sh
./scripts/build-macos.sh
./scripts/package-macos.sh
```

Увеличивайте номер сборки при каждом выпуске. Сборочный скрипт по умолчанию подписывает приложение ad hoc. Для публичных сборок с Developer ID подпишите и нотариализуйте приложение перед упаковкой. Перед выпуском проверяйте обновление именно с предыдущей распространяемой версии.

Сохраните подписанный и финальный .app в ZIP. Из этого архива Sparkle установит обновление. DMG остаётся форматом первой установки.

```sh
mkdir -p build/release
ditto -c -k --sequesterRsrc --keepParent 'build/Still Snow.app' build/release/StillSnow-0.1.2-arm64.zip
export STILLSNOW_UPDATE_PRIVATE_KEY_FILE='/private/path/to/ed25519-key'
./scripts/generate-appcast.sh build/release 'https://github.com/fqfqfqff/still-snow/releases/download/v0.1.2'
```

Загрузите `appcast.xml`, ZIP и установочный DMG в один релиз. Публикуйте их вместе, чтобы ссылка на скачивание работала к моменту появления новой ленты. После подписания изменения в XML требуют новой подписи.

[Подготовка подписанного appcast в Sparkle](https://sparkle-project.org/documentation/) · [Публикация обновлений](https://sparkle-project.org/documentation/publishing/)

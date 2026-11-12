# dayz-flux-boot

Публичное зеркало bootstrap-файлов основного репозитория **git.sts.co.ua/sts/dayz_serv**
(там приватный Forgejo требует логина, а Flux-ноде нужен анонимный fetch).

- `docker/bootstrap.sh` — ставит зависимости и steamcmd, забирает entrypoint и конфиги
- `docker/entrypoint.sh` — логика старта сервера
- `config/*` — serverDZ.cfg, mods.txt, BEServer_x64.cfg.tpl

Секретов здесь нет: пароли приходят в env приложения.

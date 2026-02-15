file_size dir:
    fd -t f . {{ dir }} --exec stat -f%z {}

total_file_size dir:
    fd -t f . {{ dir }} --exec stat -f%z {} | awk '{sum+=$1} END {print sum}'

server_dev:
    cd server && \
    watchexec \
        --debounce 500ms \
        --restart \
        --watch src \
        --watch test \
        --watch assets \
        --watch gleam.toml \
        -- 'sleep 2 && npx @tailwindcss/cli -i ./assets/css/app.css -o ./priv/static/css/app.css && GLEAM_CODESEARCH_INDEX="../_index/gleam_packages.json" gleam run'

server:
    cd server && npx @tailwindcss/cli -i ./assets/css/app.css -o ./priv/static/css/app.css --minify && GLEAM_CODESEARCH_INDEX="../_index/gleam_packages.json" gleam run

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
        -- 'sleep 2 && npx @tailwindcss/cli -i ./assets/css/app.css -o ./priv/static/css/app.css && gleam run'

server:
    cd server && npx @tailwindcss/cli -i ./assets/css/app.css -o ./priv/static/css/app.css --minify && gleam run

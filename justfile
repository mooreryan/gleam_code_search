file_size dir:
    fd -t f . {{ dir }} --exec stat -f%z {}

total_file_size dir:
    fd -t f . {{ dir }} --exec stat -f%z {} | awk '{sum+=$1} END {print sum}'

# Общие параметры стенда. Правьте здесь, не в run.sh.
export PGDATABASE=${PGDATABASE:-ckpt_bench}
export PGHOST=${PGHOST:-/tmp}
export PGPORT=${PGPORT:-5432}

# Масштаб pgbench. База должна быть в 4-6 раз больше shared_buffers,
# иначе грязных страниц не наберётся и эксперимент вырождается.
# scale 100 ~ 1.5 GB при shared_buffers = 256MB.
export SCALE=${SCALE:-100}

# Фиксированный arrival rate. Мы измеряем задержку под известным
# темпом, а не пропускную способность.
export RATE=${RATE:-300}
export CLIENTS=${CLIENTS:-8}
export JOBS=${JOBS:-4}
export DURATION=${DURATION:-900}   # секунд, минимум 3 полных чекпойнта

export RESULTS=${RESULTS:-$(pwd)/results}

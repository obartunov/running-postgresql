# Planner path-pruning injection points, v3

Собрано на основе v2 @yoda. Отличия от v2:

- добавлена точка `planner-add-path-accept`: без неё выживший путь
  ненаблюдаем, и серия не отвечает на собственный мотивирующий вопрос;
- точки загружаются один раз за вызов планировщика
  (`INJECTION_POINT_LOAD` в `standard_planner`) и вызываются через
  `INJECTION_POINT_CACHED`, чтобы в сборках с injection points не делать
  поиск в разделяемой памяти на каждый вызов `add_path()`;
- `Assert` перенесён перед разыменованием payload;
- upper rel помечается как `upper`, а не печатается пустым множеством;
- индекс определяется и для `BitmapHeapPath` через его `bitmapqual`:
  иначе центральное событие демонстрации показывает `new_index=0` при
  вытеснении между двумя путями одного и того же индекса;
- `path_type_name()` покрывает Sort, Gather, Material, Memoize и другие
  узлы, которые в v2 схлопывались в `Other`;
- патчи порождены `git format-patch` и накладываются на master.

## Проверено

```text
база:   PostgreSQL master 20devel, коммит 140fdfcd
сборка: --enable-injection-points --without-icu --without-readline
        --without-zlib, CFLAGS=-O1
APPLY:  PASS
BUILD:  PASS, без предупреждений
TESTS:  PASS (src/test/modules/injection_points: 4 и 11 тестов)
DEMO:   PASS, все три требуемых признака воспроизводятся
```

Трассы демонстрации сохранены: `demo/trace-observed.log` для первого
запроса и `demo/trace-observed-join.log` для второго.

Второй запрос - тот самый мотивирующий случай, ради которого всё
затевалось: индекса нет в финальном плане, и трасса показывает, что он
не был отсеян. Оба кандидата по нему приняты, Nested Loop над
параметризованным путём тоже принят, и уже он вытеснен более дешёвым
Hash Join.

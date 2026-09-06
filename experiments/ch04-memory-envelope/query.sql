-- Отчёт с несколькими потребителями бюджета: хеш-соединение,
-- хеш-агрегация и сортировка. Замените на свой реальный тяжёлый
-- запрос — смысл стенда в вашем множителе, а не в этом примере.
SELECT c.city,
       date_trunc('month', o.created) AS month,
       count(*)                       AS cnt,
       sum(o.amount)                  AS total,
       max(o.note)                    AS sample
FROM orders o
JOIN customers c ON c.id = o.customer_id
GROUP BY c.city, date_trunc('month', o.created)
ORDER BY total DESC, cnt DESC;
